#!/usr/bin/env bash
# nixos/tests/ns-maint-transaction.sh — failure injection against the real
# ns-maint state machine.
#
# Every test runs the actual script (not a re-implementation of it) with the
# deployment's NM_* overrides pointed at a disposable root and a fake `nix`,
# `nix-store`, `nix-env`, `systemctl`, `systemd-run`, `journalctl` and activation
# on PATH. Nothing here reproduces the tool's logic: it drives it and then
# asserts on the record it published, the state it left behind, and the calls it
# made.
#
# The scenarios are the ones the audit named, in the order a reader will look
# for them. Each one ends with assert_no_reboot, because "no implicit reboot" is
# a property of EVERY path rather than of the timeout path specifically.
#
# Run with nix/tests/run.sh, or directly:  bash nixos/tests/ns-maint-transaction.sh
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.sh
# shellcheck disable=SC1091
. "$HERE/lib/harness.sh"

printf '\n\033[1mns-maint maintenance transaction — failure injection\033[0m\n'

# ─────────────────────────────────────────────────────────────────────────────
# Detached deadline restoration regression tests.
t_start "deadline restoration survives stopping the watchdog service"
fixture_new
prepare_and_activate 300
sed -i 's/^deadline=.*/deadline=1/' "$NM_DIR/record.env"
export FAKE_SYSTEMD_RUN_MODE=background
export FAKE_STOP_DEADLINE_PID_FILE="$TMP/deadline.pid"
bash "$NS_MAINT_SCRIPT" tick >"$TMP/log/tick.out" 2>&1 &
deadline_pid=$!
printf '%s\n' "$deadline_pid" >"$FAKE_STOP_DEADLINE_PID_FILE"
wait "$deadline_pid" 2>/dev/null || true
limit=$(( $(date +%s) + 10 ))
while [[ "$(phase)" != restored && "$(date +%s)" -lt "$limit" ]]; do sleep 0.1; done
assert_eq restored "$(phase)" "a self-stopped watchdog cannot interrupt the restore worker"
assert_contains "$(fake_calls)" "--unit=ns-maint-restore-$(txid)" "restoration runs in its own service"
assert_contains "$(fake_calls)" "--property=TimeoutStartSec=31min" "worker keeps the outer restoration bound"
assert_no_reboot
t_done
fixture_free

t_start "queued restore workers recheck superseded records"
for change in wrong-txid confirmed cleared-deadline future-deadline; do
  fixture_new
  prepare_and_activate 300
  id="$(txid)"
  sed -i 's/^deadline=.*/deadline=1/' "$NM_DIR/record.env"
  case "$change" in
    wrong-txid) id=tx-19990101T000000Z-aaaaaa ;;
    confirmed) sed -i 's/^phase=.*/phase=confirmed/' "$NM_DIR/record.env" ;;
    cleared-deadline) sed -i 's/^deadline=.*/deadline=/' "$NM_DIR/record.env" ;;
    future-deadline) sed -i "s/^deadline=.*/deadline=$(( $(date +%s) + 300 ))/" "$NM_DIR/record.env" ;;
  esac
  before="$(cat "$NM_DIR/record.env")"
  out="$(ns_maint __run-restore "$id" 2>&1)" && rc=0 || rc=$?
  assert_eq 0 "$rc" "$change worker is a harmless no-op"
  assert_eq "$before" "$(cat "$NM_DIR/record.env")" "$change record stays unchanged"
  assert_not_contains "$(switch_calls)" "test $FAKE_RUNNING" "$change does not restore"
  fixture_free
done
t_done
t_start "a contended restore worker defers and a later tick retries interrupted restoration"
fixture_new
prepare_and_activate 300
sed -i -e 's/^deadline=.*/deadline=1/' -e 's/^phase=.*/phase=restoring/' "$NM_DIR/record.env"
before="$(cat "$NM_DIR/record.env")"
exec {held_restore_lock}>"$NM_DIR/lock"
flock "$held_restore_lock"
out="$(ns_maint __run-restore "$(txid)" 2>&1)" && rc=0 || rc=$?
assert_eq 0 "$rc" "a contended worker defers successfully"
assert_eq "$before" "$(cat "$NM_DIR/record.env")" "contention cannot change the record"
exec {held_restore_lock}>&-
ns_maint tick >"$TMP/log/tick.out" 2>&1
assert_eq restored "$(phase)" "a later tick retries and completes interrupted restoration"
assert_no_reboot
t_done
fixture_free

# End detached deadline restoration regression tests.

t_start "restore timeout rejects invalid and nonpositive durations"
fixture_new
for duration in invalid 0 0min -1; do
  out="$(NM_RESTORE_TIMEOUT="$duration" ns_maint status 2>&1)" && rc=0 || rc=$?
  assert_ne 0 "$rc" "restore duration $duration is refused"
done
out="$(NM_RESTORE_TIMEOUT=2min ns_maint status 2>&1)" && rc=0 || rc=$?
assert_eq 0 "$rc" "parser-format restore duration is accepted"
t_done
fixture_free

t_start "a build longer than the timeout causes zero activation and zero rollback"
fixture_new
# The build sleeps well past the timeout the operator was told about.
FAKE_BUILD_SLEEP=5
export FAKE_BUILD_SLEEP
out="$(ns_maint prepare --build-timeout 1 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "prepare fails when the build outlasts its own timeout"
assert_contains "$out" "Nothing was armed" "and says plainly that nothing was armed"
assert_eq "idle" "$(phase)" "phase is still idle"
assert_eq "" "$(rec_field deadline)" "no deadline exists to fire"
assert_not_contains "$(fake_calls)" "switch " "no activation was attempted"
assert_not_contains "$(switch_calls)" "$FAKE_CANDIDATE" "the candidate closure was never activated"
assert_no_file "$TMP/gcroots/ns-maint-candidate" "no candidate GC root was created"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "a build that outlasts any deadline does not roll anything back"
fixture_new
# No --build-timeout at all: the tool must not invent a deadline for the build
# phase. The armed window only exists from `activate` onwards, so a build of any
# length is simply a build.
FAKE_BUILD_SLEEP=2
export FAKE_BUILD_SLEEP
ns_maint prepare >"$TMP/log/prepare.out" 2>&1
assert_eq "prepared" "$(phase)" "a finished build leaves the candidate prepared"
assert_eq "" "$(rec_field deadline)" "preparing still arms no deadline"
assert_eq "" "$(rec_field old_running)" "and records no recovery closure yet"
assert_not_contains "$(switch_calls)" "switch " "nothing was activated"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "partial activation restores the original profile generation"
fixture_new
# The dangerous shape: activation reconfigures live units and then fails before
# the profile is touched. The old nswitch-safe read that as "no new generation
# exists, nothing to revert" and disarmed.
FAKE_SWITCH_CANDIDATE_EXIT=1
export FAKE_SWITCH_CANDIDATE_EXIT
prepare_and_activate 300
assert_eq "restored" "$(phase)" "the transaction ends restored, not idle"
assert_eq "restored-live" "$(rec_field restore_result)" "restoration is reported as having happened"
assert_contains "$(switch_calls)" "test $FAKE_RUNNING" "the OLD closure was re-activated, without a reboot"
assert_contains "$(fake_calls)" "profile-at-activation $FAKE_CANDIDATE" "the candidate profile is selected before activation"
assert_eq "system-7-link" "$(readlink "$NM_PROFILE")" "the original profile generation is restored through Nix"
assert_contains "$(fake_calls)" "switch-generation 7" "generation restoration uses nix-env"
assert_contains "$(cat "$TMP/log/activate.out" 2>/dev/null; cat "$TMP/log/unit.out")" "PARTIAL application" \
  "the operator is told partial application is possible"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "activation survives the caller disconnecting"
