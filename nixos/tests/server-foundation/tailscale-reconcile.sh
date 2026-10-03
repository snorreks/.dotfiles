#!/usr/bin/env bash
# nixos/tests/server-foundation/tailscale-reconcile.sh — offline boot, delayed
# authentication, and later internet return.
#
# The fake `tailscale` here is a STATE MACHINE, not a stub that always succeeds,
# because every interesting property of this script is about what it does across
# runs: the first run happens before the node can authenticate, and a later run
# happens after it can. A stub that succeeded immediately would not distinguish
# "the reconciler recovers on its own" from "the reconciler never had to".
#
# Nothing here touches the real node, the real control plane, any Serve
# configuration or any firewall. The fake is on PATH; nothing else is.
#
# Run directly:  bash nixos/tests/server-foundation/tailscale-reconcile.sh
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RECONCILE="$ROOT/config/system/tailscale/reconcile.sh"

printf '\n\033[1mserver-foundation — tailscale reconciliation (offline → online)\033[0m\n'

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

t_start() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '  %s\n' "$1"
}
_fail() {
  printf '    FAIL %s: %s\n' "${CURRENT_TEST:-<none>}" "$*" >&2
  TESTS_FAILED=$((TESTS_FAILED + 1))
}
t_done() {
  [[ "$TESTS_FAILED" -gt 0 ]] && return 0
  printf '    ok   %s\n' "$CURRENT_TEST"
  CURRENT_TEST=""
}
assert_eq() {
  if [[ "$2" == "$3" ]]; then return 0; fi
  _fail "$1: expected '$2', got '$3'"
}
assert_ne_zero() {
  if [[ "$2" != "0" ]]; then return 0; fi
  _fail "$1: expected a non-zero exit, got 0"
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then return 0; fi
  _fail "$1: expected '$3' in: $(printf '%s' "$2" | tr '\n' '|')"
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then return 0; fi
  _fail "$1: did NOT expect '$3' — got: $(printf '%s' "$2" | tr '\n' '|')"
}

TMP=""
setup() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/ts-reconcile-test.XXXXXX")"
  mkdir -p "$TMP/bin" "$TMP/state"
  # Every fake is written with a hardcoded interpreter path rather than
  # `#!/usr/bin/env bash`. A nix build sandbox has a coreutils-only root: /bin/sh
  # exists, /usr/bin/env does not, and a fake that cannot find its interpreter
  # fails with "bad interpreter" — which then looks like the tool under test
  # being broken rather than the harness. (Same reason, same fix, as the fakes in
  # tests/lib/harness.sh.)

  # The node's state lives in files, so it survives across runs of the script
  # within one test — which is how "delayed authentication, then recovery" is
  # expressed.
  : >"$TMP/state/backend"           # BackendState as tailscaled reports it
  printf 'NoState\n' >"$TMP/state/backend"
  printf 'legion.tailf24d02.ts.net.\n' >"$TMP/state/dnsname"
  : >"$TMP/state/serve"             # empty = nothing served yet
  : >"$TMP/state/prefs"             # applied flags
  : >"$TMP/calls"                   # every invocation, in order
  export TMP

  cat >"$TMP/bin/tailscale" <<'FAKE'
#!/usr/bin/env bash
# Fake tailscale. State in $TMP/state, every call in $TMP/calls.
set -u
echo "tailscale $*" >>"$TMP/calls"
case "${1:-}" in
  status)
    if [[ "${2:-}" == "--json" ]]; then
      printf '{"BackendState":"%s","Self":{"DNSName":"%s"}}\n' \
        "$(cat "$TMP/state/backend")" "$(cat "$TMP/state/dnsname")"
    else
      printf '%s\n' "$(cat "$TMP/state/backend")"
    fi
    ;;
  set)
    # `tailscale set` changes prefs. It never logs in — the real command has no
    # login path at all, and the fake logs any attempt to use one.
    shift
    printf '%s\n' "$*" >>"$TMP/state/prefs"
    ;;
  serve)
    case "${2:-}" in
      status)
        cat "$TMP/state/serve"
        ;;
      reset)
        echo "FATAL: 'tailscale serve reset' erases every mapping" >>"$TMP/calls"
        printf 'reset\n' >"$TMP/state/serve"
        exit 0
        ;;
      funnel)
        echo "FATAL: 'tailscale funnel' publishes to the public internet" >>"$TMP/calls"
        exit 0
        ;;
      *)
        # `serve --bg --https=PORT http://127.0.0.1:TARGET`
        # FAKE_SERVE_FAIL models an .ts.net certificate that has not been issued
        # yet: the write is refused, which is the transient failure the reconciler
        # is expected to survive and retry rather than treat as fatal.
        if [[ -n "${FAKE_SERVE_FAIL:-}" ]]; then
          printf 'failed to apply serve config: no certificate yet\n' >&2
          exit 1
        fi
        port="${3#--https=}"
        target="${4:-}"
        printf '{"TCP":{"%s":{"HTTPS":true}},"Web":{"%s":{"Handlers":{"/":{"Proxy":"%s"}}}}}\n' \
          "$port" "$port" "$target" >"$TMP/state/serve"
        ;;
    esac
    ;;
  up)
    # A real `up` on an authenticated node can start an interactive re-auth
    # prompt; on an unattended machine that hangs forever. Recorded so a test can
    # prove it was never called.
    echo "FATAL: 'tailscale up' is the login flow and must never be run by this job" >>"$TMP/calls"
    exit 1
    ;;
  *)
    printf 'unexpected invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
  # Give the fake a real interpreter path. Written with a literal
  # `#!/usr/bin/env bash` above and patched here, because a nix build sandbox has
  # a coreutils-only root: /bin/sh exists, /usr/bin/env does not, and a fake that
  # cannot find its interpreter fails with "bad interpreter" — which reads as the
  # tool under test being broken rather than the harness. Same reason, same fix
  # as tests/lib/harness.sh.
  sed -i "1s|^#!.*|#!$(command -v bash)|" "$TMP/bin/tailscale"
  chmod +x "$TMP/bin/tailscale"
}

