#!/usr/bin/env bash
# nixos/config/system/tailscale/reconcile.sh — converge this node's Tailscale
# state onto what the configuration says it should be, without ever logging in
# again and without ever rebooting.
#
# ── Why this exists ──────────────────────────────────────────────────────────
# `tailscaled-set` is a oneshot that runs once at boot. It is not a supervisor:
# if it runs before the node has finished authenticating, or before the network
# is up, or before the Let's Encrypt certificate for the Serve name has been
# issued, it fails, and nothing retries it. The tailnet then comes up with
# `--ssh` unset (no SSH at all), or with the Serve mapping missing (no Collie),
# and the operator — who is not at the machine — has no way to fix it except a
# manual `tailscale up` or a reboot.
#
# The failure is not rare in the shapes that matter:
#
#   * an unattended boot starts before the uplink is up (ethernet DHCP, a slow
#     router, a modem that takes two minutes);
#   * the node's control-plane credentials have not finished being re-read, so
#     `tailscale status` reports NeedsLogin rather than Running;
#   * a Serve certificate for a .ts.net name is issued on demand, and the first
#     attempt happens at a moment when it cannot complete.
#
# Each of those resolves on its own within minutes. So this script is a
# convergent reconciler driven by a timer: it observes the current state, does
# the smallest thing that moves it towards the declared state, and exits
# non-zero (visibly, in the journal) when it cannot.
#
# ── What it will never do ────────────────────────────────────────────────────
#   * `tailscale up` — that is the login flow. Running it on an
#     already-authenticated node can start an interactive re-authentication
#     prompt on a machine with nobody at the keyboard, and on a node that IS
#     logged out it does nothing useful without a browser. Preferences are
#     changed with `tailscale set`, which never logs in.
#   * `tailscale serve reset` — that erases EVERY mapping on the node,
#     including the Collie HTTPS/443 one this repository depends on and any
#     listener a later change adds. The mapping is repaired individually, and
#     only when it is genuinely missing or points at the wrong port.
#   * `tailscale funnel` — that publishes to the public internet. The mapping
#     below is private Serve only.
#   * reboot, restart or `tailscale up` on the peer path. Nothing here
#     interrupts a live connection; a box you cannot reach must never be
#     rebooted by a repair job.
#
# Environment (all overridable so the tests can drive every branch):
#   NM_TAILSCALE             tailscale binary           (default: tailscale)
#                             Must be resolvable on PATH, or the script says
#                             so and stops: an unreadable node is not a
#                             logged-out node.
#   NM_TS_DESIRED_SSH        "true"/"false"             node-level SSH
#   NM_TS_ACCEPT_DNS         "true"/"false"             MagicDNS acceptance
#   NM_TS_EXIT_NODE          "true"/"false"             advertise an exit node
#   NM_TS_SERVE_HTTPS_PORT   port already serving HTTPS (0 = do not manage)
#   NM_TS_SERVE_TARGET_PORT  loopback port to proxy to (0 = do not manage)
#   NM_TS_SERVE_HOST         the .ts.net name to verify  ("" = skip the check)
#   NM_TS_WAIT_SECONDS       how long to wait for auth   (default 0)
set -o nounset -o pipefail

: "${NM_TAILSCALE:=tailscale}"
: "${NM_TS_DESIRED_SSH:=true}"
: "${NM_TS_ACCEPT_DNS:=false}"
: "${NM_TS_EXIT_NODE:=false}"
: "${NM_TS_SERVE_HTTPS_PORT:=0}"
: "${NM_TS_SERVE_TARGET_PORT:=0}"
: "${NM_TS_SERVE_HOST:=}"
: "${NM_TS_WAIT_SECONDS:=0}"

log() { printf 'tailscale-reconcile: %s\n' "$*"; }
warn() { printf 'tailscale-reconcile: %s\n' "$*" >&2; }

fail() {
  warn "$*"
  warn "not changing anything else and NOT rebooting — the node keeps whatever it has."
  exit 1
}

# ── Is the node authenticated? ───────────────────────────────────────────────
#
# BackendState is the single field that answers "can this node reach the
# control plane". Anything other than Running means either logged out (a human
# has to visit an admin URL — not something this job can or should do) or
# still starting up (which is the case this script exists for).
#
# "I could not ask" and "the answer was no" are DIFFERENT and are kept apart
# here. They used to collapse into one empty string, so a unit whose PATH did
# not contain the tailscale CLI reported "the node is not authenticated, run
# 'tailscale up'" about a node that was logged in the whole time — and an
# unattended `tailscale up` is exactly the interactive hang this script exists
# to avoid. An empty answer is only reported as an empty answer.
if ! command -v "$NM_TAILSCALE" >/dev/null 2>&1; then
  fail "the tailscale CLI ('$NM_TAILSCALE') is not on this unit's PATH, so the
         node's state cannot be read at all. This is a packaging fault, not a
         node fault: nothing below was attempted, nothing was changed, and
         'tailscale up' would NOT help. Check 'path' in
         config/system/server.nix for systemd.services.tailscale-reconcile."
fi

backend_state() {
  "$NM_TAILSCALE" status --json 2>/dev/null |
    sed -n 's/.*"BackendState":[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n1
}

state="$(backend_state)"
log "BackendState=${state:-<none reported>}"

if [[ "$NM_TS_WAIT_SECONDS" -gt 0 ]]; then
  waited=0
  while [[ "$state" != "Running" && "$waited" -lt "$NM_TS_WAIT_SECONDS" ]]; do
    sleep 1
    waited=$((waited + 1))
    state="$(backend_state)"
  done
  log "waited ${waited}s for authentication; BackendState=${state:-unknown}"
