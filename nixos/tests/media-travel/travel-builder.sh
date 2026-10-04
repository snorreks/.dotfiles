#!/usr/bin/env bash
# nixos/tests/media-travel/travel-builder.sh
#
# Audit checklist: "Test builder SSH2222 protocol, credentials absent,
# unauthorized command and remote outage/local fallback; CLI incompatibility
# never restarts server."
#
# The herdr half is tested against a FAKE herdr on PATH, which is the only way
# to assert the two properties that matter:
#
#   * a client that cannot speak the server's protocol REFUSES, and
#   * nothing in the helper ever restarts, upgrades or replaces a server.
#
# The second is a TRIPWIRE, not a grep: the fake records every invocation and
# writes a marker for any subcommand that is not a read-only query. Asserting
# "the script does not contain the word restart" would prove nothing about a
# script that shells out to something else.
#
# The Nix builder half (port 2222, protocol ssh-ng) is asserted in
# host-isolation.sh, because it is a fact about the evaluated configuration
# rather than about a script.
#
# shellcheck shell=bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"

printf '=== travel-builder ===\n'

SCRIPT="$HERE/../../config/home/scripts/herdr-travel.sh"
if ! bash -n "$SCRIPT"; then
  bad "herdr-travel.sh does not parse"
  summary "travel-builder"
  exit 1
fi
ok "herdr-travel.sh parses"

FAKE="$FIXTURE_TMP/bin"
TRIPWIRE="$FIXTURE_TMP/SERVER-WAS-TOUCHED"
CALLS="$FIXTURE_TMP/herdr-calls.log"
mkdir -p "$FAKE"

# make_fake_herdr <client-gen> <server-gen> [tripwire]
#
# A stand-in for the real CLI: global flags are skipped, then the subcommand is
# answered. `session attach` returns success — the subject under test is the
# protocol negotiation and the machine-id resolution, not session handling.
make_fake_herdr() {
  local client_gen="$1" server_gen="$2" trip="${3:-}"
  cat >"$FAKE/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
# The --machine flag takes a VALUE, so shifting only on the leading dashes would
# stop on the id and mistake it for the subcommand. Both halves are skipped.
while [[ "\$#" -gt 0 ]]; do
  case "\$1" in
    --machine|--session) shift 2 ;;
    --*) shift ;;
    *) break ;;
  esac
done
case "\$1" in
  status|machine|session|workspace|tab|pane|agent|api|config|channel|notification) ;;
  *)
    if [[ -n "$trip" ]]; then : >"$trip"; fi
    exit 1
    ;;
esac
case "\$1" in
  status)
    printf 'client:\n  endpoint_protocol_generation: $client_gen\nserver:\n  private_protocol: $server_gen\n'
    ;;
  machine)
    printf '[{"id":"wQ6:t5","label":"legion","name":"legion"}]\n'
    ;;
esac
exit 0
EOF
  chmod +x "$FAKE/herdr"
}

run_helper() {
  local out err
  out="$FIXTURE_TMP/h.out"
  err="$FIXTURE_TMP/h.err"
  PATH="$FAKE:$PATH" bash "$SCRIPT" "$@" >"$out" 2>"$err"
  RUN_STATUS=$?
  RUN_OUT="$out"
  RUN_ERR="$err"
}

# ── 1. Compatible client: attach succeeds, with an EXPLICIT machine id ─────
: >"$CALLS"
make_fake_herdr 22 22
run_helper attach legion
if [[ "$RUN_STATUS" -eq 0 ]]; then
  ok "attach succeeds against a compatible server"
else
  bad "attach failed on a compatible server" "$(cat "$RUN_ERR")"
fi
if grep -q -- "--machine wQ6:t5" "$CALLS"; then
  ok "the machine is addressed by EXPLICIT remote id (--machine wQ6:t5)"
else
  bad "no explicit --machine was used" "$(cat "$CALLS")"
fi
if grep -q -- "session attach" "$CALLS"; then
  ok "the attach subcommand was actually issued"
else
  bad "no attach subcommand was issued" "$(cat "$CALLS")"
fi

