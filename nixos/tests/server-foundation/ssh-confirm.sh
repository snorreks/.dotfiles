#!/usr/bin/env bash
# nixos/tests/server-foundation/ssh-confirm.sh — the NEW-session check that
# `ns-maint confirm` performs, against BOTH OpenSSH listeners this host has.
#
# ── Why this suite exists ────────────────────────────────────────────────────
# The check is the one piece of the maintenance contract that could not be
# verified by reading the configuration: it asks sshd's own journal whether a
# session from THIS peer was accepted after the switch was armed. If the unit it
# reads, or the peer it identifies, or the timestamp it compares against is
# wrong, the failure mode is not an error — it is a confirmation that means
# nothing, which is exactly what the check exists to prevent.
#
# Two specific risks in the current configuration:
#
#   1. The host runs TWO OpenSSH listeners (22 and the phone's 2222). If the
#      evidence were looked for in a unit that only one of them logs to, then a
#      confirmation from the phone — the documented fallback path — could never
#      succeed, and the only "fix" available at 2am would be
#      --assume-new-connection, i.e. turning the check off.
#
#   2. A peer inside the tailnet is most likely on TAILSCALE SSH, which answers
#      on port 22 before the OS sshd sees the connection and is recorded by a
#      different daemon entirely. That case must fail with an explanation, not
#      with "no evidence found", which reads as a broken update.
#
# This suite drives the real ns-maint state machine against a fake journal. It
# does not reimplement the check; it makes the machine, the record and the
# journal say the things each scenario requires, then asserts on what ns-maint
# concluded.
#
# Run directly:  bash nixos/tests/server-foundation/ssh-confirm.sh
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/harness.sh
# shellcheck disable=SC1091
. "$HERE/../lib/harness.sh"

printf '\n\033[1mserver-foundation — ns-maint new-connection confirmation\033[0m\n'

# The shared harness speaks value-first (`assert_eq WANT GOT LABEL`); this suite
# reads better label-first. The wrappers get their OWN names rather than
# shadowing the harness's: `assert_no_reboot` calls `assert_eq` internally, and a
# shadow with a different argument order would silently break every assertion
# the harness makes on our behalf.
is_eq() { assert_eq "$2" "$3" "$1"; }
isnt() { assert_ne "$2" "$3" "$1"; }
has() { assert_contains "$2" "$3" "$1"; }
hasnt() { assert_not_contains "$2" "$3" "$1"; }

# Write one line into the fake sshd journal, as `<epoch> <text>`. The fake
# journalctl (lib/harness.sh) filters by --since and renders it the way
# journald would, including the `sshd-session[NNN]:` prefix that real entries
# carry.
journal_add() {
  printf '%s\t%s\n' "$1" "$2" >>"$FAKE_SSHD_LOG"
}

accepted_line() {
  journal_add "$1" "sshd-session[999]: Accepted publickey for $NM_HOST from $2 port $3 ssh2: ED25519 SHA256:fake"
}

# The peer a given listener would report. Both are loopback here: the point of
# these tests is WHICH JOURNAL RECORD IS FOUND, not what a real peer's address
# is, and using real-looking addresses would not change a single assertion.
PEER22="127.0.0.1"
PORT22="51022"
PEER2222="127.0.0.1"
PORT2222="51023"

