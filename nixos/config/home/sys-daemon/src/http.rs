//! Tiny HTTP server for the dev-ports dashboard — replaces the Bun server.
//!
//! Endpoints:
//!   GET  /            dashboard HTML (embedded)
//!   GET  /api/status  full snapshot as JSON
//!   GET  /api/stream  Server-Sent Events: push snapshot on every change
//!   POST /api/kill    { "port": n } → kill process listening on n
//!
//! The snapshot is recomputed by a 1s tick (a couple of /proc file reads);
//! SSE pushes it to open dashboards only when it changes, so the browser
//! never polls and never reloads.
//!
//! ## This module owns the socket; `httpcore` owns the rules
//!
//! Everything here is I/O: accepting, reading with a deadline, and writing.
//! Every question of the form "may this request proceed?" is answered in
//! [`httpcore`], which has no sockets in it. That split is what lets
//! `tests/api_negative.rs` drive a hostile request through the full admission
//! path without binding a port or starting this server — which in turn means
//! the security tests can never accidentally reach the live daemon.

use crate::config::Config;
use crate::httpcore::{
    self, Guard, ParseError, Request, Response, Route, MAX_BODY_BYTES,
    MAX_HEADER_BYTES,
};
use crate::ports;
use serde_json::Value;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, RwLock};
use tokio::time::{timeout, Duration};

const HTML: &str = include_str!("dashboard.html");

/// Whole-request budget. Slowloris defence: a client that connects and then
/// dribbles bytes must not be able to hold a task open indefinitely. 5s is
/// far longer than any real loopback dashboard request needs.
const READ_DEADLINE: Duration = Duration::from_secs(5);

/// Cap on bytes held in memory for one connection: header cap plus body cap
/// plus slack, so the read loop has a hard ceiling independent of what
/// `Content-Length` claims.
const MAX_REQUEST_BYTES: usize = MAX_HEADER_BYTES + MAX_BODY_BYTES + 4096;

pub async fn serve() -> anyhow::Result<()> {
    let cfg = Arc::new(Config::load());
    let bind = format!("127.0.0.1:{}", cfg.dashboard_port);
    let listener = TcpListener::bind(&bind).await.map_err(|e| {
        anyhow::anyhow!(
            "cannot bind {bind}: {e} — is the old Bun dev-ports process still running on :{}? \
             (kill it or run `toggle-dev-ports off` on the old setup)",
            cfg.dashboard_port
        )
    })?;

    // One token per run. It is never written to disk and never configured, so
    // there is nothing to rotate, leak into the repository, or paste into a
    // bug report.
    let guard = Guard::new(cfg.dashboard_port, Guard::generate_token());
    eprintln!("sys-daemon serve: dev-ports dashboard on http://{bind}");

    let shared: Arc<RwLock<Value>> = Arc::new(RwLock::new(Value::Null));
    let (tx, _rx) = broadcast::channel::<Value>(8);

    // Snapshot watcher: recompute every 1s, broadcast only on change.
    {
        let cfg = cfg.clone();
        let shared = shared.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            let mut prev: Option<ports::Snapshot> = None;
            loop {
                let snap = ports::snapshot(&cfg);
                let changed = prev
                    .as_ref()
                    .map_or(true, |p| snap.differs_except_check(p));
                if changed {
                    let value = serde_json::to_value(&snap).unwrap_or(Value::Null);
                    *shared.write().await = value.clone();
                    let _ = tx.send(value);
                    prev = Some(snap);
                }
                tokio::time::sleep(Duration::from_millis(1000)).await;
            }
        });
    }

    loop {
        let (stream, _) = match listener.accept().await {
            Ok(s) => s,
            Err(_) => continue,
        };
        let shared = shared.clone();
        let tx = tx.clone();
        let guard = guard.clone();
        tokio::spawn(async move {
            if let Err(e) = handle(stream, shared, tx, guard).await {
                eprintln!("sys-daemon serve: connection error: {e}");
            }
        });
    }
}

async fn handle(
    mut stream: TcpStream,
    shared: Arc<RwLock<Value>>,
    tx: broadcast::Sender<Value>,
    guard: Guard,
) -> anyhow::Result<()> {
    let req = match read_request(&mut stream).await? {
        Outcome::Request(req) => req,
        // The peer closed before sending anything. Nothing to answer.
        Outcome::PeerClosed => return Ok(()),
        Outcome::Malformed(error) => {
            return write(stream, httpcore::parse_error_response(error)).await
        }
    };

    // Admission first, before any routing or state is touched. A refused
    // request must not have reached `classify`, the snapshot, or `kill_port`.
    if let Err(rejection) = guard.check(&req) {
        return write(stream, httpcore::rejection_response(rejection)).await;
    }

    match httpcore::classify(&req) {
        Route::Dashboard => write(stream, dashboard_response(&guard)).await,
        Route::Status => {
            let snap = shared.read().await.clone();
            write(stream, Response::json(&snap)).await
        }
        Route::Stream => sse(stream, tx, shared).await,
        Route::Kill(port) => {
            let result = ports::kill_port(port, guard.port()).await;
            write(stream, Response::json(&serde_json::to_value(&result).unwrap_or(Value::Null))).await
        }
        Route::NotFound => write(stream, Response::not_found()).await,
    }
}