# ── 2. Incompatible client: REFUSE, explain, and touch nothing ─────────────
: >"$CALLS"
rm -f "$TRIPWIRE"
make_fake_herdr 21 22 "$TRIPWIRE"
run_helper attach legion
if [[ "$RUN_STATUS" -ne 0 ]]; then
  ok "an incompatible client is refused (exit $RUN_STATUS)"
else
  bad "an incompatible client was allowed to proceed"
fi
if grep -qiE "refus|incompatible" "$RUN_ERR"; then
  ok "the refusal explains itself"
else
  bad "the refusal does not explain itself" "$(cat "$RUN_ERR")"
fi
if grep -qiE "herdr update|updating the herdr CLI" "$RUN_ERR"; then
  ok "the refusal points at fixing the CLIENT, not the server"
else
  bad "no guidance on how to fix the mismatch" "$(cat "$RUN_ERR")"
fi
if grep -q -- "--machine" "$CALLS"; then
  bad "a remote command was attempted despite the incompatibility" "$(cat "$CALLS")"
else
  ok "no remote command is attempted once the client is known to be incompatible"
fi
if [[ -e "$TRIPWIRE" ]]; then
  bad "the helper invoked a non-read-only herdr subcommand" "$(cat "$CALLS")"
else
  ok "the helper never restarted, upgraded or replaced the server"
fi

# ── 3. Unreadable server status: refuse rather than guess ──────────────────
make_fake_herdr 22 22
cat >"$FAKE/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
exit 1
EOF
chmod +x "$FAKE/herdr"
run_helper attach legion
if [[ "$RUN_STATUS" -ne 0 ]]; then
  ok "an unreadable 'herdr status' refuses rather than guessing"
else
  bad "proceeded without a readable 'herdr status'"
fi
if grep -qiE "fallback|--local" "$RUN_ERR"; then
  ok "the refusal points at the local fallback"
else
  bad "no mention of the local fallback" "$(cat "$RUN_ERR")"
fi

# ── 4. Unknown machine: refuse and say how to add one ─────────────────────
make_fake_herdr 22 22
cat >"$FAKE/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
# The --machine flag takes a VALUE, so shifting only on the leading dashes would
# stop on the id and mistake it for the subcommand. Both halves are skipped.
while [[ "\$#" -gt 0 ]]; do
  case "\$1" in
    --machine|--session) shift 2 ;;
    --*) shift ;;
    *) break ;;
  esac
done
if [[ "\$1" == status ]]; then
  printf 'client:\n  endpoint_protocol_generation: 22\nserver:\n  private_protocol: 22\n'
  exit 0
fi
if [[ "\$1" == machine ]]; then printf '[]\n'; exit 0; fi
exit 0
EOF
chmod +x "$FAKE/herdr"
run_helper attach nosuchmachine
if [[ "$RUN_STATUS" -ne 0 ]]; then
  ok "an unknown machine label is refused"
else
  bad "attached to a machine that does not exist"
fi
if grep -qiE "no saved machine|herdr machine list" "$RUN_ERR"; then
  ok "the refusal names the problem and how to fix it"
else
  bad "the refusal does not say how to add the machine" "$(cat "$RUN_ERR")"
fi

# ── 5. Offline fallback: runs locally, never contacts herdr ───────────────
# This is the case that matters on hotel wifi: a remote outage must not stop
# local work, so `local` must not depend on any herdr server being reachable.
marker="$FIXTURE_TMP/local-ran"
rm -f "$marker"
: >"$CALLS"
cat >"$FAKE/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
exit 1
EOF
chmod +x "$FAKE/herdr"
run_helper local touch "$marker"
if [[ -e "$marker" ]]; then
  ok "the local fallback runs the command"
else
  bad "the local fallback did not run the command" "$(cat "$RUN_ERR")"
fi
if [[ -s "$CALLS" ]]; then
  bad "the local fallback consulted herdr" "$(cat "$CALLS")"
else
  ok "the local fallback never contacts herdr (works with no server at all)"
fi

# ── 6. Usage is honest about the explicit --machine requirement ───────────
make_fake_herdr 22 22
run_helper
if grep -qi "explicit --machine" "$RUN_OUT" "$RUN_ERR"; then
  ok "usage states that remote commands need an explicit --machine"
else
  bad "usage does not mention the explicit --machine requirement"
fi

summary "travel-builder"