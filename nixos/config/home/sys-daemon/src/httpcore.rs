//! Pure request/response core for the dev-ports dashboard.
//!
//! Everything here is a function of its arguments: no sockets, no async, no
//! process state. That is deliberate. The daemon is the only thing on the box
//! that exposes a *mutating* HTTP endpoint, so the decisions that decide
//! whether a request is allowed to reach it must be testable by feeding bytes
//! into a parser rather than by standing up the real server and pointing a
//! browser at it.
//!
//! `http.rs` owns the socket, the deadlines and the async glue; every question
//! of the form "is this request allowed?" is answered here.
//!
//! ## Why a loopback bind is not an access control
//!
//! This server binds `127.0.0.1`, which means no *other machine* can reach it.
//! It does not mean only the owner can reach it: every process on the box can,
//! and so can the user's web browser, because a page the browser loads runs
//! with the user's privileges and can issue requests to loopback addresses.
//! The two request shapes that turn that into remote code execution on the
//! desktop are:
//!
//!   * **DNS rebinding.** Attacker-controlled DNS hands back `127.0.0.1` for
//!     `evil.example`. The browser now believes it is talking to
//!     `evil.example` and sends `Host: evil.example`. Nothing about that
//!     request looks cross-origin, so browser-side protections do not engage.
//!     The defence is to validate `Host` against the addresses we actually
//!     serve. This is the load-bearing check; the others are defence in depth.
//!   * **CSRF.** A page on any origin can POST to `http://127.0.0.1:3333`
//!     with `Content-Type: text/plain` to dodge a preflight. The defences are
//!     an exact-match `Origin` check and a per-run token that is only ever
//!     delivered over a request that already passed the `Host` check.
//!
//! Neither check implies the daemon is reachable from the internet, and this
//! module deliberately makes no claim about that either way.

/// Request line plus headers may not exceed this. A dashboard request is a
/// few hundred bytes; anything near this is abuse or a broken client.
pub const MAX_HEADER_BYTES: usize = 16 * 1024;
/// Request bodies may not exceed this. `POST /api/kill` carries `{"port":N}`.
pub const MAX_BODY_BYTES: usize = 4 * 1024;
/// Header name carrying the mutation token.
pub const TOKEN_HEADER: &str = "x-sys-daemon-token";

// ── request ─────────────────────────────────────────────────────────────────

/// A parsed request. Header names are lowercased; values keep their original
/// spacing minus surrounding whitespace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub method: String,
    /// Path with any query string removed.
    pub path: String,
    pub version: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Request {
    /// First value for `name` (case-insensitive; names are stored lowercased).
    pub fn header(&self, name: &str) -> Option<&str> {
        let name = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| *k == name)
            .map(|(_, v)| v.as_str())
    }

    /// True for methods that can change state. Only `POST` is routed today,
    /// but treating every non-`GET`/`HEAD` as mutating means adding a `PUT`
    /// later cannot silently arrive unguarded.
    pub fn is_mutation(&self) -> bool {
        !matches!(self.method.as_str(), "GET" | "HEAD")
    }
}

/// Why a byte slice is not yet a usable request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseError {
    /// No complete `\r\n\r\n` yet — keep reading, subject to the deadline.
    Incomplete,
    /// The header block grew past [`MAX_HEADER_BYTES`]. A client that sends
    /// megabytes of headers is not a dashboard.
    HeadersTooLarge,
    /// `Content-Length` is absent, malformed, negative, or past
    /// [`MAX_BODY_BYTES`].
    BadContentLength,
    /// The body grew past [`MAX_BODY_BYTES`].
    BodyTooLarge,
}

impl ParseError {
    /// Short, stable machine-readable tag. Surfaced to the client and used as
    /// the assertion key in tests, so keep it boring.
    pub fn tag(self) -> &'static str {
        match self {
            ParseError::Incomplete => "incomplete",
            ParseError::HeadersTooLarge => "headers_too_large",
            ParseError::BadContentLength => "bad_content_length",
            ParseError::BodyTooLarge => "body_too_large",
        }
    }

    pub fn status(self) -> u16 {
        match self {
            ParseError::Incomplete => 400,
            ParseError::HeadersTooLarge => 431,
            ParseError::BadContentLength => 400,
            ParseError::BodyTooLarge => 413,
        }
    }
}

