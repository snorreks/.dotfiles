//! Negative tests for the dev-ports dashboard HTTP admission rules.
//!
//! ## These tests never reach the live daemon
//!
//! Every case drives [`sys_daemon::httpcore`], which is the pure parse →
//! guard → classify path. Nothing here binds a port, sends a packet, or
//! starts `sys-daemon serve`. That is a deliberate property of the design
//! rather than a limitation of the tests: `http.rs` holds the socket and
//! `httpcore.rs` holds the rules, so the rules can be tested exhaustively
//! without any risk of accidentally exercising the operator's running
//! dashboard. The socket-level behaviour (deadlines, bounded reads) is
//! covered separately in `api_socket.rs`, against an ephemeral port.
//!
//! ## What each test is defending against
//!
//! A loopback bind stops other *machines* connecting. It stops nothing on
//! this one, and in particular it does not stop the user's browser, which
//! runs with the user's privileges and will happily issue requests to
//! `127.0.0.1` on behalf of any page the user visits. `POST /api/kill` turns
//! that into "any page the user visits can terminate processes", so the
//! cases below are written from the attacker's side.

use sys_daemon::httpcore::{
    self, Guard, ParseError, Rejection, Route, MAX_BODY_BYTES, MAX_HEADER_BYTES,
    TOKEN_HEADER,
};

/// The port the tests pretend the dashboard is on.
const PORT: u16 = 3333;

/// A token for a guard under test.
fn guard() -> Guard {
    Guard::new(PORT, "a".repeat(64))
}

/// Build a raw request as bytes, exactly as it would arrive on the wire.
/// `Content-Length` is added automatically whenever a body is present and the
/// caller did not supply one — a body of undeclared length is read as zero
/// bytes, which is correct server behaviour and a confusing test otherwise.
fn raw(method: &str, path: &str, headers: &[(&str, &str)], body: &[u8]) -> Vec<u8> {
    let mut out = format!("{method} {path} HTTP/1.1\r\n");
    for (name, value) in headers {
        out.push_str(&format!("{name}: {value}\r\n"));
    }
    if !body.is_empty() && !headers.iter().any(|(k, _)| k.eq_ignore_ascii_case("content-length")) {
        out.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    out.push_str("\r\n");
    let mut bytes = out.into_bytes();
    bytes.extend_from_slice(body);
    bytes
}

/// A same-origin mutation: correct Host, correct Origin, correct token.
/// Everything hostile is derived by removing exactly one of those.
/// Build a raw request as bytes, exactly as it would arrive on the wire.
/// `port` is a JSON number rather than a `u16` so tests can send values the
/// server would never accept.
///
/// `Content-Length` is always emitted for a non-empty body. That is what a
/// browser does, and it matters: a body with no declared length is
/// deliberately treated as length zero by the parser (see `parse`), so a
/// helper that omitted the header would silently be testing empty requests.
fn authorised_kill(port: u32) -> Vec<u8> {
    raw(
        "POST",
        "/api/kill",
        &[
            ("Host", &format!("127.0.0.1:{PORT}")),
            ("Origin", &format!("http://127.0.0.1:{PORT}")),
            ("Content-Type", "application/json"),
            (TOKEN_HEADER, &"a".repeat(64)),
        ],
        format!("{{\"port\":{port}}}").as_bytes(),
    )
}

// ── the baseline: an authorised request still works ─────────────────────────

/// The control. If this ever fails, the guards have broken the dashboard
/// rather than defended it, and every refusal below is worthless.
#[test]
fn authorised_mutation_is_accepted() {
    let bytes = authorised_kill(4000);
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Ok(()));
    assert_eq!(httpcore::classify(&req), Route::Kill(4000));
}

// ── DNS rebinding: the Host check ───────────────────────────────────────────

/// The rebinding case. `evil.example` resolves to 127.0.0.1, so this request
/// physically arrives at the daemon while the browser believes it is talking
/// to a remote site. It is same-origin *from the browser's point of view*,
/// which is why browser CSRF protections do not engage and why the daemon has
/// to check `Host` itself.
#[test]
fn rebinding_request_with_foreign_host_is_refused() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[
            ("Host", "evil.example"),
            ("Content-Type", "application/json"),
            (TOKEN_HEADER, &"a".repeat(64)),
        ],
        br#"{"port":4000}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Err(Rejection::BadHost));
}

