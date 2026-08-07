//! Configuration for the dev-ports dashboard.
//!
//! The config file lives at `~/.config/sys-daemon/ports.json` (installed by
//! Home Manager). If it is missing or broken we fall back to the embedded
//! copy so the binary is self-sufficient. Edit the file to add projects or
//! ports without rebuilding the daemon.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PortEntry {
    pub name: String,
    pub port: u16,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PortGroup {
    pub title: String,
    pub entries: Vec<PortEntry>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Project {
    pub name: String,
    pub groups: Vec<PortGroup>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    #[serde(default = "default_dashboard_port")]
    pub dashboard_port: u16,
    #[serde(default)]
    pub projects: Vec<Project>,
    /// Friendly names for well-known service ports (shown in the dashboard's
    /// "Other Running Ports" section). Real process names take precedence.
    #[serde(default)]
    pub services: HashMap<u16, String>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            dashboard_port: default_dashboard_port(),
            projects: Vec::new(),
            services: HashMap::new(),
        }
    }
}

fn default_dashboard_port() -> u16 {
    3333
}

fn config_path() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_CONFIG_HOME") {
        return PathBuf::from(dir).join("sys-daemon/ports.json");
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home).join(".config/sys-daemon/ports.json");
    }
    PathBuf::from("/tmp/sys-daemon-ports.json")
}

impl Config {
    pub fn load() -> Config {
        let path = config_path();
        match std::fs::read_to_string(&path) {
            Ok(text) => match serde_json::from_str(&text) {
                Ok(cfg) => return cfg,
                Err(e) => eprintln!(
                    "sys-daemon: invalid config {}: {e}; using defaults",
                    path.display()
                ),
            },
            Err(_) => {}
        }
        serde_json::from_str(include_str!("../ports.json")).unwrap_or_default()
    }
}