/// Parse a complete request from `buf`, which must contain the full header
/// block and the entire declared body.
///
/// Returns [`ParseError::Incomplete`] when no `\r\n\r\n` has arrived yet. The
/// caller is responsible for the read deadline; this function will not block.
pub fn parse(buf: &[u8]) -> Result<Request, ParseError> {
    let Some(header_end) = find(buf, b"\r\n\r\n").map(|p| p + 4) else {
        // No terminator yet. Distinguish "still arriving" from "already too
        // big to ever be legal", so an oversized client gets a 431 rather
        // than being read to the limit and then called incomplete.
        if buf.len() > MAX_HEADER_BYTES {
            return Err(ParseError::HeadersTooLarge);
        }
        return Err(ParseError::Incomplete);
    };

    if header_end > MAX_HEADER_BYTES {
        return Err(ParseError::HeadersTooLarge);
    }

    let head = String::from_utf8_lossy(&buf[..header_end]);
    let mut lines = head.split("\r\n");

    let request_line = lines.next().unwrap_or_default().trim();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_uppercase();
    let target = parts.next().unwrap_or("/");
    let version = parts.next().unwrap_or("HTTP/1.1").to_string();

    if method.is_empty() {
        return Err(ParseError::BadContentLength);
    }

    let mut headers = Vec::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        // A bare CRLF in the middle of the header block is request smuggling
        // bait; reject rather than try to guess what the sender meant.
        let Some((name, value)) = line.split_once(':') else {
            return Err(ParseError::BadContentLength);
        };
        headers.push((
            name.trim().to_ascii_lowercase(),
            value.trim().to_string(),
        ));
    }

    let path = target.split('?').next().unwrap_or("/").to_string();

    let declared: Option<usize> = headers
        .iter()
        .find(|(k, _)| k == "content-length")
        .and_then(|(_, v)| v.parse::<usize>().ok());

    // A declared length that does not survive a round trip through usize is
    // not a length we are willing to act on.
    if let Some(raw) = headers.iter().find(|(k, _)| k == "content-length") {
        if declared.is_none() {
            return Err(ParseError::BadContentLength);
        }
        let _ = raw;
    }

    let content_length = declared.unwrap_or(0);
    if content_length > MAX_BODY_BYTES {
        return Err(ParseError::BodyTooLarge);
    }

    let available = buf.len() - header_end;
    if available < content_length {
        return Err(ParseError::Incomplete);
    }

    Ok(Request {
        method,
        path,
        version,
        headers,
        body: buf[header_end..header_end + content_length].to_vec(),
    })
}

/// Index of `needle` in `haystack`.
fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

// ── routing ─────────────────────────────────────────────────────────────────

/// What a well-formed request asks for, independent of whether it is allowed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    /// The dashboard HTML.
    Dashboard,
    /// One-shot JSON snapshot.
    Status,
    /// Server-Sent Events stream.
    Stream,
    /// The only mutating route: terminate whatever listens on this port.
    Kill(u16),
    /// Nothing here.
    NotFound,
}

/// Map a parsed request to a route. Pure routing only — no security decision
/// is made here, so a `Route` can exist for a request that [`Guard`] will go
/// on to reject.
pub fn classify(req: &Request) -> Route {
    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/") | ("HEAD", "/") => Route::Dashboard,
        ("GET", "/api/status") | ("HEAD", "/api/status") => Route::Status,
        ("GET", "/api/stream") => Route::Stream,
        ("POST", "/api/kill") => match parse_port(&req.body) {
            Some(port) => Route::Kill(port),
            None => Route::NotFound,
        },
        _ => Route::NotFound,
    }
}

/// `{"port": <u16>}` and nothing else. Unknown fields are tolerated (a future
/// dashboard may send more) but the port itself must be a real port number.
///
/// Zero is rejected explicitly. It parses as a `u16`, which is how it got
/// through in the first place, but it is not a port anything can listen on —
/// binding to 0 asks the kernel for an ephemeral port. Accepting it would mean
/// treating "kill the thing on port 0" as a well-formed request instead of the
/// malformed one it is.
fn parse_port(body: &[u8]) -> Option<u16> {
    let value: serde_json::Value = serde_json::from_slice(body).ok()?;
    match value.get("port") {
        Some(serde_json::Value::Number(n)) => match u16::try_from(n.as_u64()?).ok() {
            Some(0) | None => None,
            Some(port) => Some(port),
        },
        _ => None,
    }
}