/// The same request with a token the attacker somehow obtained. The token is
/// not the load-bearing control: a page that reached the daemon by rebinding
/// was already refused at `Host`, so it never got a token. This case proves
/// the two checks are independent rather than one being redundant.
#[test]
fn foreign_host_is_refused_even_with_a_valid_token() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[
            ("Host", "attacker.example:3333"),
            (TOKEN_HEADER, &"a".repeat(64)),
        ],
        br#"{"port":4000}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Err(Rejection::BadHost));
}

/// A Host naming loopback on the *wrong* port is not us. Otherwise a rebinding
/// attacker could point `Host: 127.0.0.1:9999` at the real daemon.
#[test]
fn loopback_host_on_the_wrong_port_is_refused() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[("Host", "127.0.0.1:9999"), (TOKEN_HEADER, &"a".repeat(64))],
        br#"{"port":4000}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Err(Rejection::BadHost));
}

/// A bare `Host: localhost` with no port. HTTP/1.1 permits this only when the
/// port is the scheme default; ours is not. Refused rather than guessed.
#[test]
fn host_without_port_is_refused() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[("Host", "localhost"), (TOKEN_HEADER, &"a".repeat(64))],
        br#"{"port":4000}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Err(Rejection::BadHost));
}

/// An absent Host is refused. HTTP/1.0 clients may omit it, but this daemon
/// serves browsers and the omission is never legitimate here.
#[test]
fn missing_host_is_refused() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[("Content-Type", "application/json")],
        br#"{"port":4000}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Err(Rejection::BadHost));
}

/// Reads are held to the Host rule too. `/api/status` leaks the full project
/// and port map, which is reconnaissance for a rebinding attacker, and
/// requiring no token for reads keeps `curl` usable by the operator.
#[test]
fn reads_from_a_foreign_host_are_refused() {
    for path in ["/", "/api/status", "/api/stream"] {
        let bytes = raw("GET", path, &[("Host", "evil.example")], b"");
        let req = httpcore::parse(&bytes).expect("parses");
        assert_eq!(
            guard().check(&req),
            Err(Rejection::BadHost),
            "{path} should be refused for a foreign Host"
        );
    }
}

/// Both spellings of loopback that a human actually types must keep working,
/// otherwise the hardening breaks the dashboard for its own user.
#[test]
fn loopback_hosts_are_accepted() {
    for host in [
        format!("127.0.0.1:{PORT}"),
        format!("localhost:{PORT}"),
        format!("[::1]:{PORT}"),
    ] {
        let bytes = raw("GET", "/api/status", &[("Host", &host)], b"");
        let req = httpcore::parse(&bytes).expect("parses");
        assert_eq!(guard().check(&req), Ok(()), "{host} should be accepted");
    }
}

// ── CSRF: the Origin and token checks ───────────────────────────────────────

/// A cross-origin POST from any page. Browsers attach `Origin` to cross-origin
/// POSTs, and the attacker does not control its value.
#[test]
fn cross_origin_mutation_is_refused() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[
            ("Host", &format!("127.0.0.1:{PORT}")),
            ("Origin", "http://evil.example"),
            ("Content-Type", "application/json"),
            (TOKEN_HEADER, &"a".repeat(64)),
        ],
        br#"{"port":4000}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Err(Rejection::BadOrigin));
}

/// The realistic CSRF shape: the attacker's page cannot set a custom header on
/// a no-cors POST, and has no token. Both defences are absent at once.
#[test]
fn simple_form_style_csrf_is_refused() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[
            ("Host", &format!("127.0.0.1:{PORT}")),
            ("Origin", "http://evil.example"),
            ("Content-Type", "text/plain"),
        ],
        br#"{"port":22}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Err(Rejection::BadOrigin));
}

/// Right Host, right Origin, no token: refused. A non-browser client is not
/// subject to CSRF and is therefore held to the token instead, which it has no
/// way to read.
#[test]
fn mutation_without_a_token_is_refused() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[
            ("Host", &format!("127.0.0.1:{PORT}")),
            ("Origin", &format!("http://127.0.0.1:{PORT}")),
        ],
        br#"{"port":4000}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Err(Rejection::MissingToken));
}

/// A wrong token is refused. Guards against a token that leaks into a log, a
/// screenshot, or a copy-pasted `curl`.
#[test]
fn mutation_with_the_wrong_token_is_refused() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[
            ("Host", &format!("127.0.0.1:{PORT}")),
            (TOKEN_HEADER, &"b".repeat(64)),
        ],
        br#"{"port":4000}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Err(Rejection::BadToken));
}

