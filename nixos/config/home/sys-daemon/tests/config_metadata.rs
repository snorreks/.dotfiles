//! Protection must survive the configuration changing underneath it.
//!
//! `ports.json` is operator-editable and meant to be edited: adding a project,
//! relabelling a service, moving the dashboard to another port. Every one of
//! those is a legitimate thing to do.
//!
//! It also means every one of them is a way to weaken the kill rules by
//! accident, or on purpose, by someone editing a JSON file rather than by
//! anyone attacking the daemon. So the protections are asserted against
//! *mutated* configurations, not just against the shipped one. If a change to
//! the dashboard's own port could make the daemon killable, or adding a
//! project entry could make sshd killable, that is a finding here.
//!
//! Nothing in this file signals a process or binds a port: it exercises the
//! pure decision functions over a range of configurations.

use sys_daemon::config::Config;
use sys_daemon::killsafe::{self, Refusal, Target};
use sys_daemon::httpcore::{Guard, Rejection, Route, Request};

/// The workload port the fixtures name, as opposed to the dashboard's own.
const WORKLOAD_PORT: u16 = 4000;

/// A dashboard request that a browser on this machine would legitimately make,
/// bound to whatever port the configuration under test declares.
fn request_for(port: u16) -> Request {
    let host = format!("127.0.0.1:{port}");
    let origin = format!("http://127.0.0.1:{port}");
    let token = "c".repeat(64);
    // Content-Length is DERIVED from the body. It was hard-coded to 12 while
    // the body `{"port":4000}` is 13 bytes, so the parser sliced off the
    // closing brace and handed `{"port":4000` to serde, which fails to parse
    // and silently routes to NotFound. The assertions still passed, because
    // they only checked `check()` — so the helper was quietly exercising a
    // truncated body.
    let body = format!("{{\"port\":{WORKLOAD_PORT}}}");
    let raw = format!(
        "POST /api/kill HTTP/1.1\r\nHost: {host}\r\nOrigin: {origin}\r\n\
         Content-Type: application/json\r\nX-Sys-Daemon-Token: {token}\r\n\
         Content-Length: {len}\r\n\r\n{body}",
        len = body.len()
    );
    sys_daemon::httpcore::parse(raw.as_bytes()).expect("the request is well formed")
}

/// Build a config with a chosen dashboard port and some plausible entries.
fn config_with_dashboard_port(port: u16) -> Config {
    Config {
        dashboard_port: port,
        projects: vec![sys_daemon::config::Project {
            name: "example".into(),
            groups: vec![sys_daemon::config::PortGroup {
                title: "web".into(),
                entries: vec![sys_daemon::config::PortEntry {
                    name: "dev".into(),
                    port: 4000,
                }],
            }],
        }],
        services: [(4000u16, "example-dev".to_string())]
            .into_iter()
            .collect(),
    }
}

/// A target owned by us, on `port`, under a config whose dashboard is on
/// `self_port`.
fn target_on(port: u16, self_port: u16) -> Target {
    Target {
        pid: std::process::id(),
        port,
        self_port,
        uid: killsafe::self_uid(),
        expected_uid: killsafe::self_uid(),
        name: Some("example-dev".into()),
        start_time: 1,
        pidfd: None,
    }
}

// ── the dashboard's own port, moved ─────────────────────────────────────────

/// Moving the dashboard must move its self-protection with it. The old port
/// becomes an ordinary port; the new one becomes untouchable.
#[test]
fn moving_the_dashboard_port_moves_its_self_protection() {
    let before = Config::default();
    let after = config_with_dashboard_port(45451);
    assert_ne!(before.dashboard_port, after.dashboard_port);

    assert_eq!(
        killsafe::is_management_port(before.dashboard_port, before.dashboard_port),
        Some("dev-ports dashboard"),
        "the original port protects itself"
    );
    assert_eq!(
        killsafe::is_management_port(after.dashboard_port, after.dashboard_port),
        Some("dev-ports dashboard"),
        "the relocated dashboard must protect itself"
    );

    // And crucially: the NEW port is not protected on a daemon that is not
    // running there. Otherwise relabelling a port in the config would
    // silently freeze an unrelated workload.
    assert_eq!(
        killsafe::is_management_port(after.dashboard_port, before.dashboard_port),
        None,
        "a port that is only special to another daemon must not be protected here"
    );
}

