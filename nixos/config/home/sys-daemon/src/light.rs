//! Light / eye-protection status for waybar.
//!
//! The old module spawned `waybar-light-status.sh` (bash → brightnessctl →
//! pgrep) every 2s. This reads sysfs files directly (microseconds), checks a
//! /proc scan for wlsunset, and emits JSON only when the state changes.

use crate::waybar::emit;
use tokio::time::{sleep, Duration};

/// Best brightness percentage across all /sys/class/backlight devices.
fn backlight_percent() -> Option<u32> {
    let mut best: Option<u32> = None;
    let Ok(devices) = std::fs::read_dir("/sys/class/backlight") else {
        return None;
    };
    for device in devices.flatten() {
        let dir = device.path();
        let Ok(brightness) = std::fs::read_to_string(dir.join("brightness")) else {
            continue;
        };
        let Ok(max) = std::fs::read_to_string(dir.join("max_brightness")) else {
            continue;
        };
        let Ok(b) = brightness.trim().parse::<u64>() else { continue };
        let Ok(m) = max.trim().parse::<u64>() else { continue };
        if m == 0 {
            continue;
        }
        let pct = ((b * 100) / m) as u32;
        best = Some(best.map_or(pct, |cur| cur.max(pct)));
    }
    best
}

/// `/tmp/custom_brightness` is written by `change_brightness.sh` (5%..100%).
fn custom_brightness() -> Option<u32> {
    let text = std::fs::read_to_string("/tmp/custom_brightness").ok()?;
    text.trim().parse().ok()
}

fn wlsunset_running() -> bool {
    let Ok(proc) = std::fs::read_dir("/proc") else {
        return false;
    };
    proc.flatten().any(|entry| {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.chars().all(|c| c.is_ascii_digit()) {
            return false;
        }
        match std::fs::read_to_string(format!("/proc/{name}/comm")) {
            Ok(comm) => comm.trim() == "wlsunset",
            Err(_) => false,
        }
    })
}

fn forced() -> bool {
    std::path::Path::new("/tmp/wlsunset-forced").exists()
}

/// `sys-daemon waybar light` — emits JSON on change only (1s tick of cheap
/// file reads, no subprocesses).
pub async fn waybar_stream() -> anyhow::Result<()> {
    let mut last = String::new();
    loop {
        let pct = custom_brightness().or_else(backlight_percent).unwrap_or(50);
        let sunset = wlsunset_running();
        let is_forced = forced();

        // Icon + percentage share one color, driven entirely by the
        // `eye-*` waybar CSS class (theme/lib.nix mkWaybarCss) — no
        // hardcoded hex here, so this follows the active palette (static
        // tokyo-night or the wallpaper-derived dynamic one) instead of
        // silently staying tokyo-night-colored forever.
        let (text, tooltip, class) = if sunset {
            if is_forced {
                (
                    format!("󱩌 {pct}%"),
                    format!("<b>Eye Protection (FORCED 3500K)</b>\nBrightness: <b>{pct}%</b>"),
                    "eye-forced",
                )
            } else {
                (
                    format!("󱩌 {pct}%"),
                    format!("<b>Eye Protection (AUTO)</b>\nBrightness: <b>{pct}%</b>"),
                    "eye-on",
                )
            }
        } else {
            (
                format!("󱩍 {pct}%"),
                format!("<b>Eye Protection (OFF)</b>\nBrightness: <b>{pct}%</b>"),
                "eye-off",
            )
        };

        let sig = format!("{text}|{tooltip}|{class}");
        if sig != last {
            emit(&text, &tooltip, class);
            last = sig;
        }
        sleep(Duration::from_millis(1000)).await;
    }
}
