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

use crate::config::Config;
use crate::ports;
use serde_json::Value;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, RwLock};
use tokio::time::Duration;

const HTML: &str = include_str!("dashboard.html");

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
        tokio::spawn(async move {
            if let Err(e) = handle(stream, shared, tx).await {
                eprintln!("sys-daemon serve: connection error: {e}");
            }
        });
    }
}

async fn handle(
    mut stream: TcpStream,
    shared: Arc<RwLock<Value>>,
    tx: broadcast::Sender<Value>,
) -> anyhow::Result<()> {
    let mut buf = Vec::with_capacity(2048);
    let mut tmp = [0u8; 1024];
    loop {
        match stream.read(&mut tmp).await {
            Ok(0) => return Ok(()),
            Ok(n) => {
                buf.extend_from_slice(&tmp[..n]);
                if buf.windows(4).any(|w| w == b"\r\n\r\n") || buf.len() > 65536 {
                    break;
                }
            }
            Err(e) => return Err(e.into()),
        }
    }

    let header_end = buf
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|p| p + 4)
        .unwrap_or(buf.len());

    // Read the request line + path.
    let head = String::from_utf8_lossy(&buf[..header_end]);
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or_default().to_string();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("GET").to_string();
    let path = parts.next().unwrap_or("/").split('?').next().unwrap_or("/").to_string();

    // For POST bodies: respect Content-Length and read until full.
    let mut body: Vec<u8> = Vec::new();
    if method == "POST" {
        let clen: usize = head
            .lines()
            .find_map(|l| {
                l.to_ascii_lowercase()
                    .strip_prefix("content-length:")
                    .and_then(|v| v.trim().parse().ok())
            })
            .unwrap_or(0);
        let mut rest: Vec<u8> = buf[header_end..].to_vec();
        while rest.len() < clen {
            let mut tmp = [0u8; 1024];
            match stream.read(&mut tmp).await {
                Ok(0) => break,
                Ok(n) => rest.extend_from_slice(&tmp[..n]),
                Err(e) => return Err(e.into()),
            }
        }
        body = rest[..clen.min(rest.len())].to_vec();
    }

    match (method.as_str(), path.as_str()) {
        ("GET", "/") => respond(stream, "text/html", HTML.as_bytes()).await,
        ("GET", "/api/status") => {
            let snap = shared.read().await.clone();
            respond_json(stream, &snap).await
        }
        ("GET", "/api/stream") => {
            let shared = shared.clone();
            sse(stream, tx, shared).await
        }
        ("POST", "/api/kill") => {
            let port: Option<u16> = serde_json::from_slice(&body)
                .ok()
                .and_then(|v: Value| v.get("port").and_then(|p| p.as_u64()))
                .and_then(|p| u16::try_from(p).ok());
            match port {
                Some(port) => {
                    let result = ports::kill_port(port).await;
                    respond_json(stream, &serde_json::to_value(&result).unwrap_or(Value::Null)).await
                }
                None => {
                    let body = serde_json::json!({"success": false, "message": "Invalid port"});
                    respond_json(stream, &body).await
                }
            }
        }
        _ => {
            let body =
                b"HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: close\r\n\r\n404 not found";
            stream.write_all(body).await?;
            stream.flush().await?;
            Ok(())
        }
    }
}

async fn respond(mut stream: TcpStream, content_type: &str, body: &[u8]) -> anyhow::Result<()> {
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.flush().await?;
    Ok(())
}

async fn respond_json(stream: TcpStream, value: &Value) -> anyhow::Result<()> {
    let body = serde_json::to_string(value).unwrap_or_else(|_| "{}".into());
    respond(stream, "application/json", body.as_bytes()).await
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
            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n",
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