/// The `Host` an authorised request must present follows the configured port.
/// A dashboard moved to 45451 must not keep accepting `Host: 127.0.0.1:3333`,
/// which is the stale-value form of DNS rebinding.
#[test]
fn authorised_requests_track_the_configured_port() {
    for port in [3333u16, 45451, 65535] {
        let guard = Guard::new(port, "c".repeat(64));
        assert_eq!(
            guard.check(&request_for(port)),
            Ok(()),
            "port {port}: a matching Host must be accepted"
        );

        // A Host naming a different port is a rebinding attempt.
        let other = if port == 3333 { 45451 } else { 3333 };
        let wrong = request_for(other);
        assert_eq!(
            guard.check(&wrong),
            Err(Rejection::BadHost),
            "port {port}: a Host naming port {other} must be refused"
        );
    }
}

/// Killing the dashboard's own port is refused for every port it might be
/// configured on, checked through the same entry point `kill_port` uses.
#[test]
fn kill_targets_are_refused_for_any_configured_dashboard_port() {
    for port in [3333u16, 8080, 45451] {
        let result = killsafe::check_targets(&[target_on(port, port)]);
        assert!(
            result.is_err(),
            "killing the dashboard on port {port} must be refused"
        );
    }
}

// ── project entries ─────────────────────────────────────────────────────────

/// Adding a project entry for a management port does not make that port
/// killable. `/api/kill` takes a raw port number, and the project list is
/// display metadata — it has no authority over what may be terminated.
#[test]
fn a_project_entry_for_a_management_port_does_not_unprotect_it() {
    let mut cfg = config_with_dashboard_port(3333);
    // An operator adds a project that happens to use port 22.
    cfg.projects.push(sys_daemon::config::Project {
        name: "oops".into(),
        groups: vec![sys_daemon::config::PortGroup {
            title: "misc".into(),
            entries: vec![sys_daemon::config::PortEntry {
                name: "not-really-sshd".into(),
                port: 22,
            }],
        }],
    });

    assert!(
        cfg.projects.iter().any(|p| p
            .groups
            .iter()
            .any(|g| g.entries.iter().any(|e| e.port == 22))),
        "the fixture must actually contain port 22"
    );

    // The kill rules never consult the project list, so this holds.
    assert_eq!(
        killsafe::is_management_port(22, cfg.dashboard_port),
        Some("sshd")
    );
    assert!(killsafe::check_targets(&[target_on(22, cfg.dashboard_port)]).is_err());
}

/// Relabelling a service in the service map does not unprotect the port. The
/// map is what the dashboard *displays* for a port; it is not an allowlist.
#[test]
fn relabelling_a_management_service_does_not_unprotect_it() {
    let mut cfg = config_with_dashboard_port(3333);
    cfg.services.insert(22, "my-tunnel".into());
    cfg.services.insert(7456, "my-bridge".into());

    assert_eq!(
        killsafe::is_management_port(22, cfg.dashboard_port),
        Some("sshd"),
        "a service-map label must not override the port table"
    );
    assert_eq!(killsafe::is_management_port(7456, cfg.dashboard_port), Some("collie"));
    assert!(killsafe::check_targets(&[target_on(22, cfg.dashboard_port)]).is_err());
    assert!(killsafe::check_targets(&[target_on(7456, cfg.dashboard_port)]).is_err());
}

