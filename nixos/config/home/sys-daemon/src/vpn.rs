//! VPN status for waybar — event-driven.
//!
//! Instead of `systemctl is-active` every 2s (a subprocess spawn), this
//! subscribes to systemd's D-Bus signals for the `wg-quick-wg0.service`
//! unit and watches the toggle scripts' marker files (`vpn-busy`,
//! `current-vpn-server`) with inotify. It only recomputes on real events,
//! plus a 30s safety tick to catch anything missed.

use crate::waybar::emit;
use futures_util::StreamExt;
use std::path::PathBuf;
use tokio::time::Duration;
use zbus::{Connection, MessageStream};

const SYSTEMD_DEST: &str = "org.freedesktop.systemd1";
const SYSTEMD_MANAGER_IFACE: &str = "org.freedesktop.systemd1.Manager";
const SYSTEMD_UNIT_IFACE: &str = "org.freedesktop.systemd1.Unit";
const UNIT: &str = "wg-quick-wg0.service";

fn runtime_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        return PathBuf::from(dir);
    }
    PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() }))
}

fn read_file(path: &PathBuf) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Resolve the unit's object path via systemd Manager.GetUnit.
async fn unit_path(conn: &Connection) -> Option<zbus::zvariant::OwnedObjectPath> {
    let reply = conn
        .call_method(
            Some(SYSTEMD_DEST),
            "/org/freedesktop/systemd1",
            Some(SYSTEMD_MANAGER_IFACE),
            "GetUnit",
            &(UNIT,),
        )
        .await
        .ok()?;
    reply
        .body()
        .deserialize::<zbus::zvariant::OwnedObjectPath>()
        .ok()
}

#[derive(Debug, PartialEq, Eq, Clone)]
struct State {
    busy: bool,
    active: String,
    server: Option<String>,
}

async fn query_state(conn: Option<&Connection>) -> State {
    let busy = runtime_dir().join("vpn-busy").exists();
    let server = read_file(&runtime_dir().join("current-vpn-server"));
    let mut active = "inactive".to_string();
    if let Some(conn) = conn {
        if let Some(path) = unit_path(conn).await {
            if let Ok(reply) = conn
                .call_method(
                    Some(SYSTEMD_DEST),
                    path.as_str(),
                    Some("org.freedesktop.DBus.Properties"),
                    "Get",
                    &(SYSTEMD_UNIT_IFACE, "ActiveState"),
                )
                .await
            {
                if let Ok(value) =
                    reply.body().deserialize::<zbus::zvariant::OwnedValue>()
                {
                    if let zbus::zvariant::Value::Str(s) = &*value {
                        active = s.to_string();
                    }
                }
            }
        }
    }
    State { busy, active, server }
}

fn render(state: &State) -> (String, String, &'static str) {
    if state.busy {
        return (
            "󰑮".into(),
            "VPN: Connecting / Switching...".into(),
            "vpn-loading",
        );
    }
    match state.active.as_str() {
        "active" => {
            let tooltip = match &state.server {
                Some(server) => format!("VPN Connected (ProtonVPN — {server})"),
                None => "VPN Connected (ProtonVPN wg0)".into(),
            };
            ("󰌾".into(), tooltip, "vpn-on")
        }
        "activating" | "deactivating" | "reloading" => (
            "󰑮".into(),
            "VPN: Changing state...".into(),
            "vpn-loading",
        ),
        "failed" | "maintenance" => ("󰅚".into(), "VPN Connection Failed!".into(), "vpn-failed"),
        _ => (
            "󰌿".into(),
            "VPN Disconnected\nLeft Click: Connect\nRight Click: Rotate Server".into(),
            "vpn-off",
        ),
    }
}

/// `sys-daemon waybar vpn` — long-lived stream; emits JSON on change only.
pub async fn waybar_stream() -> anyhow::Result<()> {
    // D-Bus is non-fatal: without it we fall back to a 2s poll.
    let conn = match zbus::connection::Builder::system() {
        Ok(builder) => match builder.build().await {
            Ok(conn) => Some(conn),
            Err(e) => {
                eprintln!("sys-daemon vpn: system bus unavailable ({e}); falling back to poll");
                None
            }
        },
        Err(e) => {
            eprintln!("sys-daemon vpn: system bus unavailable ({e}); falling back to poll");
            None
        }
    };

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<()>();
    // Keep the channel open even if every watcher task exits.
    let _keepalive = tx.clone();

    if let Some(conn) = &conn {
        let conn = conn.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            let rules = [
                // PropertiesChanged on unit objects (ActiveState transitions)
                "interface='org.freedesktop.DBus.Properties',path_namespace='/org/freedesktop/systemd1/unit'",
                // JobRemoved (start/stop jobs complete)
                "interface='org.freedesktop.systemd1.Manager',member='JobRemoved',path='/org/freedesktop/systemd1'",
            ];
            if let Ok(proxy) = zbus::fdo::DBusProxy::new(&conn).await {
                for rule_str in rules {
                    match zbus::OwnedMatchRule::try_from(rule_str) {
                        Ok(rule) => {
                            if proxy.add_match_rule(rule.into()).await.is_err() {
                                eprintln!("sys-daemon vpn: failed to add match rule {rule_str}");
                            }
                        }
                        Err(e) => eprintln!("sys-daemon vpn: bad match rule: {e}"),
                    }
                }
            }
            let mut stream = MessageStream::from(&conn);
            while stream.next().await.is_some() {
                if tx.send(()).is_err() {
                    break;
                }
            }
        });
    }

    // Watch XDG_RUNTIME_DIR for the toggle scripts' marker files.
    {
        let dir = runtime_dir();
        let tx = tx.clone();
        tokio::task::spawn_blocking(move || {
            let mut watcher = match inotify::Inotify::init() {
                Ok(w) => w,
                Err(_) => return,
            };
            use inotify::WatchMask;
            if watcher
                .watches()
                .add(
                    &dir,
                    WatchMask::CREATE
                        | WatchMask::DELETE
                        | WatchMask::MODIFY
                        | WatchMask::MOVED_TO
                        | WatchMask::MOVED_FROM,
                )
                .is_err()
            {
                return;
            }
            let mut buf = [0u8; 4096];
            loop {
                match watcher.read_events_blocking(&mut buf) {
                    Ok(_) => {
                        if tx.send(()).is_err() {
                            break;
                        }
                    }
                    Err(_) => break, // watch broken; exit quietly
                }
            }
        });
    }

    let safety_interval = if conn.is_some() {
        Duration::from_secs(30)
    } else {
        Duration::from_secs(2)
    };
    let mut tick = tokio::time::interval(safety_interval);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    let mut state = query_state(conn.as_ref()).await;
    let (text, tooltip, class) = render(&state);
    emit(&text, &tooltip, class);

    loop {
        tokio::select! {
            _ = rx.recv() => {}
            _ = tick.tick() => {}
        }
        let next = query_state(conn.as_ref()).await;
        if next != state {
            state = next;
            let (text, tooltip, class) = render(&state);
            emit(&text, &tooltip, class);
        }
    }
}