/// A prefix of the real token is not the token.
#[test]
fn token_prefix_is_refused() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[("Host", &format!("127.0.0.1:{PORT}")), (TOKEN_HEADER, &"a".repeat(63))],
        br#"{"port":4000}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Err(Rejection::BadToken));
}

/// Token lookup is case-insensitive on the *header name* — an attacker must not
/// be able to bypass the check by spelling it differently.
#[test]
fn token_header_name_is_matched_case_insensitively() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[
            ("Host", &format!("127.0.0.1:{PORT}")),
            ("X-SYS-DAEMON-TOKEN", &"a".repeat(64)),
        ],
        br#"{"port":4000}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(guard().check(&req), Ok(()), "header names are case-insensitive");
}

/// A guard whose token could not be minted (no `/dev/urandom`) holds the
/// empty string, and the empty string must not authenticate anything.
#[test]
fn unminted_guard_fails_closed() {
    let broken = Guard::new(PORT, String::new());
    let bytes = raw(
        "POST",
        "/api/kill",
        &[
            ("Host", &format!("127.0.0.1:{PORT}")),
            (TOKEN_HEADER, ""),
        ],
        br#"{"port":4000}"#,
    );
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(broken.check(&req), Err(Rejection::BadToken));
}

/// A minted token is 64 hex characters and differs between runs.
#[test]
fn generated_tokens_are_long_and_per_run() {
    let a = Guard::generate_token();
    let b = Guard::generate_token();
    assert_eq!(a.len(), 64, "expected 32 bytes of hex, got {}", a.len());
    assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
    assert_ne!(a, b, "two runs must not share a token");
}

// ── bounded reads ───────────────────────────────────────────────────────────

/// A body far past the cap is refused at the header, without being read.
#[test]
fn oversized_body_is_refused() {
    let body = vec![b'x'; MAX_BODY_BYTES * 4];
    let bytes = raw(
        "POST",
        "/api/kill",
        &[
            ("Host", &format!("127.0.0.1:{PORT}")),
            ("Content-Length", &body.len().to_string()),
        ],
        &body,
    );
    assert_eq!(httpcore::parse(&bytes), Err(ParseError::BodyTooLarge));
}

/// A `Content-Length` past the cap is refused even though not one byte of it
/// has arrived. Reading to the declared length first would be the bug.
#[test]
fn oversized_declared_content_length_is_refused_before_reading() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[
            ("Host", &format!("127.0.0.1:{PORT}")),
            ("Content-Length", &(MAX_BODY_BYTES * 100).to_string()),
        ],
        b"",
    );
    assert_eq!(httpcore::parse(&bytes), Err(ParseError::BodyTooLarge));
}

/// A header block with no terminator past the cap is refused, so a client
/// that never sends `\r\n\r\n` cannot make the server buffer without limit.
#[test]
fn unterminated_oversized_header_block_is_refused() {
    let bytes = vec![b'A'; MAX_HEADER_BYTES + 1];
    assert_eq!(httpcore::parse(&bytes), Err(ParseError::HeadersTooLarge));
}

/// A short header block with no terminator is simply incomplete — the caller
/// should keep reading. Confusing these two is what turns a slow client into a
/// 431.
#[test]
fn short_unterminated_request_is_incomplete_not_too_large() {
    let bytes = b"GET / HTTP/1.1\r\nHost: 127.0.0.1:3333\r\n";
    assert_eq!(httpcore::parse(bytes), Err(ParseError::Incomplete));
}

/// A `Content-Length` that is not a number is refused, not silently read as
/// zero — otherwise a body could be appended that the parser then ignores.
#[test]
fn malformed_content_length_is_refused() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[("Host", &format!("127.0.0.1:{PORT}")), ("Content-Length", "abc")],
        b"",
    );
    assert_eq!(httpcore::parse(&bytes), Err(ParseError::BadContentLength));
}

/// A negative `Content-Length` does not parse as `usize`, and is refused.
#[test]
fn negative_content_length_is_refused() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[("Host", &format!("127.0.0.1:{PORT}")), ("Content-Length", "-1")],
        b"",
    );
    assert_eq!(httpcore::parse(&bytes), Err(ParseError::BadContentLength));
}

/// A header line with no colon is request-smuggling bait and is refused
/// rather than skipped.
#[test]
fn header_line_without_a_colon_is_refused() {
    let bytes = b"POST /api/kill HTTP/1.1\r\nHost: 127.0.0.1:3333\r\nSmuggled\r\n\r\n";
    assert_eq!(httpcore::parse(bytes), Err(ParseError::BadContentLength));
}