fixture_new
FAKE_SYSTEMD_RUN_MODE=background
FAKE_SWITCH_SLEEP=2
export FAKE_SYSTEMD_RUN_MODE FAKE_SWITCH_SLEEP
ns_maint prepare >/dev/null 2>&1

# Terminate the waiting CLI after its system service has started.
bash "$NS_MAINT_SCRIPT" activate --timeout 300 >"$TMP/log/activate.out" 2>&1 &
caller=$!
deadline=$(( $(date +%s) + 10 ))
while [[ "$(phase)" != "activating" && "$(date +%s)" -lt "$deadline" ]]; do
  sleep 0.05
done
assert_eq "activating" "$(phase)" "the client is waiting while the worker activates"
kill "$caller" 2>/dev/null && rc=0 || rc=$?
assert_eq 0 "$rc" "the waiting client is still alive and can be disconnected"
wait "$caller" 2>/dev/null || true

assert_contains "$(fake_calls)" "systemd-run --unit=ns-maint-activate-" \
  "activation was handed to a transient SYSTEM unit, not run inline"
assert_contains "$(cat "$TMP/log/activate.out")" "system service" "the caller is told where it is running"

# The detached worker finishes after the waiting CLI has exited.
deadline=$(( $(date +%s) + 30 ))
while [[ "$(phase)" == "armed" || "$(phase)" == "activating" ]] && [[ "$(date +%s)" -lt "$deadline" ]]; do
  sleep 0.2
done
assert_eq "awaiting-confirm" "$(phase)" "the detached unit completed and advanced the record by itself"
assert_contains "$(switch_calls)" "switch $FAKE_CANDIDATE" "the candidate really was activated"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "a second transaction is refused while one is pending"
fixture_new
prepare_and_activate 300
first="$(txid)"
out="$(ns_maint prepare 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "prepare is refused while a transaction is awaiting confirmation"
assert_contains "$out" "already awaiting-confirm" "and says which phase is in the way"
out="$(ns_maint activate --timeout 300 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "activate is refused too"
assert_contains "$out" "refusing to start a second transaction" "with an explicit reason"
assert_eq "$first" "$(txid)" "the pending transaction is untouched"
assert_no_reboot
t_done
fixture_free

t_start "a concurrent command does not corrupt the record, it backs off"
fixture_new
prepare_and_activate 300
first="$(txid)"
# Hold the lock the way a running tick or activation would.
mkdir -p "$NM_DIR"
exec 8>"$NM_DIR/lock"
flock -n 8
out="$(ns_maint confirm "$(txid)" 2>&1)" && rc=0 || rc=$?
exec 8>&-
assert_eq 75 "$rc" "a command that cannot take the lock exits 75 (retryable), not 1"
assert_contains "$out" "another ns-maint operation holds the lock" "and says why"
assert_eq "awaiting-confirm" "$(phase)" "the record is unchanged"
assert_eq "$first" "$(txid)" "same transaction, same id"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
# THE ACTIVATION DEADLOCK. Read this before changing anything about the exit code
# of tick/reconcile.
#
# On 2026-10-06 every ns-maint-driven activation on this host failed and rolled
# itself back:
#
#   ns-maint-reconcile.service: Main process exited, code=exited, status=75
#   warning: the following units failed: ns-maint-reconcile.service
#   switching to system configuration ... failed (status 4)
#   ns-maint: activation ... FAILED (exit 4). ... Restoring the previous closure.
#   ns-maint: RESTORATION DID NOT COMPLETE ... switch-to-configuration test
#             failed with exit 4
#
# The chain: ns-maint holds its exclusive lock for the whole activation.
# ns-maint-reconcile.service is WantedBy=multi-user.target with no
# RemainAfterExit, so it is inactive after every run and switch-to-configuration
# restarts it on EVERY activation (starting an active target re-pulls its Wants=
# units). The restarted reconcile cannot take the lock ns-maint is holding,
# exits 75, and switch-to-configuration turns any failed unit into exit 4 —
# which ns-maint reads as "activation failed". The rollback re-activates the old
# closure, which restarts the same unit, which fails the same way, so the
# restoration cannot complete either.
#
# It is tempting to read this as "only activations that change the ns-maint
# derivation are affected", because a changed derivation changes the unit
# definition. It is not: the unit definitions in the failing pair were
# byte-identical, and every plain `nixos-rebuild` activation of the same closure
# succeeded in the same window. The trigger is being an ns-maint activation at
# all, so a fix aimed only at restartIfChanged would fix nothing.
#
# The property under test is therefore: while the lock is held, tick and
# reconcile exit 0. A watchdog that can fail the activation it is watching is the
# bug; a watchdog that defers 30 seconds is not.
t_start "a contended tick or reconcile cannot fail an activation"
fixture_new
prepare_and_activate 300
first="$(txid)"
mkdir -p "$NM_DIR"
exec 8>"$NM_DIR/lock"
flock -n 8

# tick: the deadline watchdog. Deferring costs one tick interval.
out="$(ns_maint tick 2>&1)" && rc=0 || rc=$?
assert_eq 0 "$rc" "a contended tick exits 0, so its unit cannot fail an activation"
assert_contains "$out" "deferring" "and says it deferred rather than silently doing nothing"

# reconcile: the cold-boot classifier. Deferring costs a boot.
out="$(ns_maint reconcile 2>&1)" && rc=0 || rc=$?
assert_eq 0 "$rc" "a contended reconcile exits 0, so its unit cannot fail an activation"
assert_contains "$out" "deferring" "and says so"
assert_contains "$out" "next boot" "and names when it will actually run"

exec 8>&-
# Neither deferral may have touched the record: both are classifiers, and a
# skipped classification must be indistinguishable from a clean no-op.
assert_eq "awaiting-confirm" "$(phase)" "the record is unchanged by a deferred tick or reconcile"
assert_eq "$first" "$(txid)" "same transaction, same id"
assert_eq "$(rec_field deadline)" "$(rec_field deadline)" "and the deadline it was armed with"

# The operator-facing half of the contract is unchanged: a mutating command
# still refuses with a retryable status rather than proceeding unlocked.
exec 8>"$NM_DIR/lock"
flock -n 8
out="$(ns_maint confirm "$(txid)" 2>&1)" && rc=0 || rc=$?
exec 8>&-
assert_eq 75 "$rc" "a mutating command still exits 75, not 0 — deferring is for classifiers only"
assert_contains "$out" "another ns-maint operation holds the lock" "and says why"
assert_no_reboot
t_done
fixture_free

# The same invariant from the other side: activation itself, holding the lock the
# whole way, must not see either unit fail. This is the shape that deadlocked.
t_start "activation holds the lock without the watchdog units being able to fail it"
fixture_new
# A switch slow enough that the deadline timer would fire inside the window —
# the real timer is 30s and a real activation takes ~30s, so this is not a
# contrived interleaving, it is the ordinary case.
FAKE_SWITCH_SLEEP=3
export FAKE_SWITCH_SLEEP
ns_maint prepare >/dev/null 2>&1
ns_maint activate --timeout 300 >"$TMP/log/activate.out" 2>&1 &
activation_pid=$!
# Wait until the activation is inside switch-to-configuration, i.e. holding the
# lock, rather than guessing with a sleep.
for _ in $(seq 1 100); do
  [[ "$(switch_calls)" == *"$FAKE_CANDIDATE"* ]] && break
  sleep 0.05