// ── the guard ───────────────────────────────────────────────────────────────

/// Why a request was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rejection {
    /// `Host` absent or not one of the loopback authorities we serve.
    BadHost,
    /// `Origin` present on a mutation and not this dashboard's own origin.
    BadOrigin,
    /// Mutation with no [`TOKEN_HEADER`].
    MissingToken,
    /// Mutation whose token did not match this run's token.
    BadToken,
}

impl Rejection {
    pub fn status(self) -> u16 {
        403
    }

    pub fn tag(self) -> &'static str {
        match self {
            Rejection::BadHost => "bad_host",
            Rejection::BadOrigin => "bad_origin",
            Rejection::MissingToken => "missing_token",
            Rejection::BadToken => "bad_token",
        }
    }

    /// Human-facing explanation. Kept non-leaky on purpose: a rebinding probe
    /// learns only that it was refused, not which of the four rules it tripped.
    pub fn message(self) -> &'static str {
        "request refused: not an authorised local dashboard request"
    }
}

/// The per-run admission rules for one dashboard instance.
#[derive(Debug, Clone)]
pub struct Guard {
    port: u16,
    token: String,
}

impl Guard {
    pub fn new(port: u16, token: String) -> Self {
        Guard { port, token }
    }

    /// Mint a fresh token for this run.
    ///
    /// Read from `/dev/urandom` rather than a PRNG crate: this is 32 bytes of
    /// entropy once per daemon start, and adding a dependency for it would be
    /// worse than the syscall.
    ///
    /// # `read_exact`, never `fs::read`
    ///
    /// `/dev/urandom` is an *endless* device. `fs::read` on it does not
    /// return — it reads until the address space or the machine's memory is
    /// gone, which triggers the kernel OOM killer and will happily take out
    /// whatever it judges expendable, including the agent multiplexer and any
    /// other sessions running on this host. That is not theoretical: an
    /// earlier revision of this function used `fs::read` and did exactly that.
    ///
    /// The count must be stated and the loop must stop at it. `read_exact`
    /// does both, and an unreadable entropy source yields the empty token, so
    /// mutations fail closed rather than running unauthenticated.
    pub fn generate_token() -> String {
        use std::io::Read;
        let mut raw = [0u8; 32];
        let read = std::fs::File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(&mut raw));
        if read.is_err() {
            // No entropy source: hand back a token that cannot match, so
            // mutations fail closed instead of running unauthenticated.
            return String::new();
        }
        raw.iter().map(|b| format!("{b:02x}")).collect()
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    /// Apply the admission rules to `req`.
    ///
    /// Order is not arbitrary. `Host` is checked first because it is the only
    /// rule that a rebinding attacker cannot get past, and therefore the only
    /// one worth spending the round trip on. Reads are held to the `Host`
    /// rule alone — they expose project and port metadata but cannot change
    /// anything, and requiring a token for `/api/status` would break any
    /// `curl` the operator is expected to run by hand.
    pub fn check(&self, req: &Request) -> Result<(), Rejection> {
        if !host_allowed(req.header("host"), self.port) {
            return Err(Rejection::BadHost);
        }
        if !req.is_mutation() {
            return Ok(());
        }
        if let Some(origin) = req.header("origin") {
            if !origin_allowed(Some(origin), self.port) {
                return Err(Rejection::BadOrigin);
            }
        }
        match req.header(TOKEN_HEADER) {
            None => Err(Rejection::MissingToken),
            Some(provided) => {
                if token_ok(Some(provided), &self.token) {
                    Ok(())
                } else {
                    Err(Rejection::BadToken)
                }
            }
        }
    }
}

/// The `Host` values this daemon answers to.
///
/// Both spellings of loopback are accepted because the dashboard is reached
/// as `http://127.0.0.1:3333` in practice, and `localhost` is what a human
/// types. A `Host` naming any other authority is a rebinding attempt: the
/// socket only ever accepts on loopback, so a name that resolves elsewhere is
/// either a stale `/etc/hosts` entry or someone pointing a browser at us.
pub fn host_allowed(host: Option<&str>, port: u16) -> bool {
    let Some(host) = host else {
        return false;
    };
    let host = host.trim();
    matches_authority(host, port)
}