/// Dropping every project leaves the protections intact. An empty or minimal
/// configuration must not be a way to disable them.
#[test]
fn an_empty_configuration_still_protects_management_ports() {
    let empty = Config::default();
    assert!(empty.projects.is_empty());
    for port in [22u16, 5335, 7456, empty.dashboard_port] {
        assert!(
            killsafe::is_management_port(port, empty.dashboard_port).is_some(),
            "port {port} must stay protected with no projects configured"
        );
    }
}

// ── the resolved process, not just the config ───────────────────────────────

/// The name check keys on the *resolved* process, so a workload that merely
/// sounds like a management process by coincidence is still refused, and a
/// management process reached under a different path is still refused.
#[test]
fn name_protection_uses_the_resolved_process_not_the_config() {
    let cfg = config_with_dashboard_port(3333);
    // The config labels port 4000 innocuously; the process actually holding it
    // is what decides.
    assert_eq!(
        cfg.services.get(&4000).map(String::as_str),
        Some("example-dev")
    );

    let mut disguised = target_on(4000, cfg.dashboard_port);
    disguised.name = Some("herdr".into());
    assert!(
        killsafe::check_targets(&[disguised]).is_err(),
        "a process actually named herdr must be refused whatever the service map says"
    );

    let mut honest = target_on(4000, cfg.dashboard_port);
    honest.name = Some("bun".into());
    assert!(
        killsafe::check_targets(&[honest]).is_ok(),
        "an ordinary workload on an ordinary port must remain killable"
    );
}

/// The refusal for a protected process names the port, so the dashboard can
/// tell the operator which one was refused rather than just failing.
#[test]
fn refusal_is_specific_about_the_protected_port() {
    let cfg = config_with_dashboard_port(3333);
    match killsafe::check_targets(&[target_on(22, cfg.dashboard_port)]) {
        Err(Refusal::ManagementPort { port, service }) => {
            assert_eq!(port, 22);
            assert_eq!(service, "sshd");
        }
        other => panic!("expected a ManagementPort refusal, got {other:?}"),
    }
}

/// The helper `request_for` builds must actually route to a kill.
///
/// It exists because `request_for` hard-coded `Content-Length: 12` against a
/// 13-byte body, so the parser dropped the closing brace and every request it
/// produced routed to NotFound. Nothing caught that, because the other tests
/// only asserted `check()`. This one asserts the classification, which is what
/// the truncation broke.
#[test]
fn the_fixture_request_actually_routes_to_a_kill() {
    let req = request_for(3333);
    assert_eq!(Guard::new(3333, "c".repeat(64)).check(&req), Ok(()));
    assert_eq!(
        sys_daemon::httpcore::classify(&req),
        Route::Kill(WORKLOAD_PORT),
        "the fixture must carry a complete, parseable body"
    );
}

/// A kill request that names no port is not a kill. Confirmed against the
/// routed request rather than the parser, since this is the shape a truncated
/// or hostile body produces.
#[test]
fn a_kill_request_without_a_usable_port_does_not_route() {
    let guard = Guard::new(3333, "c".repeat(64));
    for body in [b"{}".as_slice(), b"not json", b"{\"port\":0}", b"{\"port\":\"22\"}"] {
        let raw = format!(
            "POST /api/kill HTTP/1.1\r\nHost: 127.0.0.1:3333\r\n\
             Content-Type: application/json\r\nX-Sys-Daemon-Token: {}\r\n\
             Content-Length: {}\r\n\r\n",
            "c".repeat(64),
            body.len()
        );
        let mut bytes = raw.into_bytes();
        bytes.extend_from_slice(body);
        let req = sys_daemon::httpcore::parse(&bytes).expect("parses");
        assert_eq!(guard.check(&req), Ok(()));
        assert_eq!(
            sys_daemon::httpcore::classify(&req),
            Route::NotFound,
            "body {:?} must not produce a kill",
            String::from_utf8_lossy(body)
        );
    }
}