done
# These two are what systemd runs when it restarts the Wants= units of
# multi-user.target during that activation.
ns_maint tick >"$TMP/log/tick-midflight.out" 2>&1 && rc=0 || rc=$?
tick_rc="$rc"
ns_maint reconcile >"$TMP/log/reconcile-midflight.out" 2>&1 && rc=0 || rc=$?
reconcile_rc="$rc"
wait "$activation_pid"

assert_eq 0 "$tick_rc" "the watchdog tick run mid-activation does not fail"
assert_eq 0 "$reconcile_rc" "the reconcile run mid-activation does not fail"
assert_eq "awaiting-confirm" "$(phase)" "the activation completes instead of rolling back"
assert_contains "$(switch_calls)" "switch $FAKE_CANDIDATE" "and the candidate really was activated"
assert_not_contains "$(switch_calls)" "test $FAKE_RUNNING" "no rollback was attempted at all"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "activation waits for completion before offering sudo confirmation"
fixture_new
prepare_and_activate 300
out="$(cat "$TMP/log/activate.out")"
assert_contains "$(fake_calls)" "--wait" "client waits for the system service"
assert_not_contains "$(fake_calls)" "--no-block" "client does not return during activation"
assert_contains "$out" "sudo ns-maint confirm $(txid)" "copyable confirmation uses sudo"
assert_contains "$out" "activation completed" "completion is explicit"
assert_no_reboot
t_done
fixture_free

t_start "a stale confirmation cannot confirm a newer transaction"
fixture_new
prepare_and_activate 300
stale="$(txid)"

# A new transaction starts. The operator's browser still has the old id.
ns_maint abort >/dev/null 2>&1
FAKE_BUILD_RESULT="$FAKE_OTHER_CANDIDATE"
export FAKE_BUILD_RESULT
prepare_and_activate 300
fresh="$(txid)"
assert_ne "$stale" "$fresh" "the second transaction has a different id"

as_ssh_session
now="$(date +%s)"
sshd_accepts "$((now + 1))" 51234

out="$(ns_maint confirm "$stale" 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "confirming with the OLD id is refused"
assert_contains "$out" "txid mismatch" "with an explicit mismatch message"
assert_contains "$out" "$fresh" "naming the transaction that is actually pending"
assert_eq "awaiting-confirm" "$(phase)" "the newer transaction is untouched by the stale confirmation"
assert_no_reboot
t_done
fixture_free

t_start "a malformed confirmation is refused before anything is checked"
fixture_new
prepare_and_activate 300
out="$(ns_maint confirm "../../etc/passwd" 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "a non-txid string is refused"
assert_contains "$out" "txid mismatch" "as a mismatch, not by being interpreted"
assert_eq "awaiting-confirm" "$(phase)" "nothing changed"
out="$(ns_maint confirm 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "confirm with no id at all is refused"
assert_contains "$out" "name the transaction" "and tells the operator which id to use"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "race: the operator confirms before the deadline"
fixture_new
prepare_and_activate 300
as_ssh_session
now="$(date +%s)"
sshd_accepts "$((now + 1))" 51234
id="$(txid)"
ns_maint confirm "$id" >"$TMP/log/confirm.out" 2>&1
assert_eq "confirmed" "$(phase)" "confirm before the deadline wins"
# And the watchdog, arriving afterwards, must find nothing to do.
ns_maint tick >"$TMP/log/tick.out" 2>&1
assert_eq "confirmed" "$(phase)" "a late watchdog tick does nothing at all"
assert_not_contains "$(cat "$TMP/log/tick.out")" "restoring" "and does not try to restore"
assert_no_reboot
t_done
fixture_free

t_start "race: the deadline wins, and a confirmation cannot undo it"
fixture_new
# A four-second window, not one.
#
# `activate` hands activation to a transient system unit and RETURNS, so for a
# moment the record is `activating`. Both this test and the next one need the
# record to be `awaiting-confirm` when they start racing, and with a one-second
# window a loaded machine closes the window DURING activation: the tool then
# legitimately restores from the activation path instead, the tick has nothing
# left to do, and the assertion below fails for a reason that is about timing
# rather than about the code. Four seconds makes the setup deterministic; the
# test still takes as long as it takes.
prepare_and_activate 4
wait_for_pending
assert_eq "awaiting-confirm" "$(phase)" "activation finished inside its own window"
sleep 5
as_ssh_session
now="$(date +%s)"
sshd_accepts "$((now + 1))" 51234
id="$(txid)"

ns_maint tick >"$TMP/log/tick.out" 2>&1
assert_eq "restored" "$(phase)" "the watchdog restores once the deadline has passed"
assert_contains "$(cat "$TMP/log/tick.out")" "deadline passed" "and says why"

out="$(ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "confirming after the restore is refused"
assert_contains "$out" "nothing is awaiting confirmation" "because the transaction is already over"
assert_no_reboot
t_done
fixture_free

t_start "race: the deadline has passed but the watchdog has not fired yet"
fixture_new
# Same setup as the test above, and for the same reason: the window has to
# outlive the activation so that "the deadline passed" and "the watchdog has not
# run yet" are two separate, observable states.
prepare_and_activate 4
wait_for_pending
assert_eq "awaiting-confirm" "$(phase)" "activation finished inside its own window"
sleep 5
as_ssh_session
now="$(date +%s)"
sshd_accepts "$((now + 1))" 51234
id="$(txid)"
out="$(ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "a confirmation after the window closes is refused even before restore"
assert_contains "$out" "confirmation window" "with the reason spelled out"
assert_eq "awaiting-confirm" "$(phase)" "the record is still pending, not silently confirmed"
ns_maint tick >/dev/null 2>&1
assert_eq "restored" "$(phase)" "and the watchdog then restores it"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "when restoration itself fails, it is reported plainly"
fixture_new
# Activation fails, and so does every route back: the live `switch` AND the
# `boot` fallback. The tool must not claim the machine is fine.
FAKE_SWITCH_CANDIDATE_EXIT=1
FAKE_SWITCH_OLD_EXIT=1
FAKE_SWITCH_OLD_BOOT_EXIT=1
export FAKE_SWITCH_CANDIDATE_EXIT FAKE_SWITCH_OLD_EXIT FAKE_SWITCH_OLD_BOOT_EXIT
prepare_and_activate 300
assert_eq "restore-failed" "$(phase)" "the phase says the restoration failed"
detail="$(rec_field restore_detail)"
assert_contains "$detail" "switch-to-configuration test failed" "the live failure is recorded"
assert_contains "$detail" "boot also failed" "the boot-intent fallback failure is recorded too"
out="$(cat "$TMP/log/unit.out")"
assert_contains "$out" "RESTORATION DID NOT COMPLETE" "the operator is told, in those words"
assert_contains "$out" "may still be running SOME of the failed candidate" "and is warned about partial application"
assert_no_reboot
t_done
fixture_free

t_start "boot intent is written even when live restoration fails"
fixture_new
FAKE_SWITCH_CANDIDATE_EXIT=1
FAKE_SWITCH_OLD_EXIT=1
FAKE_SWITCH_OLD_BOOT_EXIT=0
export FAKE_SWITCH_CANDIDATE_EXIT FAKE_SWITCH_OLD_EXIT FAKE_SWITCH_OLD_BOOT_EXIT
prepare_and_activate 300
assert_eq "restore-failed" "$(phase)" "still a failure, because the live restore did not work"
assert_contains "$(switch_calls)" "boot $FAKE_RUNNING" "but the old closure's bootloader entry WAS written"
assert_not_contains "$(rec_field restore_detail)" "boot also failed" "the boot fallback is recorded as having SUCCEEDED, not failing"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "a record left pending by a crash is reconciled after a cold boot"
fixture_new
prepare_and_activate 300
id="$(txid)"

