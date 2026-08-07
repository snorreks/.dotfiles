//! Pomodoro timer status for waybar.
//!
//! The old module spawned `tomato -t` every second. tomato-c keeps its state
//! in `~/.local/share/tomato/time.log` (e.g. "24:59", or "00:00" when idle),
//! so we read that one tiny file on a 1s tick and emit only on change.

use crate::waybar::emit;
use std::path::PathBuf;
use tokio::time::{sleep, Duration};

fn log_path() -> PathBuf {
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home).join(".local/share/tomato/time.log");
    }
    PathBuf::from("/tmp/tomato-time.log")
}

/// `sys-daemon waybar tomato` — emits JSON on change only.
pub async fn waybar_stream() -> anyhow::Result<()> {
    let path = log_path();
    let mut last = String::new();
    loop {
        let time = std::fs::read_to_string(&path).unwrap_or_default();
        let time = time.trim();
        let running = !time.is_empty() && time != "00:00";

        let text = if running { time.to_string() } else { String::new() };
        let tooltip = if running {
            format!("🍅 Pomodoro — {time} left")
        } else {
            "🍅 Pomodoro".to_string()
        };
        let class = if running { "tomato-active" } else { "tomato-idle" };

        let sig = format!("{text}|{tooltip}|{class}");
        if sig != last {
            emit(&text, &tooltip, class);
            last = sig;
        }
        sleep(Duration::from_secs(1)).await;
    }
}
