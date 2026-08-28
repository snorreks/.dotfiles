//! sys-daemon — event-driven system status daemon.
//!
//! One small async Rust binary replaces every polling loop in this setup:
//!
//! ```text
//!   OLD                                     NEW
//!   ─────────────────────────────────────── ─────────────────────────────
//!   bun local-port-checker                  sys-daemon serve
//!     23 TCP connects / 5s                    /proc/net/tcp parse on change
//!     browser location.reload / 5s            SSE push, no reloads
//!   waybar custom/vpn (interval=2)           sys-daemon waybar vpn
//!     systemctl is-active spawn / 2s          systemd D-Bus subscription
//!   waybar custom/light (interval=2)         sys-daemon waybar light
//!     bash + brightnessctl + pgrep / 2s       sysfs + /proc reads / 1s
//!   waybar custom/tomato (interval=1)        sys-daemon waybar tomato
//!     tomato -t spawn / 1s                    ~/.local/share/tomato read
//!   (nothing — no idle/sleep automation)      sys-daemon idle-guard
//!                                              swayidle timeout, event-driven retry
//! ```
//!
//! Every `waybar` subcommand is a long-lived process that only writes a JSON
//! line to stdout when the state actually changed. Waybar's custom module
//! `exec` reads those lines as updates ("if no interval or signal is defined,
//! it is assumed that the out script loops itself").
//!
//! `idle-guard` is run once by swayidle when the seat goes idle past its
//! timeout; it re-checks on its own retry interval (not a tight poll) rather
//! than suspending blindly, since seat idle says nothing about whether a
//! herdr agent or a download is still active. See `idle.rs`.

mod config;
mod http;
mod idle;
mod light;
mod ports;
mod power;
mod tomato;
mod vpn;
mod waybar;

use std::env;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(|s| s.as_str()) {
        Some("serve") => http::serve().await,
        Some("idle-guard") => idle::guard().await,
        Some("idle-check") => idle::check().await,
        Some("power") => match args.get(2).map(|s| s.as_str()) {
            Some("set") => power::set(&args).await,
            Some("cycle") => power::cycle().await,
            Some(other) => {
                eprintln!(
                    "sys-daemon power: unknown subcommand {other:?} (expected set | cycle)"
                );
                std::process::exit(2);
            }
            None => {
                eprintln!("usage: sys-daemon power <set <profile> | cycle>");
                std::process::exit(2);
            }
        },
        Some("waybar") => match args.get(2).map(|s| s.as_str()) {
            Some("ports") => ports::waybar_stream().await,
            Some("vpn") => vpn::waybar_stream().await,
            Some("light") => light::waybar_stream().await,
            Some("tomato") => tomato::waybar_stream().await,
            Some("power") => power::waybar_stream().await,
            other => {
                eprintln!(
                    "sys-daemon waybar: unknown module {other:?} (expected ports | vpn | light | tomato | power)"
                );
                std::process::exit(2);
            }
        },
        Some(other) => {
            eprintln!(
                "sys-daemon: unknown subcommand {other:?} (expected serve | idle-guard | idle-check | waybar | power)"
            );
            std::process::exit(2);
        }
        None => {
            eprintln!(
                "usage: sys-daemon <serve | idle-guard | idle-check | waybar <ports | vpn | light | tomato | power> | power <set <profile> | cycle>>"
            );
            std::process::exit(2);
        }
    }
}
