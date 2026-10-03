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
assert_contains "$(switch_calls)" "switch $FAKE_RUNNING" "the OLD closure was re-activated, without a reboot"
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

# Abandon the caller: run activate, do not wait for it, and let it go. The
# fake systemd-run detaches the unit, exactly as the real one does.
ns_maint activate --timeout 300 >"$TMP/log/activate.out" 2>&1
assert_eq "armed" "$(phase)" "activate returned before the (deliberately slow) activation finished"

assert_contains "$(fake_calls)" "systemd-run --unit=ns-maint-activate-" \
  "activation was handed to a transient SYSTEM unit, not run inline"
assert_contains "$(cat "$TMP/log/activate.out")" "system service" "the caller is told where it is running"

# Now kill the "caller": nothing below waits on it. The unit finishes on its own.
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
sshd_accepts "$now" 51234

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
sshd_accepts "$now" 51234
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
prepare_and_activate 1
sleep 2
as_ssh_session
now="$(date +%s)"
sshd_accepts "$now" 51234
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
prepare_and_activate 1
sleep 2
as_ssh_session
now="$(date +%s)"
sshd_accepts "$now" 51234
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
assert_contains "$detail" "switch-to-configuration switch failed" "the live failure is recorded"
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
sshd_accepts "$(date +%s)" 51234
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
out="$(ns_maint gc --keep 3 2>&1)"
assert_contains "$(fake_calls)" "nix-store --gc --keep 3" "collection runs with an explicit retention"
assert_not_contains "$(fake_calls)" "--delete" "and never passes --delete"
assert_contains "$out" "generations are NOT deleted" "the operator is told that outright"
assert_no_reboot
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "confirmation requires evidence that a NEW connection got in"
fixture_new
prepare_and_activate 300
id="$(txid)"
as_ssh_session "100.64.1.2 51234 100.64.1.9 22"
# sshd logged this session BEFORE the switch was armed — i.e. this is the socket
# that was already open, which is the case the old workflow accepted.
old_ts=$(( $(date +%s) - 600 ))
sshd_accepts "$old_ts" 51234
out="$(ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "an already-open session cannot confirm"
assert_contains "$out" "no NEW sshd session" "with the reason"
assert_contains "$out" "proves nothing about whether a fresh client can get in" "and why an old socket proves nothing"
assert_eq "awaiting-confirm" "$(phase)" "still pending"

# Now a genuinely new connection, accepted after arming.
new_ts=$(( $(date +%s) + 1 ))
sshd_accepts "$new_ts" 51234
ns_maint confirm "$id" >"$TMP/log/confirm.out" 2>&1
assert_eq "confirmed" "$(phase)" "a new connection confirms"
assert_contains "$(rec_field confirm_connection)" "after the switch was armed" "and the evidence is stored in the record"
assert_no_reboot
t_done
fixture_free

t_start "confirmation refuses when local health evidence is not clean"
fixture_new
FAKE_FAILED_UNITS="sshd.service loaded failed failed Reload"
export FAKE_FAILED_UNITS
prepare_and_activate 300
as_ssh_session
now="$(date +%s)"
sshd_accepts "$now" 51234
id="$(txid)"
out="$(ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "a failed unit blocks confirmation"
assert_contains "$out" "failed systemd unit" "and the failing units are named"
assert_eq "awaiting-confirm" "$(phase)" "the transaction is not confirmed"
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
assert_contains "$(fake_calls)" "flake update $TMP/flake nixpkgs" "one named input is updated"
assert_not_contains "$(fake_calls)" "--all" "and nothing asked for a blanket update"
assert_no_reboot
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
sshd_accepts "$now" 51234
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
ns_maint tick >"$TMP/log/tick.out" 2>&1 && rc=0 || rc=$?
assert_eq 75 "$rc" "the watchdog cannot interleave with activation"
wait "$activation_pid"
assert_eq restored "$(phase)" "a hung activation restores without waiting for the watchdog"
assert_contains "$(rec_field note)" "deadline-expired" "the deadline is recorded as the restore reason"
assert_contains "$(switch_calls)" "switch $FAKE_RUNNING" "the recovery closure is activated"
assert_eq system-7-link "$(readlink "$NM_PROFILE")" "the old generation is restored"
[[ $(( $(date +%s) - start )) -lt 15 ]] && _ok "activation is bounded" || _fail "activation exceeded its bound"
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
assert_eq restored "$(phase)" "failed activation restores"
assert_no_file "$NM_PROFILE" "the candidate profile is removed"
[[ ! -L "$NM_PROFILE" ]] && _ok "no dangling profile remains" || _fail "a profile link remains"
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

suite_summary "ns-maint transaction"