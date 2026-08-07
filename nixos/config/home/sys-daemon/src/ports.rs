//! Port monitoring via /proc/net/tcp — no TCP connects, no subprocesses.
//!
//! Linux tracks listening sockets in /proc/net/tcp and /proc/net/tcp6.
//! Reading those two small files is microseconds of work and reflects state
//! changes within ~1s. There is no multicast event source for TCP listen
//! state without root, so this is the lightest correct approach — far
//! cheaper than the old Bun server (23 TCP connect attempts every 5s) or
//! any `ss`/`lsof` spawn.

use crate::config::Config;
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
        self.status != other.status
            || self.other_ports != other.other_ports
            || self.other_status != other.other_status
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
            if let Some(name) = process_name(pid) {
                if !names.contains(&name) {
                    names.push(name);
                }
            }
        }
    }
    names.first().cloned()
}

fn process_name(pid: u32) -> Option<String> {
    // Prefer the executable basename from cmdline ("steam", "spotify",
    // "bun", "ollama" ...), falling back to the comm field.
    let from_cmdline = std::fs::read_to_string(format!("/proc/{pid}/cmdline"))
        .ok()
        .and_then(|s| {
            let first = s.split('\0').next().unwrap_or("");
            let base = std::path::Path::new(first)
                .file_name()?
                .to_string_lossy()
                .to_string();
            let base = base.trim_start_matches('.').to_string();
            if base.is_empty() {
                None
            } else {
                Some(base)
            }
        });
    if let Some(name) = from_cmdline {
        return Some(name.chars().take(16).collect());
    }
    let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
    let comm = comm.trim().trim_start_matches('.').to_string();
    if comm.is_empty() {
        None
    } else {
        Some(comm.chars().take(16).collect())
    }
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
pub async fn kill_port(port: u16) -> KillResult {
    let mut inodes = inodes_for_port(port);
    inodes.sort_unstable();
    inodes.dedup();
    if inodes.is_empty() {
        return KillResult {
            success: false,
            message: format!("Nothing listening on port {port}"),
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
        };
    }

    for pid in &pids {
        unsafe {
            libc::kill(*pid as i32, libc::SIGTERM);
        }
    }
    sleep(Duration::from_millis(600)).await;
    for pid in &pids {
        let alive = unsafe { libc::kill(*pid as i32, 0) } == 0;
        if alive {
            unsafe {
                libc::kill(*pid as i32, libc::SIGKILL);
            }
        }
    }

    KillResult {
        success: true,
        message: format!("Killed {} process(es) on port {port}", pids.len()),
    }
}