# The machine rebooted INTO the candidate (someone pressed reboot, or another
# tool did). It comes back on the candidate.
ln -sfn "$FAKE_CANDIDATE" "$TMP/run/booted-system"
ns_maint reconcile >"$TMP/log/reconcile.out" 2>&1
assert_eq "reconciled-booted" "$(phase)" "classified as booted-into-candidate"
assert_eq "" "$(rec_field deadline)" "the deadline is cleared, so no watchdog fires afterwards"
assert_contains "$(cat "$TMP/log/reconcile.out")" "NO rollback will fire" "and the operator is told that"

# Reconciliation must be idempotent: a second boot must not re-arm anything.
ns_maint reconcile >"$TMP/log/reconcile2.out" 2>&1
assert_eq "reconciled-booted" "$(phase)" "reconciling again changes nothing"
assert_eq "" "$(rec_field deadline)" "and still arms nothing"
SSH_CONNECTION="" ns_maint confirm "$id" --assume-new-connection >"$TMP/log/confirm.out" 2>&1
assert_eq "confirmed" "$(phase)" "the reconciled candidate can be confirmed"
assert_no_gc_root candidate "confirmation releases the candidate root"
assert_no_gc_root running "confirmation releases the recovery root"
assert_no_reboot
t_done
fixture_free

t_start "a cold boot on the OLD closure does not retry the transaction"
fixture_new
prepare_and_activate 300
id="$(txid)"
# It came back on the old closure: the window never took effect on this kernel.
ln -sfn "$FAKE_RUNNING" "$TMP/run/booted-system"
activations_before="$(grep -c "switch $FAKE_CANDIDATE" "$TMP/log/switch" || true)"
ns_maint reconcile >"$TMP/log/reconcile.out" 2>&1
activations_after="$(grep -c "switch $FAKE_CANDIDATE" "$TMP/log/switch" || true)"
assert_eq "reconciled-not-applied" "$(phase)" "classified as not-applied"
assert_eq "" "$(rec_field deadline)" "deadline cleared"
assert_contains "$(cat "$TMP/log/reconcile.out")" "nothing was retried" "explicitly no automatic retry"
assert_eq "$activations_before" "$activations_after" "reconcile did not activate the candidate a second time"
# Running it repeatedly must converge, not oscillate.
ns_maint reconcile >/dev/null 2>&1
ns_maint reconcile >/dev/null 2>&1
assert_eq "reconciled-not-applied" "$(phase)" "repeated cold boots converge rather than looping"
assert_no_reboot
t_done
fixture_free

t_start "a crash during restoration is resolved honestly on the next boot"
fixture_new
FAKE_SWITCH_CANDIDATE_EXIT=1
FAKE_SWITCH_OLD_EXIT=1
export FAKE_SWITCH_CANDIDATE_EXIT FAKE_SWITCH_OLD_EXIT
prepare_and_activate 300
assert_eq "restore-failed" "$(phase)" "restoration failed and said so"

# Now simulate: it was mid-restore when the machine went down, and came back on
# the old closure — which is the case a reboot could genuinely have fixed.
# Rewrite the record to look like a crash mid-restore left it. sed, not python:
# the suite's only dependencies are bash, coreutils, findutils, git and grep.
sed -i -e 's|^phase=.*|phase=restoring|' -e 's|^deadline=.*|deadline=|' "$NM_DIR/record.env"
ns_maint reconcile >/dev/null 2>&1
assert_eq "restored" "$(phase)" "rebooting onto the recovery closure counts as restored"
assert_eq "restored-by-reboot" "$(rec_field restore_result)" "and the record says WHY it is considered restored"

# And the case where it came back on neither.
sed -i 's|^phase=.*|phase=restoring|' "$NM_DIR/record.env"
ln -sfn "$FAKE_OTHER_CANDIDATE" "$TMP/run/booted-system"
ns_maint reconcile >/dev/null 2>&1
assert_eq "restore-failed" "$(phase)" "booting onto neither closure is NOT called a success"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "recovery, booted and candidate closures are pinned against GC"
fixture_new
prepare_and_activate 300
assert_gc_root candidate "the candidate is pinned the moment it is built"
assert_gc_root running "the recovery closure is pinned when the deadline is armed"
assert_gc_root booted "the booted closure is pinned too"
assert_not_contains "$(fake_calls)" "gc --delete" "no collection is asked to delete generations"

as_ssh_session
sshd_accepts "$(( $(date +%s) + 1 ))" 51234
ns_maint confirm "$(txid)" >"$TMP/log/confirm.out" 2>&1
assert_eq "confirmed" "$(phase)" "the transaction is confirmed before the roots are checked"
assert_no_gc_root running "confirming releases the recovery closure root"
assert_no_gc_root candidate "and the candidate root"
assert_gc_root booted "but the booted closure stays pinned until you reboot"
assert_no_reboot
t_done
fixture_free

t_start "ns-maint gc collects without ever deleting generations"
fixture_new
out="$(ns_maint gc --keep 3 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "unsupported retention safely refuses"
assert_not_contains "$(fake_calls)" "--gc" "no collection is run"
assert_contains "$out" "--keep is not supported" "the operator is told why"
ns_maint gc >"$TMP/log/gc.out" 2>&1
assert_contains "$(fake_calls)" 'nix-store --gc' 'ordinary collection actually runs'
assert_not_contains "$(fake_calls)" '--delete-generations' 'generation links are never removed'
assert_gc_root running 'the running closure is protected before collection'
assert_gc_root booted 'the booted closure is protected before collection'
assert_gc_root profile 'the selected profile is protected before collection'
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "confirmation is an operator decision independent of SSH transport"
fixture_new
prepare_and_activate 300
id="$(txid)"
out="$(SSH_CONNECTION="" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
assert_eq 0 "$rc" "console confirmation needs no SSH evidence flag"
assert_eq "confirmed" "$(phase)" "the operator confirms the exact candidate"
assert_contains "$(rec_field confirm_connection)" "operator confirmed" "operator decision is recorded honestly"
assert_not_contains "$(fake_calls)" "journalctl -u sshd" "no SSH journal parsing"
assert_no_reboot
t_done
fixture_free

t_start "failed services are reported without blocking operator confirmation"
fixture_new
FAKE_FAILED_UNITS="unrelated.service loaded failed failed Reload"
export FAKE_FAILED_UNITS
prepare_and_activate 300
id="$(txid)"
out="$(SSH_CONNECTION="" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
assert_eq 0 "$rc" "failed service does not override operator decision"
assert_contains "$out" "failed systemd unit" "the warning remains visible"
assert_eq "1" "$(rec_field health_failed_units)" "health evidence remains recorded"
assert_eq "confirmed" "$(phase)" "the transaction is confirmed"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "a candidate carrying a new kernel is refused for live activation"
fixture_new
# The candidate has a different kernel than the running closure. A live switch
# cannot load it, and activating userspace that expects different kernel modules
# is precisely the "Driver/library version mismatch" failure.
make_closure "$FAKE_CANDIDATE" "6.6.0-newkernel"
ns_maint prepare >/dev/null 2>&1
out="$(ns_maint activate --timeout 300 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "live activation is refused"
assert_contains "$out" "different kernel" "with the reason"
assert_contains "$out" "ns-maint stage" "and the correct alternative"
assert_eq "prepared" "$(phase)" "the record is still just 'prepared' — nothing was armed"
assert_eq "" "$(rec_field deadline)" "and no deadline exists"
assert_not_contains "$(switch_calls)" "switch $FAKE_CANDIDATE" "nothing was activated"
assert_no_reboot
t_done
fixture_free