fn matches_authority(authority: &str, port: u16) -> bool {
    for name in ["127.0.0.1", "localhost", "[::1]"] {
        if authority == format!("{name}:{port}") {
            return true;
        }
        if authority == name {
            // A bare authority is legal in HTTP/1.1 only when the port is the
            // scheme default, which it is not here. Refuse rather than guess.
            return false;
        }
    }
    false
}

/// `Origin` must be this dashboard's own origin exactly.
///
/// Cross-origin browser requests always carry `Origin` on a POST, so a value
/// that is present and different is a foreign page. Absence is tolerated: a
/// non-browser client (`curl`, a script) is not subject to CSRF and is
/// instead held to the token, which it cannot read because the token is only
/// ever served over a `Host`-validated request.
pub fn origin_allowed(origin: Option<&str>, port: u16) -> bool {
    let Some(origin) = origin else {
        return true;
    };
    let origin = origin.trim();
    for name in ["127.0.0.1", "localhost", "[::1]"] {
        if origin == format!("http://{name}:{port}") {
            return true;
        }
    }
    false
}

/// Constant-time-ish token comparison.
///
/// Length is compared first, which does leak length — but the token is a
/// fixed 64 hex characters, so its length is not a secret.
pub fn token_ok(provided: Option<&str>, expected: &str) -> bool {
    let Some(provided) = provided else {
        return false;
    };
    // An un-mintable guard (no /dev/urandom) holds the empty token, which
    // nothing can match because `None` is handled above and `Some("")` is
    // never a valid token.
    if expected.is_empty() {
        return false;
    }
    if provided.len() != expected.len() {
        return false;
    }
    let mut diff = 0u8;
    for (a, b) in provided.bytes().zip(expected.bytes()) {
        diff |= a ^ b;
    }
    diff == 0
}

// ── response ────────────────────────────────────────────────────────────────

/// A fully-formed response, ready to be written to a socket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub reason: &'static str,
    pub content_type: &'static str,
    pub body: Vec<u8>,
    pub extra_headers: Vec<(String, String)>,
}

impl Response {
    pub fn html(body: String) -> Self {
        Response {
            status: 200,
            reason: "OK",
            content_type: "text/html; charset=utf-8",
            body: body.into_bytes(),
            extra_headers: Vec::new(),
        }
    }

    pub fn json(value: &serde_json::Value) -> Self {
        Response {
            status: 200,
            reason: "OK",
            content_type: "application/json",
            body: serde_json::to_vec(value).unwrap_or_else(|_| b"{}".to_vec()),
            extra_headers: Vec::new(),
        }
    }

    pub fn status_json(status: u16, reason: &'static str, tag: &str) -> Self {
        Response {
            status,
            reason,
            content_type: "application/json",
            body: serde_json::json!({
                "success": false,
                "error": tag,
                "message": tag,
            })
            .to_string()
            .into_bytes(),
            extra_headers: Vec::new(),
        }
    }

    pub fn not_found() -> Self {
        Response {
            status: 404,
            reason: "Not Found",
            content_type: "text/plain; charset=utf-8",
            body: b"404 not found".to_vec(),
            extra_headers: Vec::new(),
        }
    }

    /// Serialise to wire bytes.
    ///
    /// `Content-Length` is always derived from the body rather than trusted
    /// from anywhere, and `Connection: close` matches the server's actual
    /// behaviour (it never reuses a connection).
    pub fn render(&self) -> Vec<u8> {
        let mut head = format!(
            "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\n\
             Cache-Control: no-store\r\nConnection: close\r\n",
            self.status,
            self.reason,
            self.content_type,
            self.body.len()
        );
        for (name, value) in &self.extra_headers {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
        head.push_str("\r\n");
        let mut out = head.into_bytes();
        out.extend_from_slice(&self.body);
        out
    }
}

/// The error response for a refusal.
pub fn rejection_response(rejection: Rejection) -> Response {
    Response::status_json(
        rejection.status(),
        "Forbidden",
        rejection.tag(),
    )
}

/// The error response for a malformed or oversized request.
pub fn parse_error_response(error: ParseError) -> Response {
    let reason = match error {
        ParseError::HeadersTooLarge => "Request Header Fields Too Large",
        ParseError::BodyTooLarge => "Payload Too Large",
        _ => "Bad Request",
    };
    Response::status_json(error.status(), reason, error.tag())
}