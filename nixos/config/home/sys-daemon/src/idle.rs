//! Idle-triggered suspend gate.
//!
//! swayidle fires `sys-daemon idle-guard` once the seat has been idle for
//! the configured timeout (see `idle.nix`). Seat idle only means "no
//! keyboard/mouse input" — it says nothing about whether a herdr agent is
//! mid-turn, a movie is playing, a build is compiling, or a download is in
//! flight, all of which happen with zero input. So this doesn't suspend on
//! the first call: it re-checks on a retry interval until herdr, media
//! playback, CPU load, network throughput, and disk I/O all clear, then
//! suspends. swayidle's `resume` handler kills this process on real user
//! activity, so a slow retry loop never races a manual wake-up.

use serde::Deserialize;
use std::time::Duration;
use tokio::process::Command;

const RETRY_INTERVAL: Duration = Duration::from_secs(5 * 60);
const SAMPLE_WINDOW: Duration = Duration::from_secs(2);
/// Sustained throughput above this (rx+tx summed across all non-loopback
/// interfaces) counts as "actively downloading/uploading".
const NET_BUSY_THRESHOLD_BYTES_PER_SEC: u64 = 300_000; // ~2.4 Mbit/s
/// 1-minute load average divided by core count above this counts as
/// "actively computing" (a build, render, or encode job).
const CPU_BUSY_LOAD_PER_CORE: f64 = 0.5;
/// Milliseconds of the sample window any block device spent with at least
/// one I/O in flight (io_ticks, same signal `iostat`'s %util is built from)
/// counts as "actively reading/writing". Catches a slow/stuck write that
/// throughput sampling would miss entirely — that's exactly what caused a
/// failed-suspend hard-hang here once: a game's async file-IO thread stuck
/// mid-write to an ntfs3 mount blocked the suspend freezer for ~100s and
/// left the compositor wedged. See the systemd fix in power-management.nix
/// for the other half of that incident.
const DISK_BUSY_MS_PER_SAMPLE: u64 = 400;

#[derive(Deserialize)]
struct AgentListReply {
    result: AgentListResult,
}

#[derive(Deserialize)]
struct AgentListResult {
    agents: Vec<AgentEntry>,
}

#[derive(Deserialize)]
struct AgentEntry {
    agent: String,
    agent_status: String,
}

#[derive(Debug)]
enum Blocker {
    HerdrAgent,
    Media,
    Cpu,
    Network,
    Disk,
}

impl Blocker {
    fn reason(&self) -> &'static str {
        match self {
            Blocker::HerdrAgent => "a herdr agent is actively working",
            Blocker::Media => "media is actively playing (movie/video/music)",
            Blocker::Cpu => "sustained CPU load (looks like a build/render/compile job)",
            Blocker::Network => "sustained network throughput (looks like a download)",
            Blocker::Disk => "active disk I/O (something is reading/writing right now)",
        }
    }
}

async fn herdr_agents() -> Vec<AgentEntry> {
    let Ok(output) = Command::new("herdr").args(["agent", "list"]).output().await else {
        return Vec::new(); // herdr not installed/running
    };
    if !output.status.success() {
        return Vec::new();
    }
    serde_json::from_slice::<AgentListReply>(&output.stdout)
        .map(|reply| reply.result.agents)
        .unwrap_or_default()
}

/// Counts processes whose `/proc/<pid>/comm` is exactly `pi` — the LLM CLI
/// this setup runs everything through, not just an abbreviation.
fn count_pi_processes() -> usize {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return 0;
    };
    entries
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().parse::<u32>().is_ok())
        .filter(|entry| {
            std::fs::read_to_string(entry.path().join("comm"))
                .map(|comm| comm.trim() == "pi")
                .unwrap_or(false)
        })
        .count()
}

/// `working` blocks sleep directly. `blocked` means the agent is paused
/// waiting on you — nothing is being computed, so suspending costs nothing.
/// `idle`/`done` are obviously fine too.
///
/// But herdr only knows about panes it manages (`herdr tab create` etc).
/// A pipeline can also run `pi` as a raw detached subprocess with no herdr
/// pane at all — invisible to `agent_status`, but still doing real work
/// (this actually happened: a contract-pipeline background implementer run
/// went unnoticed and idle-guard blanked the screen mid-task). herdr's PID
/// isn't exposed, so PID-level correlation isn't possible — instead, count
/// live `pi` processes system-wide and compare against how many herdr
/// tracks. Any excess is an untracked run; block for as long as it exists
/// since there's no way to ask it whether it's actually mid-turn.
async fn herdr_busy() -> bool {
    let agents = herdr_agents().await;
    if agents.iter().any(|a| a.agent_status == "working") {
        return true;
    }
    let tracked = agents.iter().filter(|a| a.agent == "pi").count();
    count_pi_processes() > tracked
}