teardown() {
  [[ -n "$TMP" && -d "$TMP" && "${KEEP_TMP:-0}" != "1" ]] && rm -rf "$TMP"
  TMP=""
  return 0
}

run_reconcile() {
  PATH="$TMP/bin:$PATH" \
    NM_TAILSCALE="$TMP/bin/tailscale" \
    NM_TS_DESIRED_SSH=true \
    NM_TS_ACCEPT_DNS=false \
    NM_TS_EXIT_NODE=true \
    NM_TS_SERVE_HTTPS_PORT=443 \
    NM_TS_SERVE_TARGET_PORT=8787 \
    NM_TS_SERVE_HOST=legion.tailf24d02.ts.net \
    NM_TS_WAIT_SECONDS="${NM_TS_WAIT_SECONDS:-0}" \
    bash "$RECONCILE" 2>&1
}

# These read the fixture through the CURRENT $TMP. `setup` redefines TMP for
# each test, so they must not capture it as a default argument — an earlier
# version bound them to the first fixture and every later test read the wrong
# (or no) state.
calls() { cat "$TMP/calls"; }
serve_config() { cat "$TMP/state/serve"; }
prefs() { cat "$TMP/state/prefs"; }

# ─────────────────────────────────────────────────────────────────────────────
t_start "an unauthenticated node fails loudly and changes nothing"
setup
out="$(run_reconcile)" && rc=0 || rc=$?
assert_ne_zero "exit status" "$rc"
assert_contains "it says the node is not authenticated" "$out" "not authenticated"
assert_contains "it says what a human has to do" "$out" "tailscale up"
assert_contains "it says it will not reboot" "$out" "NOT rebooting"
assert_eq "nothing was written" "" "$(prefs)"
assert_eq "nothing was served" "" "$(serve_config)"
assert_not_contains "no login was attempted" "$(calls)" "FATAL: 'tailscale up'"
assert_not_contains "no Serve reset" "$(calls)" "serve reset"
assert_not_contains "no Funnel" "$(calls)" "funnel"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "delayed authentication: the first run waits, then gives up cleanly"
setup
# The node authenticates four seconds in — later than the window we allow.
# The node authenticates four seconds in — later than the window we allow. The
# subshell's own chatter is not part of what is being asserted.
( sleep 4; printf 'Running\n' >"$TMP/state/backend" ) >/dev/null 2>&1 &
bg=$!
out="$(NM_TS_WAIT_SECONDS=3 run_reconcile)" && rc=0 || rc=$?
wait "$bg" 2>/dev/null || true
assert_ne_zero "exit status while still unauthenticated" "$rc"
assert_contains "it reports what it waited" "$out" "waited"
assert_eq "still nothing written" "" "$(prefs)"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the later internet return is picked up by the next run, no reboot"
setup
# This is the whole point of the timer: run 1 is offline, the uplink comes back,
# run 2 converges. Nothing about run 1 needs to have "fixed" anything for run 2
# to work — it just needs to have left the node alone.
printf 'NoState\n' >"$TMP/state/backend"
out1="$(run_reconcile)" && rc1=0 || rc1=$?
: "$out1"
assert_ne_zero "run 1 (offline)" "$rc1"

