//! Port monitoring via /proc/net/tcp — no TCP connects, no subprocesses.
//!
//! Linux tracks listening sockets in /proc/net/tcp and /proc/net/tcp6.
//! Reading those two small files is microseconds of work and reflects state
//! changes within ~1s. There is no multicast event source for TCP listen
//! state without root, so this is the lightest correct approach — far
//! cheaper than the old Bun server (23 TCP connect attempts every 5s) or
//! any `ss`/`lsof` spawn.
//!
//! `/proc` discovery lives here; the decision to actually signal anything
//! lives in [`crate::killsafe`]. This module finds candidates, that module
//! decides whether they may be killed.

use crate::config::Config;
use crate::killsafe::{self, Refusal, SignalOutcome, Target};
use crate::waybar::emit;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use tokio::time::{sleep, Duration};

/// All ports currently in LISTEN state (IPv4 + IPv6).
pub fn listening_ports() -> HashSet<u16> {
    let mut set = HashSet::new();
    for path in ["/proc/net/tcp", "/proc/net/tcp6"] {
        let Ok(data) = std::fs::read_to_string(path) else {
            continue;
        };
        for line in data.lines().skip(1) {
            let mut fields = line.split_whitespace();
            let _sl = fields.next();
            let Some(local) = fields.next() else { continue };
            let _remote = fields.next(); // rem_address
            let Some(state) = fields.next() else { continue };
            // 0A == TCP_LISTEN (hex)
            if state != "0A" {
                continue;
            }
            if let Some(hex) = local.rsplit(':').next() {
                if let Ok(port) = u16::from_str_radix(hex, 16) {
                    set.insert(port);
                }
            }
        }
    }
    set
}

// ── dashboard snapshot ─────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub projects: serde_json::Value,
    pub status: HashMap<String, bool>,
    pub other_ports: Vec<u16>,
    pub other_status: HashMap<String, bool>,
    /// Friendly label per other port: static service map, else real process
    /// name from /proc, else absent.
    pub other_services: HashMap<String, String>,
    pub last_check: u64,
}

impl Snapshot {
    /// True when anything except `last_check` differs from `other`.
    pub fn differs_except_check(&self, other: &Snapshot) -> bool {
        self.projects != other.projects
            || self.status != other.status
            || self.other_ports != other.other_ports
            || self.other_status != other.other_status
            || self.other_services != other.other_services
    }
}

/// Build the /api/status payload: known ports + "other" listening ports.
pub fn snapshot(cfg: &Config) -> Snapshot {
    let listening = listening_ports();
    let mut status = HashMap::new();
    for project in &cfg.projects {
        for group in &project.groups {
            for entry in &group.entries {
                status.insert(entry.port.to_string(), listening.contains(&entry.port));
            }
        }
    }

    let known: HashSet<u16> = cfg
        .projects
        .iter()
        .flat_map(|p| p.groups.iter())
        .flat_map(|g| g.entries.iter())
        .map(|e| e.port)
        .collect();

    let mut other_ports: Vec<u16> = listening
        .iter()
        .copied()
        .filter(|p| *p > 1024 && !known.contains(p) && *p != cfg.dashboard_port)
        .collect();
    other_ports.sort_unstable();

    let other_status: HashMap<String, bool> = other_ports
        .iter()
        .map(|p| (p.to_string(), true))
        .collect();

    let other_services: HashMap<String, String> = other_ports
        .iter()
        .filter_map(|port| {
            let name = cfg
                .services
                .get(port)
                .cloned()
                .or_else(|| process_name_for_port(*port))
                .unwrap_or_default();
            if name.is_empty() {
                None
            } else {
                Some((port.to_string(), name))
            }
        })
        .collect();

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);

    Snapshot {
        projects: serde_json::to_value(&cfg.projects).unwrap_or(serde_json::json!([])),
        status,
        other_ports,
        other_status,
        other_services,
        last_check: now,
    }
}