/// Same MPRIS query waybar's own `mpris` module reads (D-Bus, no polling
/// there — this is a one-shot check, not a subscription, so `playerctl` is
/// the simpler fit here). Neither CPU nor network reliably catches "a movie
/// is playing": hardware decode is cheap, and streaming bitrate is bursty
/// enough to duck under the network threshold in a given sample window.
async fn media_playing() -> bool {
    let Ok(output) = Command::new("playerctl")
        .args(["-a", "status"])
        .output()
        .await
    else {
        return false; // no players / playerctl unavailable: nothing to block on
    };
    if !output.status.success() {
        return false;
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|line| line.trim() == "Playing")
}

/// Suspend just freezes/resumes a CPU-bound process untouched, so this isn't
/// about data loss — it's about not silently pausing a build/render for
/// hours because it left no network trace and no herdr agent involved.
fn cpu_busy() -> bool {
    let Ok(text) = std::fs::read_to_string("/proc/loadavg") else {
        return false;
    };
    let Some(load1) = text
        .split_whitespace()
        .next()
        .and_then(|s| s.parse::<f64>().ok())
    else {
        return false;
    };
    let cores = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1) as f64;
    load1 / cores > CPU_BUSY_LOAD_PER_CORE
}

fn read_net_bytes() -> u64 {
    let Ok(entries) = std::fs::read_dir("/sys/class/net") else {
        return 0;
    };
    let mut total = 0u64;
    for entry in entries.flatten() {
        if entry.file_name() == "lo" {
            continue;
        }
        for stat in ["rx_bytes", "tx_bytes"] {
            let path = entry.path().join("statistics").join(stat);
            if let Ok(text) = std::fs::read_to_string(&path) {
                total += text.trim().parse::<u64>().unwrap_or(0);
            }
        }
    }
    total
}

async fn network_busy() -> bool {
    let before = read_net_bytes();
    tokio::time::sleep(SAMPLE_WINDOW).await;
    let after = read_net_bytes();
    let rate = after.saturating_sub(before) / SAMPLE_WINDOW.as_secs().max(1);
    rate > NET_BUSY_THRESHOLD_BYTES_PER_SEC
}

/// Sum of `io_ticks` (field 10, 0-indexed 9, of `/sys/block/*/stat` — same
/// layout as `/proc/diskstats`) across all non-virtual block devices: total
/// milliseconds each device had an I/O outstanding. A live gauge, not a
/// throughput rate, so it catches I/O that's slow/stuck rather than fast.
fn read_disk_io_ticks() -> u64 {
    let Ok(entries) = std::fs::read_dir("/sys/block") else {
        return 0;
    };
    let mut total = 0u64;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with("loop") || name.starts_with("ram") {
            continue;
        }
        let path = entry.path().join("stat");
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Some(ticks) = text.split_whitespace().nth(9) {
                total += ticks.parse::<u64>().unwrap_or(0);
            }
        }
    }
    total
}

async fn disk_busy() -> bool {
    let before = read_disk_io_ticks();
    tokio::time::sleep(SAMPLE_WINDOW).await;
    let after = read_disk_io_ticks();
    after.saturating_sub(before) > DISK_BUSY_MS_PER_SAMPLE
}

async fn blocker() -> Option<Blocker> {
    // Cheapest checks first; only pay for the multi-second samples if
    // nothing else already blocks. Network and disk both just diff a
    // counter across the same window, so sample them concurrently rather
    // than paying 2x the wall-clock time.
    if herdr_busy().await {
        return Some(Blocker::HerdrAgent);
    }
    if media_playing().await {
        return Some(Blocker::Media);
    }
    if cpu_busy() {
        return Some(Blocker::Cpu);
    }
    let (net_busy, disk_busy) = tokio::join!(network_busy(), disk_busy());
    if net_busy {
        return Some(Blocker::Network);
    }
    if disk_busy {
        return Some(Blocker::Disk);
    }
    None
}

/// `sys-daemon idle-check` — one-shot decision printer for manual testing.
/// Exits 0 and prints `clear` if suspend is safe, exits 1 and prints the
/// reason otherwise.
pub async fn check() -> anyhow::Result<()> {
    match blocker().await {
        Some(b) => {
            println!("blocked: {}", b.reason());
            std::process::exit(1);
        }
        None => {
            println!("clear");
            Ok(())
        }
    }
}

async fn suspend() -> anyhow::Result<()> {
    let conn = zbus::connection::Builder::system()?.build().await?;
    conn.call_method(
        Some("org.freedesktop.login1"),
        "/org/freedesktop/login1",
        Some("org.freedesktop.login1.Manager"),
        "Suspend",
        &(false,),
    )
    .await?;
    Ok(())
}

/// `sys-daemon idle-guard` — run by swayidle once the seat has been idle
/// past the configured timeout. Re-checks on `RETRY_INTERVAL` until clear,
/// then suspends via logind over D-Bus.
pub async fn guard() -> anyhow::Result<()> {
    loop {
        match blocker().await {
            Some(b) => {
                eprintln!("sys-daemon idle-guard: postponing — {}", b.reason());
                tokio::time::sleep(RETRY_INTERVAL).await;
            }
            None => {
                eprintln!("sys-daemon idle-guard: clear, suspending");
                return suspend().await;
            }
        }
    }
}
