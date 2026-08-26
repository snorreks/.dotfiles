//! Power profile for waybar — event-driven.
//!
//! Instead of `powerprofilesctl get` every N seconds (a subprocess spawn),
//! this subscribes to `net.hadess.PowerProfiles` on the system bus and
//! watches the `ActiveProfile` property via `PropertiesChanged`. It only
//! emits a waybar JSON line when the profile actually changes.
//!
//! Also supports `sys-daemon power set <profile>` and `sys-daemon power cycle`
//! for interactive use (waybar on-click bindings).

use crate::waybar::emit;
use futures_util::StreamExt;
use tokio::time::Duration;
use zbus::{Connection, MessageStream};

const PPD_DEST: &str = "net.hadess.PowerProfiles";
const PPD_PATH: &str = "/net/hadess/PowerProfiles";
const PPD_IFACE: &str = "net.hadess.PowerProfiles";

/// Read the current active profile via D-Bus Properties.Get.
async fn read_active_profile(conn: &Connection) -> Option<String> {
    let reply = conn
        .call_method(
            Some(PPD_DEST),
            PPD_PATH,
            Some("org.freedesktop.DBus.Properties"),
            "Get",
            &(PPD_IFACE, "ActiveProfile"),
        )
        .await
        .ok()?;
    let value: zbus::zvariant::OwnedValue = reply.body().deserialize().ok()?;
    if let zbus::zvariant::Value::Str(s) = &*value {
        Some(s.to_string())
    } else {
        None
    }
}

/// Read the list of available profile IDs.
///
/// PPD's Profiles property is `a(sss)` — array of (id, description, icon).
/// We deserialize the variant body, then downcast to the inner type.
async fn read_profiles(conn: &Connection) -> Option<Vec<String>> {
    let reply = conn
        .call_method(
            Some(PPD_DEST),
            PPD_PATH,
            Some("org.freedesktop.DBus.Properties"),
            "Get",
            &(PPD_IFACE, "Profiles"),
        )
        .await
        .ok()?;
    let value: zbus::zvariant::OwnedValue = reply.body().deserialize().ok()?;
    // Walk the Value tree: Array -> each element is a Structure -> first field is the ID.
    if let zbus::zvariant::Value::Array(arr) = &*value {
        let ids: Vec<String> = arr
            .iter()
            .filter_map(|v| {
                if let zbus::zvariant::Value::Structure(st) = v {
                    if let Some(zbus::zvariant::Value::Str(s)) = st.fields().first() {
                        Some(s.to_string())
                    } else {
                        None
                    }
                } else {
                    None
                }
            })
            .collect();
        if ids.is_empty() { None } else { Some(ids) }
    } else {
        None
    }
}

/// Write the ActiveProfile property (used by `power set` and `power cycle`).
async fn set_active_profile(conn: &Connection, profile: &str) -> anyhow::Result<()> {
    conn.call_method(
        Some(PPD_DEST),
        PPD_PATH,
        Some("org.freedesktop.DBus.Properties"),
        "Set",
        &(PPD_IFACE, "ActiveProfile", zbus::zvariant::Value::Str(profile.into())),
    )
    .await?;
    Ok(())
}

fn render(profile: &str) -> (String, String, &'static str) {
    match profile {
        "performance" => (
            "󰓅".into(), // nf-fa-bolt
            "Power Mode: Performance".into(),
            "power-performance",
        ),
        "power-saver" => (
            "󰾆".into(), // nf-md-battery_saver
            "Power Mode: Power Saver".into(),
            "power-saver",
        ),
        _ => (
            "󰖣".into(), // nf-md-leaf (balanced)
            "Power Mode: Balanced".into(),
            "power-balanced",
        ),
    }
}

/// `sys-daemon waybar power` — long-lived stream; emits JSON on change only.
pub async fn waybar_stream() -> anyhow::Result<()> {
    let conn = match zbus::connection::Builder::system() {
        Ok(builder) => match builder.build().await {
            Ok(conn) => conn,
            Err(e) => {
                eprintln!("sys-daemon power: system bus unavailable ({e}); falling back to poll");
                let mut tick = tokio::time::interval(Duration::from_secs(10));
                tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                emit("󰚩", "Power Profiles: Bus unavailable", "power-unknown");
                loop {
                    tick.tick().await;
                }
            }
        },
        Err(e) => {
            eprintln!("sys-daemon power: system bus unavailable ({e}); falling back to poll");
            let mut tick = tokio::time::interval(Duration::from_secs(10));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            emit("󰚩", "Power Profiles: Bus unavailable", "power-unknown");
            loop {
                tick.tick().await;
            }
        }
    };

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<()>();
    let _keepalive = tx.clone();

    // Subscribe to PropertiesChanged on the PPD path.
    if let Ok(proxy) = zbus::fdo::DBusProxy::new(&conn).await {
        let rule_str = format!(
            "interface='org.freedesktop.DBus.Properties',path='{}'",
            PPD_PATH
        );
        if let Ok(rule) = zbus::OwnedMatchRule::try_from(rule_str.as_str()) {
            if proxy.add_match_rule(rule.into()).await.is_err() {
                eprintln!("sys-daemon power: failed to add match rule");
            }
        }
        let tx = tx.clone();
        let signal_conn = conn.clone();
        tokio::spawn(async move {
            let mut stream = MessageStream::from(&signal_conn);
            while stream.next().await.is_some() {
                if tx.send(()).is_err() {
                    break;
                }
            }
        });
    }

    // Safety tick: re-read every 30s in case a signal was missed.
    let mut tick = tokio::time::interval(Duration::from_secs(30));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    let mut current = read_active_profile(&conn).await.unwrap_or_default();
    let (text, tooltip, class) = render(&current);
    emit(&text, &tooltip, class);

    loop {
        tokio::select! {
            _ = rx.recv() => {}
            _ = tick.tick() => {}
        }
        if let Some(next) = read_active_profile(&conn).await {
            if next != current {
                current = next;
                let (text, tooltip, class) = render(&current);
                emit(&text, &tooltip, class);
            }
        }
    }
}

/// `sys-daemon power set <profile>` — write the ActiveProfile property.
pub async fn set(args: &[String]) -> anyhow::Result<()> {
    let profile = args.get(3).map(|s| s.as_str()).unwrap_or("");
    if profile.is_empty() {
        eprintln!("usage: sys-daemon power set <performance|balanced|power-saver>");
        std::process::exit(2);
    }
    let conn = zbus::connection::Builder::system()?
        .build()
        .await?;
    set_active_profile(&conn, profile).await?;
    Ok(())
}

/// `sys-daemon power cycle` — rotate to the next available profile.
pub async fn cycle() -> anyhow::Result<()> {
    let conn = zbus::connection::Builder::system()?
        .build()
        .await?;

    let current = read_active_profile(&conn).await.unwrap_or_default();
    let profiles = read_profiles(&conn).await.unwrap_or_default();

    if profiles.is_empty() {
        eprintln!("sys-daemon power: no profiles available");
        std::process::exit(1);
    }

    // Find the current profile index, then advance by one (wrapping).
    let next = if let Some(idx) = profiles.iter().position(|p| p == &current) {
        &profiles[(idx + 1) % profiles.len()]
    } else {
        &profiles[0]
    };

    set_active_profile(&conn, next).await?;
    let (text, tooltip, class) = render(next);
    // Print to stdout so a one-shot waybar exec can pick it up, but the
    // streaming waybar process will also see the PropertiesChanged signal.
    println!("{}", serde_json::json!({"text": text, "tooltip": tooltip, "class": class}));
    Ok(())
}
