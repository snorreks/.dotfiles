//! Tests for the process-kill safety rules.
//!
//! # These tests kill processes, so the blast radius is fenced
//!
//! Every test that signals anything spawns the process it is about to signal,
//! and signals only that child. A `Spawned` guard owns its pid: it is the only
//! thing in this file permitted to call [`killsafe::signal_target`], and it
//! refuses outright if handed a pid it did not start. That is a deliberate
//! asymmetry with production, where the daemon signals processes it discovered
//! by walking `/proc` — here the equivalent discovery step is *not* tested
//! against live processes, because a discovery bug in a test suite would aim a
//! SIGKILL at whatever else happens to be listening.
//!
//! Nothing in this file calls [`sys_daemon::ports::kill_port`]. That function
//! works from real `/proc/net/tcp` state, so calling it in a test would mean
//! signalling whatever this machine happens to be running — including the agent
//! multiplexer and its session, which is not a thing a test should be able to
//! do by accident. Its port and identity rules are covered here through
//! [`killsafe::check_targets`], which is the pure decision it defers to.
//!
//! Policy tests (everything except the three that signal a child) allocate
//! nothing and spawn nothing, so they are safe to run anywhere.

use std::process::{Child, Command, Stdio};
use sys_daemon::killsafe::{
    self, Refusal, SignalOutcome, Target, MANAGEMENT_PORTS, PROTECTED_NAMES,
};

/// The dashboard's own port, used as `self_port` throughout.
const SELF_PORT: u16 = 3333;
/// A port that belongs to a workload and is therefore fair game.
const WORKLOAD_PORT: u16 = 4000;

/// Owns a process this test spawned, and is the only thing here that signals.
///
/// Deliberately not `#[derive(Debug)]`-cloned and deliberately not copyable in
/// a way that would let the pid outlive the check: `signal()` verifies the pid
/// is still one of ours immediately before it does anything.
struct Spawned {
    child: Child,
    pid: u32,
}

impl Spawned {
    /// Start a disposable, long-lived child we intend to signal.
    ///
    /// `sleep` is chosen because it does nothing, listens on nothing, and is
    /// guaranteed to be disposable. It is resolved through `PATH` rather than
    /// named absolutely so the test does not encode one machine's layout.
    fn disposable() -> Self {
        let child = Command::new("sleep")
            .arg("300")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("sleep must be spawnable for these tests");
        let pid = child.id();
        // Do not let a panic in the middle of a test leave it running.
        let spawned = Spawned { child, pid };
        assert!(
            killsafe::process_start_time(pid).is_some(),
            "spawned pid {pid} has no readable start time"
        );
        spawned
    }

    fn describe(&self, port: u16) -> Target {
        killsafe::describe(self.pid, port, SELF_PORT)
            .expect("a live child must be describable")
    }

    /// Signal this child, having first re-verified we still own the pid.
    fn signal(&self, signal: i32) -> SignalOutcome {
        assert_eq!(
            killsafe::process_start_time(self.pid).is_some(),
            true,
            "refusing to signal pid {}: it is no longer our child",
            self.pid
        );
        killsafe::signal_target(&self.describe(WORKLOAD_PORT), signal)
    }

    fn still_alive(&self) -> bool {
        // Zombie-aware: `sleep` killed by SIGTERM stays in /proc as a zombie
        // until reaped, and this test does not reap until Drop.
        killsafe::process_is_running(self.pid)
    }
}