t_start "staging writes a boot entry without switching anything live"
fixture_new
make_closure "$FAKE_CANDIDATE" "6.6.0-newkernel"
ns_maint prepare >/dev/null 2>&1
ns_maint stage >"$TMP/log/stage.out" 2>&1
assert_contains "$(switch_calls)" "boot $FAKE_CANDIDATE" "the bootloader entry was written for the candidate"
assert_not_contains "$(switch_calls)" "switch $FAKE_CANDIDATE" "but nothing was switched live"
assert_eq "$FAKE_RUNNING" "$(readlink -f "$NM_CURRENT_SYSTEM")" "the running system is unchanged"
assert_contains "$(cat "$TMP/log/stage.out")" "reboot only when you have chosen to" "staging does not reboot"
assert_gc_root candidate "the staged candidate is pinned so it survives until you reboot"
assert_no_reboot
t_done
fixture_free

t_start "reboot is refused without an explicit --yes"
fixture_new
out="$(ns_maint reboot 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "reboot without --yes does nothing"
assert_contains "$out" "refusing without --yes" "with an explanation"
assert_contains "$out" "Nothing in this tool reboots implicitly" "and the reason the contract exists"
assert_no_reboot
t_done
fixture_free

t_start "reboot while a transaction is pending is refused"
fixture_new
prepare_and_activate 300
out="$(ns_maint reboot --yes 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "an armed/pending transaction blocks a reboot"
assert_contains "$out" "Confirm or abort it first" "telling the operator what to do about it"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "an all-input update cannot be requested by accident"
fixture_new
out="$(ns_maint prepare --update-all 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "--update-all is refused"
assert_contains "$out" "--update-input nixpkgs" "and the named-input form is suggested"
assert_not_contains "$(fake_calls)" "flake update" "no flake was touched"
out="$(ns_maint prepare --update-input nixpkgs 2>&1)"
assert_contains "$(fake_calls)" "flake update --flake $TMP/flake nixpkgs" "one named input is updated, with the flake selected by --flake"
assert_contains "$(fake_calls)" "flake-update inputs=nixpkgs" "the fake nix saw exactly the one input named"
assert_not_contains "$(fake_calls)" "--all" "and nothing asked for a blanket update"
assert_no_reboot
t_done
fixture_free

t_start "an input name that is really an option is refused before nix sees it"
fixture_new
out="$(ns_maint prepare --update-input --all 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "an option-shaped input name is refused"
assert_contains "$out" "not a flake input name" "with the reason"
assert_not_contains "$(fake_calls)" "flake update" "nix was never invoked at all"
assert_no_reboot
t_done
fixture_free

t_start "inaccessible state is an error rather than a fictitious idle transaction"
fixture_new
prepare_and_activate 300
chmod 000 "$NM_DIR"
out="$(ns_maint status 2>&1)" && rc=0 || rc=$?
chmod 700 "$NM_DIR"
assert_ne 0 "$rc" "status refuses inaccessible state"
assert_contains "$out" "sudo ns-maint status" "status explains how to read it"
assert_not_contains "$out" "no transaction has ever run" "status does not invent an empty record"
t_done
fixture_free

t_start "the record is validated rather than trusted"
fixture_new
prepare_and_activate 300
# Simulate a hand-edited or corrupted record.
sed -i 's|^candidate=.*|candidate=/tmp/not-a-store-path|' "$NM_DIR/record.env"
out="$(ns_maint status 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "a record with a bogus store path is refused"
assert_contains "$out" "is not a Nix store path" "with the reason"
t_done
fixture_free

t_start "a record from another host is refused"
fixture_new
prepare_and_activate 300
sed -i 's|^host=.*|host=some-other-box|' "$NM_DIR/record.env"
out="$(ns_maint status 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "a record belonging to another host is refused"
assert_contains "$out" "belongs to host" "with the reason"
t_done
fixture_free

t_start "an unknown phase is refused rather than guessed at"
fixture_new
prepare_and_activate 300
sed -i 's|^phase=.*|phase=probably-fine|' "$NM_DIR/record.env"
out="$(ns_maint status 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "an unrecognised phase is a hard error"
assert_contains "$out" "not a known phase" "with the reason"
assert_no_reboot
t_done
fixture_free

t_start "verify-installation reports the invariants the tool assumes"
fixture_new
ns_maint verify-installation >"$TMP/log/verify.out" 2>&1
assert_eq 0 "$?" "a correctly laid-out state directory verifies"
chmod 777 "$NM_DIR"
out="$(ns_maint verify-installation 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "a world-writable state directory fails"
assert_contains "$out" "mode" "naming the mode"
chmod 700 "$NM_DIR"
assert_no_reboot
t_done
fixture_free

t_start "unprivileged callers cannot mutate the transaction"
fixture_new
prepare_and_activate 300
out="$(env NM_TEST_MODE=0 bash "$NS_MAINT_SCRIPT" confirm "$(txid)" 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "confirm refuses without privilege"
assert_contains "$out" "must run as root" "and says so"
assert_eq "awaiting-confirm" "$(phase)" "nothing changed"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "the ordinary happy path arms once, activates once, and reboots never"
fixture_new
ns_maint prepare >/dev/null 2>&1
assert_eq "prepared" "$(phase)" "prepare"
ns_maint activate --timeout 300 >/dev/null 2>&1
assert_eq "awaiting-confirm" "$(phase)" "activate"
as_ssh_session
now="$(date +%s)"
sshd_accepts "$((now + 1))" 51234
ns_maint confirm "$(txid)" >/dev/null 2>&1
assert_eq "confirmed" "$(phase)" "confirm"
assert_eq 1 "$(grep -c 'switch switch' "$TMP/log/switch" || true)" "exactly one live activation happened"
assert_no_reboot
t_done
fixture_free

t_start "prepare consumes offline and online flags"
fixture_new
timeout 5 bash "$NS_MAINT_SCRIPT" prepare --offline --tag flags >"$TMP/log/prepare.out" 2>&1
assert_eq 0 "$?" "offline prepare terminates"
assert_contains "$(fake_calls)" "--offline" "offline reaches nix build"
: >"$TMP/log/calls"
timeout 5 bash "$NS_MAINT_SCRIPT" prepare --offline --online --tag flags >"$TMP/log/prepare.out" 2>&1
assert_eq 0 "$?" "online prepare terminates"
assert_not_contains "$(fake_calls)" "--offline" "online overrides offline"
t_done
fixture_free

for kernel_case in changed-modules unknown-candidate unknown-running; do
  t_start "kernel override: $kernel_case"
  fixture_new
  if [[ "$kernel_case" == changed-modules ]]; then
    modules="$NM_STORE_PREFIX/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-modules-rebuilt"
    mkdir -p "$modules/lib/modules/6.1.0-test"
    ln -sfn "$modules" "$FAKE_CANDIDATE/kernel-modules"
  elif [[ "$kernel_case" == unknown-candidate ]]; then
    rm "$FAKE_CANDIDATE/kernel-modules"
  else
    rm "$FAKE_RUNNING/kernel-modules"
  fi
  ns_maint prepare >/dev/null 2>&1
  ns_maint activate --timeout 300 >"$TMP/log/refusal.out" 2>&1 && rc=0 || rc=$?
  assert_ne 0 "$rc" "dirty or unknown signatures require refusal"
  timeout 5 bash "$NS_MAINT_SCRIPT" activate --allow-unknown-kernel --timeout 300 >"$TMP/log/override.out" 2>&1 && rc=0 || rc=$?
  out="$(cat "$TMP/log/override.out")"
  if [[ "$kernel_case" == changed-modules ]]; then
    assert_ne 0 "$rc" "override cannot bypass known module changes with the same version"
    assert_eq prepared "$(phase)" "no transaction is armed"
    assert_not_contains "$out" "WARNING" "known differences produce no unknown warning"
    assert_eq "" "$(switch_calls)" "no activation occurs"
  else
    assert_eq 0 "$rc" "unknown signature override terminates successfully"
    assert_eq awaiting-confirm "$(phase)" "unknown signature override activates"
    assert_contains "$out" "WARNING" "unknown signature produces a warning"
  fi
  t_done
  fixture_free