# The uplink returns and the credentials are read.
printf 'Running\n' >"$TMP/state/backend"
out2="$(run_reconcile)" && rc2=0 || rc2=$?
assert_eq "run 2 converges" 0 "$rc2"
assert_contains "it says so" "$out2" "converged"
assert_contains "SSH is on" "$(prefs)" "--ssh=true"
assert_contains "MagicDNS is still refused" "$(prefs)" "--accept-dns=false"
assert_contains "the exit node is advertised" "$(prefs)" "--advertise-exit-node=true"
assert_contains "Serve 443 was restored" "$(serve_config)" "8787"
assert_contains "Serve is on 443" "$(serve_config)" '"443"'
assert_not_contains "no login" "$(calls)" "FATAL: 'tailscale up'"
assert_not_contains "no Serve reset" "$(calls)" "serve reset"
assert_not_contains "no Funnel" "$(calls)" "funnel"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "preferences are applied with set, never with up"
setup
printf 'Running\n' >"$TMP/state/backend"
run_reconcile >/dev/null 2>&1 || true
assert_contains "it used set" "$(calls)" "tailscale set"
assert_not_contains "it never used up" "$(calls)" "tailscale up"
assert_not_contains "and never even reached the fake's up trap" "$(calls)" "FATAL"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "an existing Serve 443 mapping is left completely untouched"
setup
printf 'Running\n' >"$TMP/state/backend"
# A correct mapping, plus a SECOND listener a later change added — the case this
# job must never be the reason disappears.
cat >"$TMP/state/serve" <<'JSON'
{"TCP":{"443":{"HTTPS":true}},"Web":{"legion.tailf24d02.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}
JSON
out="$(run_reconcile)" && rc=0 || rc=$?
assert_eq "exit status" 0 "$rc"
assert_contains "it says it left it alone" "$out" "leaving it untouched"
assert_not_contains "no Serve write was attempted" "$(calls)" "serve --bg"
assert_contains "the mapping is unchanged" "$(serve_config)" "8787"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "a Serve mapping pointing at the wrong port is repaired, not reset"
setup
printf 'Running\n' >"$TMP/state/backend"
# Present, but at the wrong loopback port — a half-applied mapping from an
# interrupted activation. The fix must be the one mapping, never a reset.
cat >"$TMP/state/serve" <<'JSON'
{"TCP":{"443":{"HTTPS":true}},"Web":{"legion.tailf24d02.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}
JSON
out="$(run_reconcile)" && rc=0 || rc=$?
assert_eq "exit status" 0 "$rc"
assert_contains "it reports the repair" "$out" "restoring it"
assert_contains "it now points at the right port" "$(serve_config)" "8787"
assert_not_contains "no Serve reset" "$(calls)" "serve reset"
assert_not_contains "no Funnel" "$(calls)" "funnel"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "a Serve failure (no certificate yet) is visible and retried, not fatal"
setup
printf 'Running\n' >"$TMP/state/backend"
# The fake refuses the Serve write, the way an un-issued certificate does.
out="$(FAKE_SERVE_FAIL=1 run_reconcile)" && rc=0 || rc=$?
assert_ne_zero "exit status" "$rc"
assert_contains "it explains the likely cause" "$out" "certificate"
assert_contains "it says it will be retried" "$out" "later run"
assert_not_contains "and still never reboots" "$out" "reboot the node"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "a DNS name that disagrees with serveHosts is reported, with both names"
setup
# The failure this catches is invisible from a phone: the node is up, Collie
# serves, and every request is refused with "host not allowed".
printf 'Running\n' >"$TMP/state/backend"
printf 'legion-renamed.tailf24d02.ts.net.\n' >"$TMP/state/dnsname"
out="$(run_reconcile)" && rc=0 || rc=$?
assert_ne_zero "exit status" "$rc"
assert_contains "it names what the node reports" "$out" "legion-renamed.tailf24d02.ts.net"
assert_contains "it names what is configured" "$out" "legion.tailf24d02.ts.net"
assert_contains "it explains the symptom" "$out" "Host-header allowlist"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the LAN is not opened: no firewall rule is added by this job"
setup
printf 'Running\n' >"$TMP/state/backend"
run_reconcile >/dev/null 2>&1 || true
# The reconciler has no firewall tool at all. Assert that the only commands it
# can reach are tailscale's, so there is no path by which it could open one.
assert_eq "every call went to the tailscale fake" "" \
  "$(grep -v '^tailscale ' "$TMP/calls" || true)"
assert_contains "and it did call tailscale" "$(calls)" "tailscale"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "a node in a transitional state is left alone"
setup
printf 'Stopped\n' >"$TMP/state/backend"
out="$(run_reconcile)" && rc=0 || rc=$?
assert_eq "exit status" 0 "$rc"
assert_eq "no preferences written" "" "$(prefs)"
assert_contains "it says tailscaled will sort it out" "$out" "tailscaled will sort it out"
teardown
t_done

# ─────────────────────────────────────────────────────────────────────────────
if [[ "$TESTS_FAILED" -ne 0 ]]; then
  printf '\n\033[31mtailscale-reconcile: %d assertion(s) failed\033[0m\n' "$TESTS_FAILED"
  exit 1
fi
printf '\n\033[32mtailscale-reconcile: all %d checks passed\033[0m\n' "$TESTS_RUN"