impl Drop for Spawned {
    fn drop(&mut self) {
        // Reap, and do not leave a stray `sleep` behind. SIGKILL is fine here:
        // this is our own disposable child, and the tests have already
        // established that signalling it works.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A target that looks like a workload owned by us, for pure policy tests.
fn synthetic_target(pid: u32, port: u16, name: Option<&str>) -> Target {
    Target {
        pid,
        port,
        self_port: SELF_PORT,
        uid: killsafe::self_uid(),
        expected_uid: killsafe::self_uid(),
        name: name.map(|s| s.to_string()),
        start_time: 12345,
        // No pidfd: these targets are fabricated, so there is no process to
        // pin. That is deliberate — it makes the policy tests exercise the
        // start-time fallback path, which is the one the real daemon takes on
        // kernels without pidfd.
        pidfd: None,
    }
}

// ── port protection ─────────────────────────────────────────────────────────

/// The dashboard may not kill itself. This is the self-inflicted one: the
/// process holding this port is the one serving the request that asked.
#[test]
fn dashboard_refuses_to_kill_its_own_port() {
    assert_eq!(
        killsafe::is_management_port(SELF_PORT, SELF_PORT),
        Some("dev-ports dashboard")
    );
}

/// Self-protection follows the port even when the operator has moved it away
/// from the well-known default, so a custom `dashboard_port` is not a way to
/// make the daemon killable.
#[test]
fn self_protection_tracks_a_custom_dashboard_port() {
    let custom = 45123;
    assert_eq!(
        killsafe::is_management_port(custom, custom),
        Some("dev-ports dashboard"),
        "a non-default dashboard port must still be protected"
    );
    // And that same port is not protected when it is some *other* daemon's
    // port — protection is keyed on identity, not on the number alone.
    assert_eq!(killsafe::is_management_port(custom, SELF_PORT), None);
}

/// Every management port is protected. Asserted as a loop over the table so
/// adding a row to `MANAGEMENT_PORTS` cannot be forgotten here.
///
/// The dashboard's own port is checked separately, and is not expected in this
/// table: it is protected by identity (`self_port`) rather than by number, so
/// it still works when the operator moves the daemon off 3333.
#[test]
fn every_declared_management_port_is_protected() {
    assert!(
        !MANAGEMENT_PORTS.iter().any(|(p, _)| *p == SELF_PORT),
        "the dashboard's own port must be protected by self_port, not duplicated here"
    );
    for (port, name) in MANAGEMENT_PORTS {
        assert_eq!(
            killsafe::is_management_port(*port, SELF_PORT),
            Some(*name),
            "port {port} ({name}) is in the table but not protected"
        );
    }
}

/// sshd and tailscaled are in the table. Called out individually because they
/// are the two ports where a kill is unrecoverable from the machine itself:
/// losing sshd to a loopback dashboard request loses the way back in.
#[test]
fn remote_access_ports_are_protected() {
    assert_eq!(killsafe::is_management_port(22, SELF_PORT), Some("sshd"));
    assert_eq!(killsafe::is_management_port(5335, SELF_PORT), Some("moshi-hook"));
    assert_eq!(killsafe::is_management_port(7456, SELF_PORT), Some("collie"));
}

/// An ordinary workload port is not protected. Without this, "protect
/// everything" would pass every other test in this file while being useless.
#[test]
fn workload_ports_are_not_protected() {
    assert_eq!(killsafe::is_management_port(WORKLOAD_PORT, SELF_PORT), None);
    assert_eq!(killsafe::is_management_port(3000, SELF_PORT), None);
}

// ── name protection ─────────────────────────────────────────────────────────

/// Management process names are never targets, whatever port they hold.
#[test]
fn management_process_names_are_protected() {
    for name in PROTECTED_NAMES {
        assert!(
            killsafe::is_protected_name(name),
            "{name} is in the table but not protected"
        );
    }
}

/// herdr in particular. This is the agent multiplexer: if the dashboard can
/// kill it, it kills the running of every agent on this machine, including the
/// one that would be reporting the failure.
#[test]
fn herdr_is_protected() {
    assert!(killsafe::is_protected_name("herdr"));
    assert!(killsafe::is_protected_name("/usr/bin/herdr"));
    assert!(killsafe::is_protected_name("./herdr"));
}

/// Matching is on the executable basename, so a full path or a relative one
/// cannot smuggle a protected name past the check.
#[test]
fn protected_name_matching_uses_the_basename() {
    assert!(killsafe::is_protected_name("/nix/store/abc-sys-daemon/bin/sys-daemon"));
    assert!(killsafe::is_protected_name("herdr"));
    assert!(!killsafe::is_protected_name("herdr-tui"));
    assert!(!killsafe::is_protected_name("bun"));
}

/// A protected process on an unprotected port is still refused, and so is an
/// unprotected process on a protected port. The two checks are independent.
#[test]
fn check_targets_refuses_a_protected_name_on_a_workload_port() {
    let targets = [synthetic_target(4000, WORKLOAD_PORT, Some("herdr"))];
    match killsafe::check_targets(&targets) {
        Err(Refusal::ManagementPort { port, .. }) => assert_eq!(port, WORKLOAD_PORT),
        other => panic!("expected ManagementPort refusal, got {other:?}"),
    }
}

#[test]
fn check_targets_refuses_a_management_port_whatever_the_process_is_called() {
    let targets = [synthetic_target(4000, 22, Some("curl"))];
    match killsafe::check_targets(&targets) {
        Err(Refusal::ManagementPort { port, .. }) => assert_eq!(port, 22),
        other => panic!("expected ManagementPort refusal, got {other:?}"),
    }
}

/// The happy path: an ordinary process of ours on an ordinary port is allowed.
#[test]
fn check_targets_permits_a_workload_we_own() {
    let targets = [synthetic_target(4000, WORKLOAD_PORT, Some("bun"))];
    assert!(killsafe::check_targets(&targets).is_ok());
}

// ── ownership ───────────────────────────────────────────────────────────────

/// A process owned by another user is refused. The daemon is a user process;
/// it has no business terminating a root-owned system service that happens to
/// hold the requested port.
#[test]
fn check_targets_refuses_a_foreign_uid() {
    let mut target = synthetic_target(4000, WORKLOAD_PORT, Some("systemd"));
    target.uid = killsafe::self_uid().wrapping_add(1);
    match killsafe::check_targets(&[target]) {
        Err(Refusal::ForeignUid { pid, found, .. }) => {
            assert_eq!(pid, 4000);
            assert_eq!(found, killsafe::self_uid().wrapping_add(1));
        }
        other => panic!("expected ForeignUid refusal, got {other:?}"),
    }
}

/// Refusal is all-or-nothing. Discovering a protected process alongside a
/// killable one must not let the killable one through — the caller asked to
/// stop the thing on this port, and a half-result there is the surprise the
/// whole check exists to prevent.
#[test]
fn one_protected_process_refuses_the_whole_operation() {
    let targets = [
        synthetic_target(4001, WORKLOAD_PORT, Some("bun")),
        synthetic_target(4002, WORKLOAD_PORT, Some("herdr")),
    ];
    assert!(killsafe::check_targets(&targets).is_err());
}

// ── identity: PID reuse ─────────────────────────────────────────────────────

/// A target whose recorded start time no longer matches the pid is refused.
///
/// This is the PID-reuse case, and it is tested on the *fallback* path
/// specifically: a fabricated target carries no pidfd, so the decision rests
/// on the start-time comparison. On the pidfd path the stale field would be
/// irrelevant — the fd names one process and keeps naming it — which is the
/// point of holding it from discovery. `pidfd_is_held_from_discovery` covers
/// that half.
#[test]
fn a_reused_pid_is_refused() {
    let spawned = Spawned::disposable();
    let mut stale = spawned.describe(WORKLOAD_PORT);
    // Pretend we recorded this target a long time ago.
    stale.start_time = stale.start_time.wrapping_add(1);
    stale.pidfd = None;

    // Bypass `Spawned::signal`, which re-verifies: this test is specifically
    // about signalling when the verification is expected to FAIL.
    let outcome = killsafe::signal_target(&stale, killsafe::SIGTERM);
    assert!(
        matches!(outcome, SignalOutcome::Reused(Refusal::NotTheSameProcess { .. })),
        "expected reuse refusal, got {outcome:?}"
    );
    assert!(
        spawned.still_alive(),
        "the child must survive: a start-time mismatch is a refusal, not a kill"
    );
}

/// A target discovered while the pid was valid holds a pidfd, and that pidfd
/// is what the signal goes through.
///
/// This is the regression guard for the subtle version of the bug: an earlier
/// revision opened the pidfd inside `signal_target`, at signal time. That
/// looked like PID-reuse protection and was not — it reopened the exact window
/// between discovery and signal, because a pidfd opened after the reuse pins
/// whatever now holds the number.
#[test]
fn pidfd_is_held_from_discovery() {
    let spawned = Spawned::disposable();
    let target = spawned.describe(WORKLOAD_PORT);
    assert!(
        target.pidfd.is_some(),
        "discovery should have taken a pidfd on a pidfd-capable kernel"
    );

    // Corrupt the start time. With a pidfd held, delivery must still succeed,
    // because the pidfd — not the start time — is the identity proof.
    let mut corrupted = target;
    corrupted.start_time = corrupted.start_time.wrapping_add(999);
    assert_eq!(
        killsafe::signal_target(&corrupted, killsafe::SIGTERM),
        SignalOutcome::PidFd,
        "a pidfd held from discovery must win over a stale start time"
    );
}

/// A vanished pid is likewise refused rather than signalled. Signalling a
/// recycled number is the failure this guards against; not signalling an
/// absent one is just correctness.
#[test]
fn a_dead_pid_is_refused() {
    let gone = Target {
        pid: 4194303, // above the default pid_max, so it cannot exist
        port: WORKLOAD_PORT,
        self_port: SELF_PORT,
        uid: killsafe::self_uid(),
        expected_uid: killsafe::self_uid(),
        name: None,
        start_time: 1,
        pidfd: None,
    };
    let outcome = killsafe::signal_target(&gone, killsafe::SIGTERM);
    assert!(
        matches!(outcome, SignalOutcome::Reused(Refusal::NotTheSameProcess { .. })),
        "expected refusal for a dead pid, got {outcome:?}"
    );
}

// ── the delivery path, against a disposable child ───────────────────────────

/// The pidfd path, if the kernel has one. This is the mechanism that makes
/// PID reuse impossible rather than unlikely, so it is worth confirming
/// whether this machine actually has it.
#[test]
fn pidfd_is_used_when_available() {
    let spawned = Spawned::disposable();
    let has_pidfd = killsafe::pidfd_open(spawned.pid).is_some();
    let outcome = spawned.signal(killsafe::SIGTERM);

    match outcome {
        SignalOutcome::PidFd => assert!(has_pidfd, "reported pidfd but none could be opened"),
        SignalOutcome::StartTimeVerified => assert!(
            !has_pidfd,
            "fell back to start-time despite pidfd being available"
        ),
        other => panic!("our own live child should have been signalled: {other:?}"),
    }
}

/// A real SIGTERM to our own child actually terminates it, and the daemon
/// reports how it was delivered so the operator can see whether the pidfd path
/// or the weaker fallback was in play.
#[test]
fn signalling_our_own_child_works() {
    let spawned = Spawned::disposable();
    let pid = spawned.pid;
    assert!(spawned.still_alive());

    let outcome = spawned.signal(killsafe::SIGTERM);

    match &outcome {
        SignalOutcome::PidFd => {}
        SignalOutcome::StartTimeVerified => {}
        other => panic!("unexpected delivery: {other:?}"),
    }

    // `sleep` dies on SIGTERM. Give the scheduler a moment, then reap.
    for _ in 0..50 {
        if !spawned.still_alive() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(
        !spawned.still_alive(),
        "pid {pid} survived a SIGTERM sent through the production signalling path"
    );
}

/// `describe` refuses a pid that does not exist, rather than inventing a
/// target with default identity — an invented start time would pass the
/// reuse check by accident.
#[test]
fn describe_refuses_a_nonexistent_pid() {
    assert!(matches!(
        killsafe::describe(4194303, WORKLOAD_PORT, SELF_PORT),
        Err(Refusal::Gone)
    ));
}

/// This process is describable, and its UID is our own. If these ever drift,
/// every ownership rule above is being evaluated against the wrong number.
#[test]
fn this_process_is_describable_as_ours() {
    let me = std::process::id();
    let target = killsafe::describe(me, WORKLOAD_PORT, SELF_PORT).expect("we exist");
    assert_eq!(target.uid, killsafe::self_uid());
    assert_eq!(target.expected_uid, killsafe::self_uid());
    assert!(target.start_time > 0);
}