fi

case "$state" in
  Running)
    :
    ;;
  NeedsLogin | NoState)
    fail "the node is not authenticated (BackendState=$state).
         A browser login is required — run 'tailscale up' from a console, or
         use the admin console. This job will not: an unattended 'tailscale up'
         can leave the node waiting on an interactive prompt forever, and the
         timer will retry once the credentials are in place."
    ;;
  "")
    # The CLI ran but reported no BackendState at all: tailscaled is not
    # answering (still starting, or wedged). Named separately from the
    # logged-out case above, because 'tailscale up' is the wrong advice here —
    # nothing about this node needs a browser.
    fail "'$NM_TAILSCALE status --json' returned no BackendState, so tailscaled
         is not answering. This is a starting-up or wedged-daemon condition,
         not a logged-out one: do NOT run 'tailscale up'. The timer retries."
    ;;
  unknown)
    fail "BackendState=unknown. tailscaled reports an explicit state this
         version of the script does not recognise; leaving the node alone."
    ;;
  Stopped | Starting)
    log "node is $state; tailscaled will sort it out, nothing to change."
    exit 0
    ;;
  *)
    log "node is in state '$state'; leaving it alone."
    exit 0
    ;;
esac

# ── Preferences ──────────────────────────────────────────────────────────────
#
# `tailscale set`, never `up`. Idempotent: setting a flag that is already set
# is a no-op that still succeeds, so this runs happily every few minutes
# without churning anything.
set_flags=()
[[ "$NM_TS_DESIRED_SSH" == "true" ]] && set_flags+=(--ssh=true) || set_flags+=(--ssh=false)
[[ "$NM_TS_ACCEPT_DNS" == "true" ]] && set_flags+=(--accept-dns=true) || set_flags+=(--accept-dns=false)
[[ "$NM_TS_EXIT_NODE" == "true" ]] && set_flags+=(--advertise-exit-node=true) || set_flags+=(--advertise-exit-node=false)

if "$NM_TAILSCALE" set "${set_flags[@]}"; then
  log "preferences converged: ${set_flags[*]}"
else
  fail "could not apply preferences (${set_flags[*]}). The node is reachable
         (it just answered status), so this is a permission or policy problem,
         not a connectivity one."
fi

# ── Serve ────────────────────────────────────────────────────────────────────
#
# Repair ONE mapping, and only if it is missing or pointing somewhere else.
#
# The test is the node's own view of what it serves (`tailscale serve status`),
# not a guess. If the right mapping is already there, nothing is written: this
# job must not be the reason a future media listener disappears, and must not
# churn the config of a mapping that is already correct.
serve_status() {
  "$NM_TAILSCALE" serve status --json 2>/dev/null || true
}

if [[ "$NM_TS_SERVE_HTTPS_PORT" -gt 0 && "$NM_TS_SERVE_TARGET_PORT" -gt 0 ]]; then
  status="$(serve_status)"

  # `serve status --json` is shaped as
  #   {"TCP":{"443":{"HTTPS":true}}, "Web":{ "<host>:443": {"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}
  # Only the HTTPS listener and its root Web handler count; other listeners,
  # paths, and longer port numbers must not mask a missing or incorrect mapping.
  if jq -e --arg https "$NM_TS_SERVE_HTTPS_PORT" \
    --arg proxy "http://127.0.0.1:$NM_TS_SERVE_TARGET_PORT" '
      .TCP[$https].HTTPS == true and
      any(.Web // {} | to_entries[];
        (.key | endswith(":" + $https)) and .value.Handlers["/"].Proxy == $proxy)
    ' <<<"$status" >/dev/null 2>&1; then
    log "Serve already maps HTTPS/$NM_TS_SERVE_HTTPS_PORT -> 127.0.0.1:$NM_TS_SERVE_TARGET_PORT; leaving it untouched"
  else
    log "Serve mapping for HTTPS/$NM_TS_SERVE_HTTPS_PORT is missing or points elsewhere; restoring it"
    if "$NM_TAILSCALE" serve --bg --https="$NM_TS_SERVE_HTTPS_PORT" "http://127.0.0.1:$NM_TS_SERVE_TARGET_PORT"; then
      log "Serve restored"
    else
      # A certificate that has not been issued yet is the expected transient
      # failure here; the timer retries. Say so, rather than leaving an error
      # that reads like a misconfiguration.
      warn "could not restore the Serve mapping on port $NM_TS_SERVE_HTTPS_PORT."
      warn "A .ts.net certificate is issued on first use and that needs working"
      warn "DNS to the control plane; this normally succeeds on a later run."
      exit 1
    fi
  fi

  # The name is what a browser and Collie's Host gate both use. Checked, not
  # assumed: a node that has come back up serving the wrong name is reachable
  # and looks healthy, which is exactly the failure that wastes an afternoon.
  if [[ -n "$NM_TS_SERVE_HOST" ]]; then
    dns_name="$("$NM_TAILSCALE" status --json 2>/dev/null |
      sed -n 's/.*"DNSName":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    dns_name="${dns_name%.}"
    if [[ -n "$dns_name" && "$dns_name" != "$NM_TS_SERVE_HOST" ]]; then
      warn "this node's DNSName is '$dns_name' but opts.mobileAgents.collie.serveHosts says '$NM_TS_SERVE_HOST'."
      warn "Collie's Host-header allowlist will refuse every request until they match."
      exit 1
    fi
    log "Serve host $dns_name matches the configured name"
  fi
fi

log "converged"