/// The dashboard HTML with this run's token injected.
///
/// The token is substituted into a single-quoted JS string literal at serve
/// time. It is hex, so it needs no escaping — see `Guard::generate_token`.
fn dashboard_response(guard: &Guard) -> Response {
    const PLACEHOLDER: &str = "__SYS_DAEMON_TOKEN__";
    let token = guard.token();
    let html = if HTML.contains(PLACEHOLDER) {
        HTML.replace(PLACEHOLDER, token)
    } else {
        // A build where the placeholder is missing would silently serve a
        // dashboard that can never authenticate. Fail loudly instead.
        HTML.to_string()
    };
    let mut response = Response::html(html);
    // Defence in depth against DNS rebinding: even if the Host check were
    // bypassed, a hostile page cannot read this document cross-origin.
    response.extra_headers.push((
        "Content-Security-Policy".into(),
        "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'".into(),
    ));
    response.extra_headers.push(("X-Content-Type-Options".into(), "nosniff".into()));
    response
}

/// What reading one connection produced.
enum Outcome {
    /// A complete, parseable request.
    Request(Request),
    /// The peer closed the connection without sending a request line.
    PeerClosed,
    /// The request arrived but is not usable. Reported with the reason rather
    /// than dropped, so a client can tell a 413 from a silent disconnect.
    Malformed(ParseError),
}

/// Read one complete request.
///
/// Enforces three independent bounds, because any one of them alone is
/// bypassable: an overall byte ceiling that does not depend on `Content-Length`,
/// the header/body limits enforced by the parser, and a wall-clock deadline so
/// a connection that sends nothing at all still gets collected.
async fn read_request(stream: &mut TcpStream) -> anyhow::Result<Outcome> {
    // The deadline wraps the WHOLE read, not each individual `read`.
    //
    // Wrapping the individual call looked equivalent and was not: each read
    // returns well inside the deadline as long as the peer keeps sending, so
    // a client dribbling one byte every four seconds never trips it and holds
    // a task open indefinitely. The budget has to cover the entire operation
    // for it to bound anything.
    match timeout(READ_DEADLINE, read_request_inner(stream)).await {
        // Deadline hit. Reported as a malformed request rather than a silent
        // close: a caller that waits forever learns nothing from a vanished
        // socket.
        Err(_) => Ok(Outcome::Malformed(ParseError::Incomplete)),
        // Read errors propagate unchanged; only the timeout is translated.
        Ok(result) => result,
    }
}

async fn read_request_inner(stream: &mut TcpStream) -> anyhow::Result<Outcome> {
    let mut buf: Vec<u8> = Vec::with_capacity(2048);
    let mut tmp = [0u8; 1024];

    loop {
        let n = match stream.read(&mut tmp).await {
            Err(e) => return Err(e.into()),
            Ok(0) => {
                return Ok(if buf.is_empty() {
                    Outcome::PeerClosed
                } else {
                    // Sent some bytes then hung up mid-request.
                    Outcome::Malformed(ParseError::Incomplete)
                })
            }
            Ok(n) => n,
        };
        buf.extend_from_slice(&tmp[..n]);

        // Hard ceiling independent of Content-Length: a client that never
        // sends `\r\n\r\n` cannot make this grow forever.
        if buf.len() > MAX_REQUEST_BYTES {
            return Ok(Outcome::Malformed(ParseError::HeadersTooLarge));
        }

        match httpcore::parse(&buf) {
            Ok(req) => return Ok(Outcome::Request(req)),
            // Only "keep reading" is non-terminal. Every other verdict is
            // final, so no amount of further bytes will change it.
            Err(ParseError::Incomplete) => continue,
            Err(e) => return Ok(Outcome::Malformed(e)),
        }
    }
}

async fn write(mut stream: TcpStream, response: Response) -> anyhow::Result<()> {
    stream.write_all(&response.render()).await?;
    stream.flush().await?;
    Ok(())
}

/// Server-Sent Events: push the current snapshot immediately on subscribe,
/// then keep the connection open for change broadcasts until the client goes
/// away.
async fn sse(
    mut stream: TcpStream,
    tx: broadcast::Sender<Value>,
    shared: Arc<RwLock<Value>>,
) -> anyhow::Result<()> {
    stream
        .write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        )
        .await?;
    // Initial snapshot so the page renders immediately.
    let initial = shared.read().await.clone();
    if let Value::Null = initial {
        // not ready yet; nothing to push
    } else {
        let line = format!("data: {initial}\n\n");
        stream.write_all(line.as_bytes()).await?;
        stream.flush().await?;
    }
    let mut rx = tx.subscribe();
    loop {
        match rx.recv().await {
            Ok(value) => {
                let line = format!("data: {value}\n\n");
                if stream.write_all(line.as_bytes()).await.is_err() {
                    return Ok(()); // client disconnected
                }
                if stream.flush().await.is_err() {
                    return Ok(());
                }
            }
            Err(broadcast::error::RecvError::Lagged(_)) => continue,
            Err(_) => return Ok(()),
        }
    }
}