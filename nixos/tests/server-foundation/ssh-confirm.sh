#!/usr/bin/env bash
# Operator confirmation works across transports without parsing login logs.
set -o nounset -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/harness.sh
# shellcheck disable=SC1091
. "$HERE/../lib/harness.sh"

for connection in "" "100.64.1.2 51234 100.64.1.9 22" "127.0.0.1 51023 127.0.0.1 2222"; do
  t_start "operator confirmation works with SSH_CONNECTION='$connection'"
  fixture_new
  prepare_and_activate 300
  id="$(txid)"
  out="$(SSH_CONNECTION="$connection" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
  assert_eq 0 "$rc" "confirmation accepts the operator's decision"
  assert_eq confirmed "$(phase)" "the exact candidate is confirmed"
  assert_contains "$(rec_field confirm_connection)" "not automatically verified" "record does not claim verified network evidence"
  assert_not_contains "$(fake_calls)" "journalctl -u sshd" "no transport-specific log parsing"
  assert_no_reboot
  t_done
  fixture_free
done

t_start "a running closure mismatch still prevents confirmation"
fixture_new
prepare_and_activate 300
ln -sfn "$FAKE_RUNNING" "$NM_CURRENT_SYSTEM"
out="$(ns_maint confirm "$(txid)" 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "cannot confirm a different running system"
assert_contains "$out" "does not match the candidate" "refusal explains the closure mismatch"
assert_eq awaiting-confirm "$(phase)" "transaction remains pending for recovery"
assert_no_reboot
t_done
fixture_free

if [[ "$TESTS_FAILED" -ne 0 ]]; then
  printf 'ssh-confirm: %d assertion(s) failed\n' "$TESTS_FAILED"
  exit 1
fi
printf 'ssh-confirm: all %d checks passed\n' "$TESTS_RUN"
