#!/usr/bin/env bash
# nixos/tests/media-travel/lib/fixture.sh
#
# Shared helpers for the media-travel suites.
#
# The central trick in here is `fake_root_bin`: netns-up.sh does its real work
# through `ip`, `iptables`, `ip6tables` and `sysctl`, all of which it takes from
# the environment so they can be overridden. That makes it possible to run the
# SHIPPED SCRIPT — not a copy of it, and not a reimplementation of its logic —
# and assert on exactly the netfilter calls it would have made, with no
# CAP_NET_ADMIN and no host mutation.
#
# That distinction is the whole point. A test that greps netns-up.sh for the
# string "DROP" proves the word is in the file. This one proves the script
# installs a DROP policy, that it installs one on BOTH stacks, that it refuses
# a hostname endpoint outright, and that its only non-tunnel egress rule is a
# single UDP flow — which are the properties that actually decide whether the
# namespace leaks.
#
# shellcheck shell=bash

set -uo pipefail

: "${FIXTURE_TMP:="$(mktemp -d "${TMPDIR:-/tmp}/media-travel.XXXXXX")"}"
export FIXTURE_TMP

cleanup_fixture() {
  # Only ever removes the directory this fixture created.
  case "$FIXTURE_TMP" in
    /tmp/media-travel.*|"${TMPDIR:-/tmp}"/media-travel.*) rm -rf -- "$FIXTURE_TMP" ;;
    *) printf 'refusing to remove unexpected path: %s\n' "$FIXTURE_TMP" >&2; return 1 ;;
  esac
}
trap cleanup_fixture EXIT

_pass=0
_fail=0

ok() {
  _pass=$((_pass + 1))
  printf '    ok   %s\n' "$1"
}

bad() {
  _fail=$((_fail + 1))
  printf '    FAIL %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '         %s\n' "$2" >&2
  return 0
}

summary() {
  printf '  --- %s: %s passed, %s failed ---\n' "${1:-suite}" "$_pass" "$_fail" >&2
  [[ "$_fail" -eq 0 ]]
}

# fake_root_bin <dir>
#
# Must be CALLED, not captured: it exports FAKE_LOG, and a command substitution
# runs in a subshell where that export is lost.
#
# Installs stubs for the four privileged tools. Each appends its full argument
# list, one call per line, to $FAKE_LOG. `ip` additionally understands enough
# of the netns subcommands to behave sensibly: `netns add` "succeeds",
# `netns del` on a missing namespace "fails" so the script's `|| true` is
# exercised rather than accidentally satisfied.
fake_root_bin() {
  local dir="$1"
  mkdir -p "$dir"
  export FAKE_LOG="$dir/calls.log"
  : >"$FAKE_LOG"

  cat >"$dir/ip" <<'EOF'
#!/usr/bin/env bash
printf 'ip %s\n' "$*" >>"$FAKE_LOG"
# `netns del` on an absent namespace must FAIL, so the caller's `|| true` is
# genuinely exercised rather than passing because the stub always succeeds.
if [[ "$1" == "netns" && "$2" == "del" ]]; then exit 1; fi
exit 0
EOF

  for tool in iptables ip6tables sysctl; do
    cat >"$dir/$tool" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >>"\$FAKE_LOG"
exit 0
EOF
  done

  chmod +x "$dir"/ip "$dir"/iptables "$dir"/ip6tables "$dir"/sysctl
  # Deliberately prints nothing: the caller passes in $dir, because this
  # function's one real side effect (exporting FAKE_LOG) cannot survive a
  # command substitution.
}

# run_netns_up <stubdir> <endpoint> [webui_port]
#
# Runs the shipped script with the stubs on PATH. Returns its exit status; the
# recorded calls are left in $FAKE_LOG for the caller to assert against.
run_netns_up() {
  local stubs="$1" endpoint="$2" webui="${3:-18080}"
  PATH="$stubs:$PATH" \
    MEDI_IP="$stubs/ip" \
    MEDI_IPT="$stubs/iptables" \
    MEDI_IP6T="$stubs/ip6tables" \
    MEDI_SYSCTL="$stubs/sysctl" \
    MEDI_NS="medtns" \
    MEDI_VETH_HOST="mthost" \
    MEDI_VETH_NS="mtns0" \
    MEDI_GATEWAY="10.77.0.1" \
    MEDI_WG_IF="wg0" \
    MEDI_WEBUI_PORT="$webui" \
    MEDI_WG_ENDPOINT="$endpoint" \
    bash "$MEDIA_SCRIPTS/netns-up.sh" >"$stubs/stdout" 2>"$stubs/stderr"
}

# log_has <pattern> — did the recorded command log contain this?
log_has() { grep -qF -- "$1" "$FAKE_LOG"; }

# count_log <pattern> — how many recorded calls contain this?
count_log() { grep -cF -- "$1" "$FAKE_LOG" || true; }


# Resolved here rather than by each suite: the media scripts ARE what these
# suites test, and a wrong path would quietly turn a suite into testing nothing.
MEDIA_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../config/system/media/scripts" 2>/dev/null && pwd || true)"
: "${MEDIA_SCRIPTS:?could not locate nixos/config/system/media/scripts}"
export MEDIA_SCRIPTS