/// Best-effort process name for whatever is listening on `port`: walk the
/// socket inode → /proc/<pid>/fd → cmdline basename.
fn process_name_for_port(port: u16) -> Option<String> {
    let mut inodes = inodes_for_port(port);
    inodes.sort_unstable();
    inodes.dedup();
    let mut names: Vec<String> = Vec::new();
    for inode in inodes {
        for pid in pids_for_inode(inode) {
            if let Some(name) = killsafe::process_name(pid) {
                if !names.contains(&name) {
                    names.push(name);
                }
            }
        }
    }
    names.first().cloned()
}

// ── waybar streaming module ────────────────────────────────────────────────

/// `sys-daemon waybar ports` — emits JSON only when the state changes.
///
/// The dashboard server is on-demand (toggle-dev-ports), so this module has
/// three faces:
///   dashboard stopped → dim 🔌, class dev-off (click to start)
///   dashboard running, nothing up → 🔌, class dev-idle
///   dashboard running, dev servers up → 🔌 N, class dev-active
pub async fn waybar_stream() -> anyhow::Result<()> {
    let cfg = Config::load();
    let known: Vec<(String, u16)> = cfg
        .projects
        .iter()
        .flat_map(|p| p.groups.iter().flat_map(move |g| {
            g.entries
                .iter()
                .map(move |e| (format!("{} — {}", p.name, e.name), e.port))
        }))
        .collect();

    let mut last = String::new();
    loop {
        let listening = listening_ports();

        // Dashboard not running → offer to start it.
        if !listening.contains(&cfg.dashboard_port) {
            let sig = "off".to_string();
            if sig != last {
                emit(
                    "🔌",
                    "Dev-ports dashboard is stopped\nClick: start it\n\nUse it while developing to see Firebase emulators and dev servers",
                    "dev-off",
                );
                last = sig;
            }
            sleep(Duration::from_millis(1000)).await;
            continue;
        }

        let running: Vec<&(String, u16)> =
            known.iter().filter(|(_, port)| listening.contains(port)).collect();

        let text = if running.is_empty() {
            "🔌".to_string()
        } else {
            format!("🔌 {}", running.len())
        };

        let tooltip = if running.is_empty() {
            "Dev-ports dashboard running — no dev servers up\nClick: stop · Middle-click: open dashboard".to_string()
        } else {
            let mut s = String::from("Running dev servers:\n");
            for (name, port) in &running {
                s.push_str(&format!("  • {name} :{port}\n"));
            }
            s.push_str("\nClick: stop · Middle-click: open dashboard");
            s
        };

        let class = if running.is_empty() { "dev-idle" } else { "dev-active" };
        let sig = format!("{text}|{tooltip}|{class}");
        if sig != last {
            emit(&text, &tooltip, class);
            last = sig;
        }
        sleep(Duration::from_millis(1000)).await;
    }
}

// ── kill ───────────────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct KillResult {
    pub success: bool,
    pub message: String,
    /// Set when the kill was refused. Distinguishes "nothing there" from
    /// "something there that I will not touch", which an operator needs to
    /// tell apart before concluding the dashboard is broken.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<String>,
    /// How each signal was delivered: `PidFd` where the kernel supported it,
    /// `StartTimeVerified` on the fallback path. Surfaced because the
    /// fallback narrows the PID-reuse race rather than removing it, and that
    /// is not something to hide from whoever reads the result.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub delivery: Vec<String>,
}

impl KillResult {
    fn refused(message: String, refusal: Refusal) -> Self {
        KillResult {
            success: false,
            message,
            refusal: Some(refusal_tag(&refusal)),
            delivery: Vec::new(),
        }
    }
}

fn refusal_tag(r: &Refusal) -> String {
    match r {
        Refusal::SelfPort { port } => format!("self_port:{port}"),
        Refusal::ManagementPort { port, service } => format!("management_port:{port}:{service}"),
        Refusal::ForeignUid {
            pid,
            expected,
            found,
        } => format!("foreign_uid:{pid}:expected={expected}:found={found}"),
        Refusal::NotTheSameProcess { pid } => format!("not_same_process:{pid}"),
        Refusal::Gone => "gone".to_string(),
    }
}

