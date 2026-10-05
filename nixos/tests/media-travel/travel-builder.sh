#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Native transport contracts taken from the pinned herdr CLI: --machine is
# API-only; --remote attaches a TUI. No server lifecycle operations in fixtures.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"
printf '=== travel-builder ===\n'
SCRIPT="$HERE/../../config/home/scripts/herdr-travel.sh"
FAKE="$FIXTURE_TMP/bin"
CALLS="$FIXTURE_TMP/herdr-calls.log"
mkdir -p "$FAKE"
export CALLS
cat >"$FAKE/herdr" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  'machine list --json')
    if [[ "${MACHINE_MISSING:-0}" == 1 ]]; then echo '[]'; else
      echo '[{"id":"wQ6:t5","label":"legion","target":"ssh://sonny@legion:2222","session":"agents","enabled":true}]'
    fi ;;
  'machine status wQ6:t5 --json')
    # Upstream checks the remote endpoint. Its endpoint generation is 1;
    # private protocol is 22. Those values are NOT compared to each other.
    if [[ "${REMOTE_INCOMPATIBLE:-0}" == 1 ]]; then
      echo '[{"id":"wQ6:t5","status":"error","error":"incompatible remote"}]'
    else echo '[{"id":"wQ6:t5","status":"reachable","error":null}]'; fi ;;
  '--remote ssh://sonny@legion:2222 --session agents'|'--remote ssh://sonny@legion:2222 --session chosen') exit 0 ;;
  '--machine wQ6:t5 workspace list') exit 0 ;;
  *) echo 'unsupported fake CLI invocation' >&2; exit 91 ;;
esac
FAKE
sed -i "1s|^#!.*|#!$(command -v bash)|" "$FAKE/herdr"
chmod +x "$FAKE/herdr"
run_helper() {
  PATH="$FAKE:$PATH" bash "$SCRIPT" "$@" >"$FIXTURE_TMP/out" 2>"$FIXTURE_TMP/err"
  RUN_STATUS=$?
}
: >"$CALLS"
run_helper attach legion
if [[ "$RUN_STATUS" == 0 ]]; then ok 'native remote attachment succeeds'; else bad 'compatible attach failed' "$(cat "$FIXTURE_TMP/err")"; fi
if grep -Fq -- '--remote ssh://sonny@legion:2222 --session agents' "$CALLS"; then ok 'attachment uses the saved SSH target and session'; else bad 'saved remote context was not used'; fi
run_helper attach legion chosen
if [[ "$RUN_STATUS" == 0 ]]; then ok 'explicit remote session is honored'; else bad 'session override failed'; fi
run_helper run legion workspace list
if [[ "$RUN_STATUS" == 0 ]]; then ok 'remote API command succeeds'; else bad 'API command failed'; fi
if grep -Fq -- '--machine wQ6:t5 workspace list' "$CALLS"; then ok 'API uses an explicit machine ID'; else bad 'API retargeting is implicit'; fi
: >"$CALLS"
export REMOTE_INCOMPATIBLE=1
run_helper attach legion
if [[ "$RUN_STATUS" != 0 ]]; then ok 'incompatible remote is refused'; else bad 'incompatible attach succeeded'; fi
if grep -qi 'CLIENT' "$FIXTURE_TMP/err"; then ok 'failure does not recommend restarting the server'; else bad 'missing client/fallback guidance'; fi
if grep -Eq -- '^--remote|^--machine|^server|^update' "$CALLS"; then bad 'incompatible transport was attached or mutated'; else ok 'preflight failure touches no server lifecycle'; fi
unset REMOTE_INCOMPATIBLE
export MACHINE_MISSING=1
run_helper attach absent
if [[ "$RUN_STATUS" != 0 ]]; then ok 'unknown saved machine is refused'; else bad 'missing machine accepted'; fi
unset MACHINE_MISSING
: >"$CALLS"
run_helper local touch "$FIXTURE_TMP/local-ran"
if [[ -e "$FIXTURE_TMP/local-ran" && ! -s "$CALLS" ]]; then ok 'offline fallback never contacts herdr'; else bad 'offline fallback contacted herdr'; fi
: >"$CALLS"
run_helper run legion server stop
if [[ "$RUN_STATUS" != 0 ]] && ! grep -Eq '(^| )server stop($| )' "$CALLS" &&
  grep -Fq 'server lifecycle commands are refused' "$FIXTURE_TMP/err"; then
  ok 'helper refuses server lifecycle commands before forwarding'
else
  bad 'helper did not refuse server lifecycle commands' "$(cat "$FIXTURE_TMP/err")"
fi
run_helper
if grep -q -- 'explicit --machine' "$FIXTURE_TMP/err"; then ok 'usage describes explicit remote targeting'; else bad 'usage hides remote targeting'; fi
summary 'travel-builder'