done

t_start "a hung activation is killed at the deadline and restored under the lock"
fixture_new
FAKE_SWITCH_SLEEP=30
FAKE_SWITCH_IGNORE_TERM=1
export FAKE_SWITCH_SLEEP FAKE_SWITCH_IGNORE_TERM
ns_maint prepare >/dev/null 2>&1
start=$(date +%s)
ns_maint activate --timeout 3 >"$TMP/log/activate.out" 2>&1 &
activation_pid=$!
for ((attempt=0; attempt<30; attempt++)); do
  [[ "$(switch_calls)" == *"$FAKE_CANDIDATE"* ]] && break
  sleep 0.05
done
# The watchdog defers rather than interleaving: it must not interleave (the
# record below still says the activation's own deadline did the restoring) and
# it must not fail either, because this tick runs while the activation holds
# the lock and a nonzero exit here is a failed unit that rolls the activation
# back. See "a contended tick or reconcile cannot fail an activation".
ns_maint tick >"$TMP/log/tick.out" 2>&1 && rc=0 || rc=$?
assert_eq 0 "$rc" "the watchdog cannot interleave with activation, and cannot fail it either"
assert_contains "$(cat "$TMP/log/tick.out")" "deferring" "it reports that it deferred"
wait "$activation_pid"
assert_eq restored "$(phase)" "a hung activation restores without waiting for the watchdog"
assert_contains "$(rec_field note)" "deadline-expired" "the deadline is recorded as the restore reason"
assert_contains "$(switch_calls)" "test $FAKE_RUNNING" "the recovery closure is activated"
assert_eq system-7-link "$(readlink "$NM_PROFILE")" "the old generation is restored"
# Written as if/then rather than `cond && ok || fail`: the short form runs the
# FAILURE branch whenever the success branch returns non-zero, which is a trap
# waiting for an _ok that ever grows an exit status of its own.
if [[ $(( $(date +%s) - start )) -lt 15 ]]; then
  _ok "activation is bounded"
else
  _fail "activation exceeded its bound"
fi
assert_no_reboot
t_done
fixture_free

t_start "profile selection failure restores without activating the candidate"
fixture_new
FAKE_PROFILE_SET_EXIT=9
export FAKE_PROFILE_SET_EXIT
prepare_and_activate 300
assert_eq restored "$(phase)" "profile selection failure restores"
assert_contains "$(rec_field note)" "profile-update-failed-rc-9" "the failure is recorded"
assert_not_contains "$(switch_calls)" "$FAKE_CANDIDATE" "candidate activation was never invoked"
assert_contains "$(switch_calls)" "$FAKE_RUNNING" "old runtime was restored"
t_done
fixture_free

t_start "restoration removes a profile that was originally absent"
fixture_new
rm "$NM_PROFILE"
FAKE_SWITCH_CANDIDATE_EXIT=7
export FAKE_SWITCH_CANDIDATE_EXIT
prepare_and_activate 300
assert_eq restore-failed "$(phase)" "absent profile cannot claim boot intent restored"
assert_contains "$(switch_calls)" "test $FAKE_RUNNING" "runtime still recovers"
assert_not_contains "$(switch_calls)" "boot $FAKE_RUNNING" "no invented boot intent"
assert_no_file "$NM_PROFILE" "the candidate profile is removed"
if [[ ! -L "$NM_PROFILE" ]]; then
  _ok "no dangling profile remains"
else
  _fail "a profile link remains"
fi
t_done
fixture_free

for pending in armed activating awaiting-confirm restoring; do
  t_start "stage refuses a $pending transaction without mutation"
  fixture_new
  prepare_and_activate 300
  sed -i "s/^phase=.*/phase=$pending/" "$NM_DIR/record.env"
  before="$(cat "$NM_DIR/record.env")"
  calls_before="$(switch_calls)"
  root_before="$(readlink "$NM_GCROOTS/ns-maint-candidate")"
  ns_maint stage --candidate "$FAKE_OTHER_CANDIDATE" >"$TMP/log/stage.out" 2>&1 && rc=0 || rc=$?
  assert_ne 0 "$rc" "stage is refused"
  assert_contains "$(cat "$TMP/log/stage.out")" "$pending" "the pending phase is named"
  assert_eq "$before" "$(cat "$NM_DIR/record.env")" "the entire record is preserved"
  assert_eq "$calls_before" "$(switch_calls)" "no boot or live activation occurs"
  assert_eq "$root_before" "$(readlink "$NM_GCROOTS/ns-maint-candidate")" "the candidate root is preserved"
  t_done
  fixture_free
done

t_start "prepare uses the toplevel output and default documented duration"
fixture_new
ns_maint prepare >"$TMP/log/prepare.out" 2>&1
assert_contains "$(fake_calls)" "#nixosConfigurations.legion.config.system.build.toplevel" "prepare selects the real NixOS output"
ns_maint activate >"$TMP/log/activate.out" 2>&1
assert_eq awaiting-confirm "$(phase)" "20min default parses and applies"
assert_eq 1200 "$(( $(rec_field deadline) - $(rec_field armed_at) ))" "default is twenty minutes"
ns_maint abort >/dev/null 2>&1
ns_maint prepare >/dev/null 2>&1
ns_maint activate --timeout 90sec >/dev/null 2>&1
assert_eq awaiting-confirm "$(phase)" "documented sec duration parses"
assert_no_reboot
t_done
fixture_free

t_start "restore keeps distinct runtime and profile intent"
fixture_new
distinct_profile="$(fake_store_path profile-intent)"
make_closure "$distinct_profile" "6.1.0-test"
ln -sfn "$distinct_profile" "${NM_PROFILE}-7-link"
FAKE_SWITCH_CANDIDATE_EXIT=7
export FAKE_SWITCH_CANDIDATE_EXIT
prepare_and_activate 300
assert_eq restored "$(phase)" "distinct intents restore successfully"
assert_eq "$FAKE_RUNNING" "$(readlink -f "$NM_CURRENT_SYSTEM")" "runtime is the recorded runtime"
assert_eq "$distinct_profile" "$(readlink -f "$NM_PROFILE")" "profile remains the distinct recorded profile"
assert_contains "$(switch_calls)" "boot $distinct_profile" "profile-derived boot intent is restored"
assert_gc_root "profile-$(txid)" "distinct profile closure is immutably pinned"
assert_no_reboot
t_done
fixture_free

t_start "profile restore failure cannot report green"
fixture_new
FAKE_SWITCH_CANDIDATE_EXIT=7
FAKE_PROFILE_RESTORE_EXIT=9
export FAKE_SWITCH_CANDIDATE_EXIT FAKE_PROFILE_RESTORE_EXIT
prepare_and_activate 300
assert_eq restore-failed "$(phase)" "successful runtime recovery does not hide profile failure"
assert_contains "$(rec_field restore_detail)" "profile restoration failed" "failure is recorded"
assert_no_reboot
t_done
fixture_free