/// Inodes of LISTEN sockets bound to `port`.
fn inodes_for_port(port: u16) -> Vec<u64> {
    let needle = format!(":{port:04X}"); // hex, uppercase, zero-padded to 4
    let mut out = Vec::new();
    for path in ["/proc/net/tcp", "/proc/net/tcp6"] {
        let Ok(data) = std::fs::read_to_string(path) else {
            continue;
        };
        for line in data.lines().skip(1) {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.len() < 10 {
                continue;
            }
            if fields[1].ends_with(&needle) && fields[3] == "0A" {
                if let Ok(inode) = fields[9].parse::<u64>() {
                    out.push(inode);
                }
            }
        }
    }
    out
}

/// PIDs holding an fd pointing at any of `inodes`.
///
/// Takes the whole set rather than one inode so a caller can re-check several
/// targets against one walk.
fn pids_for_inode_set(inodes: &[u64]) -> std::collections::HashSet<u32> {
    let mut set = std::collections::HashSet::new();
    for inode in inodes {
        set.extend(pids_for_inode(*inode));
    }
    set
}

/// PIDs holding an fd pointing at `socket:[inode]`.
fn pids_for_inode(inode: u64) -> Vec<u32> {
    let want = format!("socket:[{inode}]");
    let mut pids = Vec::new();
    let Ok(proc) = std::fs::read_dir("/proc") else {
        return pids;
    };
    for entry in proc.flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<u32>() else {
            continue;
        };
        let Ok(fds) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
            continue;
        };
        for fd in fds.flatten() {
            if let Ok(target) = std::fs::read_link(fd.path()) {
                if target.to_string_lossy() == want {
                    pids.push(pid);
                }
            }
        }
    }
    pids.sort_unstable();
    pids.dedup();
    pids
}

/// TERM then KILL every process listening on `port`. Pure /proc walking, no
/// `fuser`/`ss`/`find` subprocesses like the old Bun implementation.
///
/// `self_port` is the dashboard's own port. It is passed in rather than read
/// from the listener so the self-protection rule is a parameter the tests can
/// exercise directly.
///
/// Every signal goes through [`killsafe::signal_target`], which pins the
/// process with a pidfd where the kernel supports one. The previous
/// implementation called `libc::kill(pid, …)` on a pid it had found by
/// walking `/proc` some milliseconds earlier; if that process exited in the
/// gap and the number was reused, the signal landed on an unrelated process.
pub async fn kill_port(port: u16, self_port: u16) -> KillResult {
    // Port-level protection, checked before any /proc walking at all.
    if let Some(service) = killsafe::is_management_port(port, self_port) {
        return KillResult::refused(
            format!("Refusing to kill port {port}: it belongs to {service}"),
            Refusal::ManagementPort { port, service },
        );
    }

    let mut inodes = inodes_for_port(port);
    inodes.sort_unstable();
    inodes.dedup();
    if inodes.is_empty() {
        return KillResult {
            success: false,
            message: format!("Nothing listening on port {port}"),
            refusal: None,
            delivery: Vec::new(),
        };
    }

    let mut pids = Vec::new();
    for inode in &inodes {
        pids.extend(pids_for_inode(*inode));
    }
    pids.sort_unstable();
    pids.dedup();
    if pids.is_empty() {
        return KillResult {
            success: false,
            message: format!("Nothing listening on port {port}"),
            refusal: None,
            delivery: Vec::new(),
        };
    }

    // Describe every candidate *before* signalling any of them, so a refusal
    // on one process (wrong UID, protected name) cannot leave the port
    // half-killed.
    let mut targets: Vec<Target> = Vec::new();
    for pid in &pids {
        match killsafe::describe(*pid, port, self_port) {
            Ok(t) => targets.push(t),
            Err(Refusal::Gone) => continue,
            Err(other) => return KillResult::refused(format!("Refusing to kill on {port}"), other),
        }
    }

    if let Err(refusal) = killsafe::check_targets(&targets) {
        return KillResult::refused(
            match &refusal {
                Refusal::ManagementPort { port, service } => {
                    format!("Refusing to kill port {port}: it belongs to {service}")
                }
                Refusal::ForeignUid { pid, .. } => {
                    format!("Refusing to kill pid {pid} on port {port}: not owned by this user")
                }
                Refusal::SelfPort { port } => {
                    format!("Refusing to kill port {port}: it is this dashboard")
                }
                Refusal::NotTheSameProcess { pid } => {
                    format!("Refusing to kill pid {pid} on port {port}: process changed")
                }
                Refusal::Gone => format!("Nothing left listening on port {port}"),
            },
            refusal,
        );
    }

    if targets.is_empty() {
        return KillResult {
            success: false,
            message: format!("Nothing listening on port {port}"),
            refusal: None,
            delivery: Vec::new(),
        };
    }

    // Re-confirm the link between each pid and the socket we found it through,
    // AFTER pinning. The discovery walk is not atomic: between reading
    // /proc/<pid>/fd and approving the target, the process can exit, drop the
    // listening socket, and a different process can take the port. Re-walking
    // the inode closes that window for everything except a full recycle within
    // one pidfd-pinned lifetime.
    for t in &targets {
        if !pids_for_inode_set(&inodes).contains(&t.pid) {
            return KillResult::refused(
                format!("Refusing to kill pid {} on port {port}: it no longer holds the socket", t.pid),
                Refusal::NotTheSameProcess { pid: t.pid },
            );
        }
    }

    // TERM, give the process a moment, then KILL whatever is still running.
    // Liveness is checked with the zombie-aware helper: after a successful
    // SIGTERM the process is usually a zombie by now, and signalling a zombie
    // is a no-op that reports misleadingly.
    let mut delivery = Vec::new();
    for t in &targets {
        delivery.push(describe_delivery(killsafe::signal_target(t, killsafe::SIGTERM)));
    }
    sleep(Duration::from_millis(600)).await;
    for t in &targets {
        if killsafe::process_is_running(t.pid) {
            delivery.push(describe_delivery(killsafe::signal_target(t, killsafe::SIGKILL)));
        }
    }

    delivery_result(port, targets.len(), delivery)
}