# ─────────────────────────────────────────────────────────────────────────────
t_start "a NEW session on port 22 after the switch confirms the transaction"
fixture_new
prepare_and_activate 300
id="$(txid)"
armed="$(rec_field activated_at)"
accepted_line "$((armed + 5))" "$PEER22" "$PORT22"
SSH_CONNECTION="$PEER22 $PORT22 127.0.0.1 22" ns_maint confirm "$id" >"$TMP/log/confirm.out" 2>&1
is_eq "the transaction is confirmed" "confirmed" "$(phase)"
has "and the evidence names sshd" "$(rec_field confirm_connection)" "sshd accepted a session"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "a NEW session on port 2222 — the phone's listener — also confirms"
fixture_new
prepare_and_activate 300
id="$(txid)"
armed="$(rec_field activated_at)"
# The SAME unit, a different local port. If the check were per-listener this is
# where it would break, and the available "fix" would be to stop checking.
accepted_line "$((armed + 5))" "$PEER2222" "$PORT2222"
SSH_CONNECTION="$PEER2222 $PORT2222 127.0.0.1 2222" ns_maint confirm "$id" >"$TMP/log/confirm.out" 2>&1
is_eq "the transaction is confirmed" "confirmed" "$(phase)"
has "evidence is sshd's, from the same unit as port 22" "$(rec_field confirm_connection)" "sshd accepted a session"
# Prove the record it read is the shared one, not a listener-specific unit.
has "it asked the sshd unit" "$(fake_calls)" "journalctl -u sshd.service"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "a session accepted BEFORE the switch does not confirm anything"
fixture_new
prepare_and_activate 300
id="$(txid)"
armed="$(rec_field activated_at)"
# The pre-existing socket's session. Same peer, same unit, wrong timestamp — the
# exact shape that makes "I am still connected" worthless as evidence.
accepted_line "$((armed - 30))" "$PEER22" "$PORT22"
out="$(SSH_CONNECTION="$PEER22 $PORT22 127.0.0.1 22" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
isnt "a stale session must not confirm" 0 "$rc"
is_eq "the transaction is untouched" "awaiting-confirm" "$(phase)"
has "and it says why" "$out" "no NEW sshd session"
has "including what to do about it" "$out" "Open a second connection"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "a session from a DIFFERENT peer does not confirm this one"
fixture_new
prepare_and_activate 300
id="$(txid)"
armed="$(rec_field activated_at)"
# Somebody else's session, from the same unit, after the switch. The check must
# be about this peer, not about "did anybody connect".
accepted_line "$((armed + 5))" "100.99.99.99" "40000"
out="$(SSH_CONNECTION="$PEER22 $PORT22 127.0.0.1 22" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
isnt "another peer's session is not evidence for this one" 0 "$rc"
is_eq "the transaction is untouched" "awaiting-confirm" "$(phase)"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "the same peer on a different source port does not confirm"
fixture_new
prepare_and_activate 300
id="$(txid)"
armed="$(rec_field activated_at)"
accepted_line "$((armed + 5))" "$PEER22" "$((PORT22 + 1))"
out="$(SSH_CONNECTION="$PEER22 $PORT22 127.0.0.1 22" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
isnt "a different source port is a different connection" 0 "$rc"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "a tailnet peer gets the Tailscale SSH explanation, not a dead end"
fixture_new
prepare_and_activate 300
id="$(txid)"
armed="$(rec_field activated_at)"
# No sshd record at all, and the peer is inside the tailnet CGNAT range — i.e.
# the operator is on Tailscale SSH, where the acceptance is recorded by
# tailscaled and this check will never find it.
out="$(SSH_CONNECTION="100.71.67.69 54321 100.71.67.69 22" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
isnt "still refused — the check is not loosened" 0 "$rc"
is_eq "the transaction is untouched" "awaiting-confirm" "$(phase)"
has "it explains where Tailscale SSH records acceptance" "$out" "recorded by"
has "it names the unit that will have it" "$out" "tailscaled"
has "it says which ports to use instead" "$out" "-p 22"
has "it names the phone's listener" "$out" "2222"
hasnt "and it does not pretend the evidence was found" "$out" "sshd accepted a session"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "a non-tailnet peer gets the plain explanation"
fixture_new
prepare_and_activate 300
id="$(txid)"
out="$(SSH_CONNECTION="203.0.113.7 40000 203.0.113.7 22" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
isnt "still refused" 0 "$rc"
hasnt "no Tailscale SSH paragraph for a public address" "$out" "is a tailnet address"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "a LAN address is not mistaken for a tailnet address"
fixture_new
prepare_and_activate 300
id="$(txid)"
out="$(SSH_CONNECTION="192.168.1.42 55555 192.168.1.42 22" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
hasnt "192.168.1.x is not in 100.64.0.0/10" "$out" "is a tailnet address"
# …and 100.63/100.128, the neighbours of the range, are not either.
out="$(SSH_CONNECTION="100.63.0.1 55555 100.63.0.1 22" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
hasnt "100.63 is below the range" "$out" "is a tailnet address"
out="$(SSH_CONNECTION="100.128.0.1 55555 100.128.0.1 22" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
hasnt "100.128 is above the range" "$out" "is a tailnet address"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "no SSH_CONNECTION at all is still refused, console or not"
fixture_new
prepare_and_activate 300
id="$(txid)"
out="$(SSH_CONNECTION="" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
isnt "with nothing to verify, refuse" 0 "$rc"
has "and it says what the console operator can do" "$out" "--assume-new-connection"
t_done
fixture_free

# ─────────────────────────────────────────────────────────────────────────────
t_start "confirmation never reboots, on any of these paths"
fixture_new
prepare_and_activate 300
id="$(txid)"
armed="$(rec_field activated_at)"
accepted_line "$((armed + 5))" "$PEER2222" "$PORT2222"
SSH_CONNECTION="$PEER2222 $PORT2222 127.0.0.1 2222" ns_maint confirm "$id" >/dev/null 2>&1
assert_no_reboot
t_done
fixture_free

for negative in during-apply port-prefix regex-peer; do
  t_start "reject misleading SSH evidence: $negative"
  fixture_new
  prepare_and_activate 300
  id="$(txid)"
  completed="$(rec_field activated_at)"
  case "$negative" in
    during-apply) accepted_line "$completed" "$PEER22" "$PORT22" ;;
    port-prefix) accepted_line "$((completed + 5))" "$PEER22" "${PORT22}9" ;;
    regex-peer) accepted_line "$((completed + 5))" "127x0x0x1" "$PORT22" ;;
  esac
  out="$(SSH_CONNECTION="$PEER22 $PORT22 127.0.0.1 22" ns_maint confirm "$id" 2>&1)" && rc=0 || rc=$?
  isnt "misleading evidence is refused" 0 "$rc"
  is_eq "transaction remains pending" awaiting-confirm "$(phase)"
  assert_no_reboot
  t_done
  fixture_free
done

# ─────────────────────────────────────────────────────────────────────────────
if [[ "$TESTS_FAILED" -ne 0 ]]; then
  printf '\n\033[31mssh-confirm: %d assertion(s) failed\033[0m\n' "$TESTS_FAILED"
  exit 1
fi
printf '\n\033[32mssh-confirm: all %d checks passed\033[0m\n' "$TESTS_RUN"
