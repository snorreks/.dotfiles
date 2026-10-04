//! `sys-daemon` as a library, so the pieces can be tested directly.
//!
//! The binary in `main.rs` is a thin argument dispatcher over these modules.
//! Exposing them as a library is what lets `tests/` drive the HTTP admission
//! rules and the process-kill safety checks without starting the daemon, so
//! the test suite never has to talk to the live server or signal a real
//! process to find out whether either is behaving.

pub mod config;
pub mod http;
pub mod httpcore;
pub mod idle;
pub mod killsafe;
pub mod light;
pub mod ports;
pub mod power;
pub mod tomato;
pub mod vpn;
pub mod waybar;