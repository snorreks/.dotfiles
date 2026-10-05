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
# a hostname endpoint outright, and permits only established WebUI replies on
# the management veth. Encrypted UDP sockets use host routing, not veth egress.
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
  # Resolved once, here, because the stubs are executed by netns-up.sh and a
  # "#!/usr/bin/env bash" shebang fails outright in the nix build sandbox, where
  # /usr/bin/env does not exist. nixos/tests/README.md records this for the
  # other lanes' fakes; the stubs inherit the same constraint.
  local TEST_BASH="${TEST_BASH:-}"
  if [[ -z "$TEST_BASH" ]]; then
    TEST_BASH="$(command -v bash || true)"
  fi
  if [[ ! -x "$TEST_BASH" ]]; then
    printf 'fixture: no bash found; set TEST_BASH to an absolute path\n' >&2
    return 1
  fi
  mkdir -p "$dir"
  export FAKE_LOG="$dir/calls.log"
  : >"$FAKE_LOG"

  cat >"$dir/ip" <<'EOF'
@@BASH@@
printf 'ip %s\n' "$*" >>"$FAKE_LOG"
# `netns del` on an absent namespace must FAIL, so the caller's `|| true` is
# genuinely exercised rather than passing because the stub always succeeds.
if [[ "$1" == "netns" && "$2" == "del" ]]; then exit 1; fi
# `netns exec NS CMD ARGS...` runs CMD inside the namespace. Recorded with the
# namespace stripped and the command marked, so a suite can assert that a
# firewall call was SCOPED rather than issued against the host.
if [[ "$1" == "netns" && "$2" == "exec" ]]; then
  shift 3
  # Shift THREE, not two: the argv is `netns exec <NS> <cmd> <args...>`, so
  # shifting only "netns exec" leaves the namespace name as the command and the
  # command as its first argument — which is exactly what an earlier version
  # did, recording `NSEXEC medtns /nix/store/…/iptables` and matching nothing.
  #
  # The command NAME is recorded, not the stub's store path, because the
  # assertions anchor on "NSEXEC iptables -w -A OUTPUT -j DROP".
  printf 'NSEXEC %s %s\n' "${1##*/}" "${*:2}" >>"$FAKE_LOG"
  exit 0
fi
exit 0
EOF

  for tool in iptables ip6tables sysctl; do
    cat >"$dir/$tool" <<'EOF'
@@BASH@@
printf '%s %s\n' "${0##*/}" "$*" >>"$FAKE_LOG"
exit 0
EOF
  done

  # Shebang written last, from a placeholder. It cannot be interpolated into a
  # quoted heredoc (that is the whole point of the quoted heredoc: the stub body
  # contains $1, $2 and $*, which must survive verbatim), and it cannot be
  # interpolated by switching the heredoc to unquoted, because then the BODY is
  # what gets expanded. So the stub is written with @@BASH@@ and patched.
  for stub in ip iptables ip6tables sysctl; do
    sed -i "1s|@@BASH@@|$TEST_BASH|" "$dir/$stub"
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

# ns_has <pattern> — did a command recorded as running INSIDE the namespace
# contain this? A firewall rule that exists but ran in the host namespace is a
# host-wide DROP policy, which on an unattended box is a lockout.
ns_has() { grep -F "NSEXEC" "$FAKE_LOG" | grep -qF -- "$1"; }


# Resolved here rather than by each suite: the media scripts ARE what these
# suites test, and a wrong path would quietly turn a suite into testing nothing.
MEDIA_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../config/system/media/scripts" 2>/dev/null && pwd || true)"
: "${MEDIA_SCRIPTS:?could not locate nixos/config/system/media/scripts}"
export MEDIA_SCRIPTS