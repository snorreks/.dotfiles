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
/// Times out after 3s so we never block waybar startup.
async fn read_active_profile(conn: &Connection) -> Option<String> {
    let reply = match tokio::time::timeout(
        Duration::from_secs(3),
        conn.call_method(
            Some(PPD_DEST),
            PPD_PATH,
            Some("org.freedesktop.DBus.Properties"),
            "Get",
            &(PPD_IFACE, "ActiveProfile"),
        ),
    )
    .await
    {
        Ok(Ok(reply)) => reply,
        _ => return None,
    };
    let value: zbus::zvariant::OwnedValue = reply.body().deserialize().ok()?;
    if let zbus::zvariant::Value::Str(s) = &*value {
        Some(s.to_string())
    } else {
        None
    }
}

/// Read the list of available profile IDs.
///
/// PPD's Profiles property is `aa{sv}` — array of dicts, each with a
/// "Profile" key (plus CpuDriver/PlatformDriver/Degraded, which we ignore).
/// We deserialize the variant body, then downcast to the inner type.
async fn read_profiles(conn: &Connection) -> Option<Vec<String>> {
    let reply = match tokio::time::timeout(
        Duration::from_secs(3),
        conn.call_method(
            Some(PPD_DEST),
            PPD_PATH,
            Some("org.freedesktop.DBus.Properties"),
            "Get",
            &(PPD_IFACE, "Profiles"),
        ),
    )
    .await
    {
        Ok(Ok(reply)) => reply,
        _ => return None,
    };
    let value: zbus::zvariant::OwnedValue = reply.body().deserialize().ok()?;
    // Walk the Value tree: Array -> each element is a Dict -> "Profile" key is the ID.
    if let zbus::zvariant::Value::Array(arr) = &*value {
        let ids: Vec<String> = arr
            .iter()
            .filter_map(|v| {
                if let zbus::zvariant::Value::Dict(dict) = v {
                    // Values in an a{sv} dict arrive variant-boxed (Value::Value),
                    // one extra layer to unwrap before hitting the inner Str.
                    dict.iter().find_map(|(k, v)| match (k, v) {
                        (zbus::zvariant::Value::Str(k), zbus::zvariant::Value::Value(inner))
                            if k.as_str() == "Profile" =>
                        {
                            if let zbus::zvariant::Value::Str(s) = inner.as_ref() {
                                Some(s.to_string())
                            } else {
                                None
                            }
                        }
                        _ => None,
                    })
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
/// Times out after 3s.
async fn set_active_profile(conn: &Connection, profile: &str) -> anyhow::Result<()> {
    tokio::time::timeout(
        Duration::from_secs(3),
        conn.call_method(
            Some(PPD_DEST),
            PPD_PATH,
            Some("org.freedesktop.DBus.Properties"),
            "Set",
            &(PPD_IFACE, "ActiveProfile", zbus::zvariant::Value::Str(profile.into())),
        ),
    )
    .await
    .map_err(|_| anyhow::anyhow!("PPD D-Bus call timed out"))??;
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
            "󰌪".into(), // nf-md-leaf (balanced)
            "Power Mode: Balanced".into(),
            "power-balanced",
        ),
    }
}

/// Every await on the startup path gets a hard timeout: `restart-interval`
/// only re-runs the module once the process *exits*, so a hang here (e.g. a
/// cold/idled-out power-profiles-daemon taking its time to bus-activate)
/// would otherwise blank the waybar pill forever instead of just degrading.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

/// `sys-daemon waybar power` — long-lived stream; emits JSON on change only.
pub async fn waybar_stream() -> anyhow::Result<()> {
    let build = async {
        let builder = zbus::connection::Builder::system()?;
        builder.build().await
    };
    let conn = match tokio::time::timeout(CONNECT_TIMEOUT, build).await {
        Ok(Ok(conn)) => conn,
        Ok(Err(e)) => {
            eprintln!("sys-daemon power: system bus unavailable ({e}); falling back to poll");
            let mut tick = tokio::time::interval(Duration::from_secs(10));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            emit("󰚩", "Power Profiles: Bus unavailable", "power-unknown");
            loop {
                tick.tick().await;
            }
        }
        Err(_) => {
            eprintln!("sys-daemon power: system bus connect timed out; falling back to poll");
            let mut tick = tokio::time::interval(Duration::from_secs(10));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            emit("󰚩", "Power Profiles: Bus unavailable", "power-unknown");
            loop {
                tick.tick().await;
            }
        }
    };

    // Subscribe to PropertiesChanged on the PPD path.
    //
    // ── The runaway this replaces ─────────────────────────────────────────
    // This used to be `MessageStream::from(&conn)`, which yields EVERY message
    // the connection sees — the AddMatch rule filters what the bus forwards,
    // but it does nothing about our own traffic on that same socket. So each
    // wakeup ran read_active_profile(), whose method-return came back down the
    // very stream that was being awaited, which woke the loop, which issued
    // another Get. A self-sustaining spin: three of these were measured at
    // ~40% of a core each, and the Get storm drove power-profiles-daemon
    // itself to 117% (killing the streams dropped PPD to ~19%).
    //
    // Two independent fixes, either of which breaks the cycle:
    //   1. `for_match_rule` yields only messages matching the rule. A method
    //      return has no interface member, so our own replies never match.
    //   2. The profile is read straight out of the signal body. In steady
    //      state there is now no Get at all — nothing to feed back.
    // A dedicated connection would be a third, but with 1+2 in place the
    // shared one carries no traffic that can retrigger anything.
    let signals = {
        let rule: zbus::OwnedMatchRule = zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .interface("org.freedesktop.DBus.Properties")?
            .member("PropertiesChanged")?
            .path(PPD_PATH)?
            .build()
            .into();
        match tokio::time::timeout(
            CONNECT_TIMEOUT,
            MessageStream::for_match_rule(rule, &conn, Some(16)),
        )
        .await
        {
            Ok(Ok(stream)) => Some(stream),
            _ => {
                // Best-effort: the 30s safety tick below still keeps the pill
                // live, just not instantly.
                eprintln!("sys-daemon power: failed to subscribe to PropertiesChanged");
                None
            }
        }
    };

    // Safety tick: re-read every 30s in case a signal was missed. Deliberately
    // the ONLY thing that issues a Get once running.
    let mut tick = tokio::time::interval(Duration::from_secs(30));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    let mut current = read_active_profile(&conn).await.unwrap_or_default();
    let (text, tooltip, class) = render(&current);
    emit(&text, &tooltip, class);

    let mut signals = signals;
    loop {
        // `next` on an Option<Stream> that is None must never resolve, or the
        // select! would spin on it; hence the pending() arm.
        let next_profile = tokio::select! {
            msg = async {
                match signals.as_mut() {
                    Some(s) => s.next().await,
                    None => std::future::pending().await,
                }
            } => msg.and_then(|m| m.ok()).and_then(|m| active_profile_from_signal(&m)),
            _ = tick.tick() => read_active_profile(&conn).await,
        };

        // A PropertiesChanged that didn't carry ActiveProfile (PPD also emits
        // for PerformanceDegraded and friends) yields None — that is not a
        // reason to go ask the bus, it is a reason to do nothing.
        if let Some(next) = next_profile {
            if next != current {
                current = next;
                let (text, tooltip, class) = render(&current);
                emit(&text, &tooltip, class);
            }
        }
    }
}

/// Pull `ActiveProfile` out of a `PropertiesChanged` body — signature
/// `sa{sv}as`: (interface, changed, invalidated). Returns None when the signal
/// is for another interface or doesn't mention ActiveProfile at all, which is
/// the common case and must stay a no-op.
fn active_profile_from_signal(msg: &zbus::Message) -> Option<String> {
    let body = msg.body();
    let (iface, changed, _invalidated): (
        String,
        std::collections::HashMap<String, zbus::zvariant::OwnedValue>,
        Vec<String>,
    ) = body.deserialize().ok()?;

    if iface != PPD_IFACE {
        return None;
    }
    match &**changed.get("ActiveProfile")? {
        zbus::zvariant::Value::Str(s) => Some(s.to_string()),
        _ => None,
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
