//! Shared waybar JSON output helpers.

use serde::Serialize;

#[derive(Serialize)]
struct Output {
    text: String,
    tooltip: String,
    class: String,
}

/// Print one waybar JSON object (newline-terminated). Waybar reads each line
/// as a module update. We only call this when the state changed.
pub fn emit(text: &str, tooltip: &str, class: &str) {
    let out = Output {
        text: text.to_string(),
        tooltip: tooltip.to_string(),
        class: class.to_string(),
    };
    match serde_json::to_string(&out) {
        Ok(line) => println!("{line}"),
        Err(e) => eprintln!("sys-daemon: failed to serialize waybar output: {e}"),
    }
}