t_start "stage registers a generation and restores profile and boot on failure"
fixture_new
ns_maint prepare >/dev/null 2>&1
FAKE_SWITCH_CANDIDATE_EXIT=7
export FAKE_SWITCH_CANDIDATE_EXIT
ns_maint stage >"$TMP/log/stage.out" 2>&1 && rc=0 || rc=$?
assert_ne 0 "$rc" "failed staging is reported"
assert_contains "$(fake_calls)" "profile-at-activation $FAKE_CANDIDATE" "candidate was registered before boot generation discovery"
assert_eq system-7-link "$(readlink "$NM_PROFILE")" "old profile is restored"
assert_contains "$(switch_calls)" "boot $FAKE_RUNNING" "old boot intent is restored"
assert_eq "$FAKE_RUNNING" "$(readlink -f "$NM_CURRENT_SYSTEM")" "no live activation occurs"
assert_no_reboot
t_done
fixture_free

t_start "restore runtime and boot hangs are bounded"
fixture_new
FAKE_SWITCH_CANDIDATE_EXIT=7
FAKE_SWITCH_OLD_SLEEP=30
NM_RESTORE_TIMEOUT=1sec
export FAKE_SWITCH_CANDIDATE_EXIT FAKE_SWITCH_OLD_SLEEP NM_RESTORE_TIMEOUT
start=$(date +%s)
prepare_and_activate 300
assert_eq restore-failed "$(phase)" "both hung recovery steps fail visibly"
assert_contains "$(rec_field restore_detail)" "boot also failed" "boot timeout is recorded"
if [[ $(( $(date +%s) - start )) -lt 10 ]]; then _ok "restore is bounded"; else _fail "restore exceeded bound"; fi
assert_no_reboot
t_done
fixture_free

t_start "store-backed settings survive a clean environment and reject caller NM overrides"
fixture_new
# Render the package's configuration prelude around the same source script.
# Only FAKE_* test controls remain ambient; deployment NM_* inputs are embedded.
configured="$TMP/bin/ns-maint-configured"
{
  printf '#!%s\n' "$(command -v bash)"
  # Literal package prelude, executed by the child.
  # shellcheck disable=SC2016
  printf '%s\n' 'for nm_variable in "${!NM_@}"; do unset "$nm_variable"; done'
  for name in "${!NM_@}"; do
    printf 'export %s=%q\n' "$name" "${!name}"
  done
  tail -n +2 "$NS_MAINT_SRC"
} >"$configured"
chmod +x "$configured"
# Strip deployment values exactly as sudo and a system manager do. Poisoning
# caller values must also not replace the embedded host or activation seam.
clean=(env)
for name in "${!NM_@}"; do clean+=(-u "$name"); done
"${clean[@]}" NM_HOST=wrong NM_NIX=/nonexistent "$configured" prepare >"$TMP/log/prepare.out" 2>&1
assert_eq 0 "$?" "prepare runs with trusted host/flake and commands"
assert_eq legion "$(rec_field host)" "caller host is ignored"
"${clean[@]}" NM_SWITCH_TO_CONFIGURATION=/nonexistent "$configured" activate --timeout 90sec >"$TMP/log/activate.out" 2>&1
assert_eq 0 "$?" "transient activation reloads trusted configuration"
assert_eq awaiting-confirm "$(phase)" "activation completes without manager NM injection"
assert_no_reboot
t_done
fixture_free

t_start "a staged candidate boot is reconciled for explicit confirmation"
fixture_new
ns_maint prepare >/dev/null 2>&1
ns_maint stage >"$TMP/log/stage.out" 2>&1
assert_eq staged "$(phase)" 'successful staging has a durable distinct phase'
ln -sfn "$FAKE_CANDIDATE" "$NM_BOOTED_SYSTEM"
ln -sfn "$FAKE_CANDIDATE" "$NM_CURRENT_SYSTEM"
ns_maint reconcile >"$TMP/log/reconcile.out" 2>&1
assert_eq reconciled-booted "$(phase)" 'booting the staged closure still requires confirmation'
assert_eq '' "$(rec_field deadline)" 'no automatic rollback/reboot is armed at boot'
assert_no_reboot
t_done
fixture_free

t_start "interrupted staging is visible and never retried automatically"
fixture_new
ns_maint prepare >/dev/null 2>&1
ns_maint stage >/dev/null 2>&1
sed -i 's/^phase=staged$/phase=staging/' "$NM_DIR/record.env"
: >"$TMP/log/switch"
ns_maint reconcile >"$TMP/log/reconcile.out" 2>&1 && rc=0 || rc=$?
assert_ne 0 "$rc" 'a interrupted profile/boot mutation is not a green no-op'
assert_eq stage-interrupted "$(phase)" 'the durable record requires operator recovery'
assert_eq '' "$(switch_calls)" 'reconciliation itself touches neither runtime nor boot intent'
ns_maint abort "$(txid)" >"$TMP/log/abort.out" 2>&1
assert_eq restored "$(phase)" 'explicit abort restores recorded runtime/profile/boot intent'
assert_eq system-7-link "$(readlink "$NM_PROFILE")" 'original profile intent is recovered'
assert_no_reboot
t_done
fixture_free

# Closed version-1 wire contract, also usable in a Nix sandbox without .git.
t_start "version 1 wire remains readable across generations"
fixture_new
prepare_and_activate 300
wire_keys='schema_version phase txid host operation candidate old_running old_profile old_gen booted deadline armed_at activated_at restore_result restore_detail staged_candidate confirmed_at confirm_peer confirm_connection health_failed_units health_checked_at reconciled_at note'
while IFS='=' read -r key _; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  case " $wire_keys " in
    *" $key "*) ;;
    *) _fail "wire contains non-version-1 key $key" ;;
  esac
done <"$NM_DIR/record.env"
assert_not_contains "$(<"$NM_DIR/record.env")" 'old_profile_closure=' "derived closure is not persisted"
# Exercise the ACTUAL original closed reader, read-only, never its mutators.
# Pin the pre-audit reader: HEAD becomes the fixed implementation after commit.
legacy_reader_commit=927020cfae1180a2e8b194af8c1858513c8c3727
if git -C "$HERE" show "$legacy_reader_commit:nixos/config/system/maintenance/ns-maint.sh" >"$TMP/old-reader.sh" 2>/dev/null; then
  cp "$NM_DIR/record.env" "$TMP/compatible-record"
  printf 'old_profile_closure=%s\n' "$FAKE_RUNNING" >>"$NM_DIR/record.env"
  out="$(bash "$TMP/old-reader.sh" status --json 2>&1)" && rc=0 || rc=$?
  assert_ne 0 "$rc" "pre-audit closed reader rejects the intermediate writer field"
  assert_contains "$out" "unknown key 'old_profile_closure'" "actual regression is reproduced"
  cp "$TMP/compatible-record" "$NM_DIR/record.env"
  for old_phase in awaiting-confirm restoring restored; do
    sed -i "s/^phase=.*/phase=$old_phase/" "$NM_DIR/record.env"
    bash "$TMP/old-reader.sh" status --json >"$TMP/old-status.json" 2>&1 && rc=0 || rc=$?
    assert_eq 0 "$rc" "pre-audit reader accepts fixed $old_phase wire"
  done
  sed -i 's/^phase=.*/phase=staging/' "$NM_DIR/record.env"
  bash "$TMP/old-reader.sh" status --json >"$TMP/old-status.json" 2>&1 && rc=0 || rc=$?
  assert_ne 0 "$rc" "unsupported staging remains fail closed in the pre-audit reader"
else
  printf '    SKIP pre-audit reader smoke: historical Git object unavailable; version-1 wire contract checked above\n'
fi
assert_no_reboot
t_done
fixture_free