fn delivery_result(port: u16, signalled: usize, delivery: Vec<String>) -> KillResult {
    let success = !delivery.is_empty()
        && delivery.iter().all(|outcome| outcome == "pidfd" || outcome == "start_time");
    KillResult {
        success,
        message: if success {
            format!("Sent termination signals to {signalled} process(es) on port {port}")
        } else {
            format!("Termination on port {port} was incomplete; inspect signal delivery")
        },
        refusal: None,
        delivery,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_comparison_ignores_only_the_check_timestamp() {
        let base = Snapshot {
            projects: serde_json::json!([]), status: HashMap::new(),
            other_ports: vec![4000], other_status: HashMap::new(),
            other_services: HashMap::new(), last_check: 1,
        };
        let mut changed = base.clone();
        changed.last_check = 2;
        assert!(!base.differs_except_check(&changed));
        changed.other_services.insert("4000".into(), "new-process".into());
        assert!(base.differs_except_check(&changed));
        changed = base.clone();
        changed.projects = serde_json::json!([{"name": "new-project"}]);
        assert!(base.differs_except_check(&changed));
    }

    #[test]
    fn refused_or_failed_signals_cannot_report_success() {
        assert!(delivery_result(4000, 1, vec!["pidfd".into()]).success);
        for delivery in [vec![], vec!["failed:permission denied".into()],
            vec!["pidfd".into(), "refused:reused".into()]] {
            assert!(!delivery_result(4000, 1, delivery).success);
        }
    }
}

fn describe_delivery(outcome: SignalOutcome) -> String {
    match outcome {
        SignalOutcome::PidFd => "pidfd".to_string(),
        SignalOutcome::StartTimeVerified => "start_time".to_string(),
        SignalOutcome::Reused(r) => format!("refused:{}", refusal_tag(&r)),
        SignalOutcome::Failed(e) => format!("failed:{e}"),
    }
}