/// A body shorter than the declared length is incomplete, so the server keeps
/// reading rather than parsing a truncated JSON document.
#[test]
fn short_body_is_incomplete() {
    let bytes = raw(
        "POST",
        "/api/kill",
        &[
            ("Host", &format!("127.0.0.1:{PORT}")),
            ("Content-Length", "100"),
        ],
        b"{}",
    );
    assert_eq!(httpcore::parse(&bytes), Err(ParseError::Incomplete));
}

// ── routing ─────────────────────────────────────────────────────────────────

/// `/api/kill` is the only mutating route. Anything else that tries to POST is
/// not found, so a future route cannot be added without meeting the guard.
#[test]
fn only_kill_is_mutating_and_nothing_else_routes_to_kill() {
    for (method, path) in [
        ("POST", "/api/status"),
        ("POST", "/"),
        ("PUT", "/api/kill"),
        ("DELETE", "/api/kill"),
        ("POST", "/api/kill/../kill"),
        ("GET", "/api/kill"),
    ] {
        let host = format!("127.0.0.1:{PORT}");
        let origin = format!("http://127.0.0.1:{PORT}");
        let token = "a".repeat(64);
        let mut headers: Vec<(&str, &str)> = vec![("Host", host.as_str())];
        if method == "POST" {
            headers.push(("Origin", origin.as_str()));
            headers.push((TOKEN_HEADER, token.as_str()));
        }
        let bytes = raw(method, path, &headers, b"{}");
        let req = httpcore::parse(&bytes).expect("parses");
        assert_eq!(
            httpcore::classify(&req),
            Route::NotFound,
            "{method} {path} must not route"
        );
    }
}

/// A `PUT` is a mutation by `is_mutation`, so it is held to the token even
/// though it routes nowhere. The guard is applied to the method, not to the
/// route table.
#[test]
fn non_get_methods_are_treated_as_mutations_by_the_guard() {
    let bytes = raw("PUT", "/whatever", &[("Host", &format!("127.0.0.1:{PORT}"))], b"");
    let req = httpcore::parse(&bytes).expect("parses");
    assert!(req.is_mutation());
    assert_eq!(guard().check(&req), Err(Rejection::MissingToken));
}

/// A `POST` body naming a port past 65535 does not route to a kill.
#[test]
fn out_of_range_port_does_not_route_to_kill() {
    let bytes = authorised_kill(70000);
    let req = httpcore::parse(&bytes).expect("parses");
    assert_eq!(httpcore::classify(&req), Route::NotFound);
}

// ── responses ───────────────────────────────────────────────────────────────

/// Every refusal is a 403 with a machine-readable tag, so the dashboard can
/// tell the operator which rule fired.
#[test]
fn rejections_render_as_403_with_a_tag() {
    for (rejection, tag) in [
        (Rejection::BadHost, "bad_host"),
        (Rejection::BadOrigin, "bad_origin"),
        (Rejection::MissingToken, "missing_token"),
        (Rejection::BadToken, "bad_token"),
    ] {
        let response = httpcore::rejection_response(rejection);
        assert_eq!(response.status, 403);
        let wire = response.render();
        let rendered = String::from_utf8_lossy(&wire).to_string();
        assert!(rendered.starts_with("HTTP/1.1 403"), "got {rendered}");
        assert!(rendered.contains(tag), "{rendered} should name {tag}");
    }
}

/// The refusal message must not tell a probing attacker which rule they
/// tripped. All four are the same sentence.
#[test]
fn refusal_messages_do_not_leak_which_rule_fired() {
    let messages: Vec<&str> = [
        Rejection::BadHost,
        Rejection::BadOrigin,
        Rejection::MissingToken,
        Rejection::BadToken,
    ]
    .iter()
    .map(|r| r.message())
    .collect();
    assert!(
        messages.windows(2).all(|w| w[0] == w[1]),
        "refusal messages must be identical: {messages:?}"
    );
}

/// `Content-Length` is derived from the body, never taken on trust, so a
/// response cannot desynchronise a client.
#[test]
fn response_content_length_matches_the_body() {
    let response = httpcore::Response::json(&serde_json::json!({"a": 1}));
    let rendered = String::from_utf8_lossy(&response.render()).to_string();
    let body_len = serde_json::to_vec(&serde_json::json!({"a": 1})).unwrap().len();
    assert!(rendered.contains(&format!("Content-Length: {body_len}")));
}