for recovery_case in legacy-gen legacy-direct absolute-gen missing-gen missing-both hint-only conflict malformed-path mismatch-gen corrupt-anchor corrupt-generation hint-conflict; do
  t_start "captured profile recovery: $recovery_case"
  fixture_new
  distinct_profile="$(fake_store_path profile-intent)"
  make_closure "$distinct_profile" "6.1.0-test"
  ln -sfn "$distinct_profile" "${NM_PROFILE}-7-link"
  FAKE_BOOTED="$(fake_store_path booted-C)"
  make_closure "$FAKE_BOOTED" "6.1.0-test"
  ln -sfn "$FAKE_BOOTED" "$NM_BOOTED_SYSTEM"
  if [[ "$recovery_case" == legacy-direct ]]; then
    ln -sfn "$distinct_profile" "$NM_PROFILE"
  fi
  prepare_and_activate 300
  anchor="$TMP/gcroots/ns-maint-profile-$(txid)"
  assert_file "$anchor" "transaction-specific anchor exists"
  case "$recovery_case" in
    legacy-gen|legacy-direct) rm "$anchor" ;;
    absolute-gen) sed -i "s|^old_profile=.*|old_profile=${NM_PROFILE}-7-link|" "$NM_DIR/record.env" ;;
    missing-gen) rm "${NM_PROFILE}-7-link" ;;
    missing-both) rm "${NM_PROFILE}-7-link" "$anchor" ;;
    hint-only)
      rm "${NM_PROFILE}-7-link" "$anchor"
      printf 'old_profile_closure=%s\n' "$distinct_profile" >>"$NM_DIR/record.env"
      ;;
    conflict) ln -sfn "$FAKE_RUNNING" "${NM_PROFILE}-7-link" ;;
    malformed-path) sed -i 's|^old_profile=.*|old_profile=../system-7-link|' "$NM_DIR/record.env" ;;
    mismatch-gen) sed -i 's/^old_gen=.*/old_gen=8/' "$NM_DIR/record.env" ;;
    corrupt-anchor) ln -sfn /tmp/not-a-store-path "$anchor" ;;
    corrupt-generation) ln -sfn /tmp/not-a-store-path "${NM_PROFILE}-7-link" ;;
    hint-conflict) printf 'old_profile_closure=%s\n' "$FAKE_RUNNING" >>"$NM_DIR/record.env" ;;
  esac
  : >"$TMP/log/switch"
  ns_maint abort "$(txid)" >"$TMP/log/abort.out" 2>&1 && rc=0 || rc=$?
  case "$recovery_case" in
    legacy-gen|legacy-direct|absolute-gen|missing-gen)
      assert_eq 0 "$rc" "recorded B can be resolved without a persisted derived field"
      assert_eq restored "$(phase)" "both intents restored"
      assert_contains "$(switch_calls)" "test $FAKE_RUNNING" "A runtime recovered"
      assert_contains "$(switch_calls)" "boot $distinct_profile" "B boot intent recovered"
      assert_eq "$distinct_profile" "$(readlink -f "$NM_PROFILE")" "B profile recovered"
      ;;
    missing-both|hint-only)
      assert_ne 0 "$rc" "lost B cannot produce a green restore"
      assert_eq restore-failed "$(phase)" "resolution failure recorded"
      assert_contains "$(switch_calls)" "test $FAKE_RUNNING" "A runtime still recovers"
      assert_not_contains "$(switch_calls)" "boot " "no A fallback boot"
      ;;
    *)
      assert_ne 0 "$rc" "corrupt captured intent refused"
      assert_eq '' "$(switch_calls)" "corrupt targets never execute"
      ;;
  esac
  assert_eq "$FAKE_BOOTED" "$(readlink -f "$NM_BOOTED_SYSTEM")" "booted C never changes"
  assert_no_reboot
  t_done
  fixture_free
done

t_start "GC retains captured B anchor and every generation link"
fixture_new
prepare_and_activate 300
anchor="$TMP/gcroots/ns-maint-profile-$(txid)"
ln -sfn "$FAKE_OTHER_CANDIDATE" "${NM_PROFILE}-2-link"
ln -sfn "$FAKE_RUNNING" "${NM_PROFILE}-3-link"
ns_maint gc >"$TMP/log/gc.out" 2>&1 && rc=0 || rc=$?
assert_ne 0 "$rc" "pending transaction refuses GC"
assert_file "$anchor" "GC retains transaction anchor"
for retained_gen in 2 3 7 8; do
  assert_file "${NM_PROFILE}-${retained_gen}-link" "GC retains generation $retained_gen"
done
ns_maint gc --keep 1 >"$TMP/log/gc-keep.out" 2>&1 && rc=0 || rc=$?
assert_ne 0 "$rc" "--keep remains refused"
assert_file "$anchor" "refused retention preserves anchor"
assert_no_reboot
t_done
fixture_free

t_start "GC refuses every pending phase before changing roots or collecting"
fixture_new
prepare_and_activate 300
for pending in staging stage-interrupted armed activating awaiting-confirm restoring; do
  sed -i "s/^phase=.*/phase=$pending/" "$NM_DIR/record.env"
  before="$(fake_calls)"
  out="$(ns_maint gc 2>&1)" && rc=0 || rc=$?
  assert_ne 0 "$rc" "GC refuses $pending"
  assert_contains "$out" "pending ($pending)" "refusal identifies $pending"
  assert_eq "$before" "$(fake_calls)" "no protection or collection calls during $pending"
done
assert_no_reboot
t_done
fixture_free

t_start "reboot onto A cannot bless interrupted recovery of distinct B"
fixture_new
distinct_profile="$(fake_store_path profile-intent)"
make_closure "$distinct_profile" "6.1.0-test"
ln -sfn "$distinct_profile" "${NM_PROFILE}-7-link"
prepare_and_activate 300
sed -i 's/^phase=.*/phase=restoring/' "$NM_DIR/record.env"
ln -sfn "$FAKE_RUNNING" "$NM_BOOTED_SYSTEM"
ln -sfn "$FAKE_RUNNING" "$NM_CURRENT_SYSTEM"
ns_maint reconcile >"$TMP/log/reconcile.out" 2>&1
assert_eq restore-failed "$(phase)" "booted A alone cannot establish B restoration"
assert_contains "$(rec_field restore_detail)" "rebooted onto $FAKE_RUNNING" "correctly identifies reboot onto A"
assert_contains "$(rec_field restore_detail)" "current runtime=$FAKE_RUNNING" "reports observed runtime"
assert_contains "$(rec_field restore_detail)" "recorded runtime=$FAKE_RUNNING, profile=$distinct_profile" "reports distinct recovery intents"
assert_not_contains "$(rec_field restore_detail)" "neither" "does not misidentify recovery runtime"
sed -i 's/^phase=.*/phase=restoring/' "$NM_DIR/record.env"
rm "$NM_PROFILE"
ns_maint reconcile >/dev/null 2>&1
assert_contains "$(rec_field restore_detail)" 'profile=<unresolved>' "reports unresolved current profile"
assert_no_reboot
t_done
fixture_free

t_start "unknown ESP capacity refuses staging before profile or boot mutation"
fixture_new
ns_maint prepare >"$TMP/log/prepare.out" 2>&1
printf '#!%s\nexit 1\n' "$(command -v bash)" >"$NM_DF"
ns_maint stage >"$TMP/log/stage.out" 2>&1 && rc=0 || rc=$?
assert_ne 0 "$rc" "failed ESP capacity query refuses staging"
assert_contains "$(<"$TMP/log/stage.out")" "refusing bootloader writes" "inconclusive preflight is fail closed"
assert_not_contains "$(switch_calls)" "boot " "no boot write after failed preflight"
assert_eq "$FAKE_RUNNING" "$(readlink -f "$NM_PROFILE")" "selected profile remains intact"
assert_no_reboot
t_done
fixture_free

suite_summary "ns-maint transaction"