#!/usr/bin/env bash
# nixos/tests/agent-operations/daemon-roots.sh
#
# Does the running daemon's closure survive a collection, and does the pin
# survive CONFIRMATION and GC?
#
# Everything runs against a disposable gcroots directory and a fake `nix-store`
# that models the only three behaviours the script depends on: --add-root
# (creating an indirect root symlink relative to the invocation directory),
# --query --requisites, and --gc --dry-run. It runs no real collection, touches
# no real store path, and never restarts or stops anything.
#
# The scenario that matters, and the one PR #4's own roots do not cover: herdr
# resolves its binary through /etc/profiles/per-user/%u, so the store path the
# LIVE server is executing is referenced by no generation, no current-system and
# no booted closure. A collection is therefore entitled to delete it.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"
SUITE_NAME="daemon-roots"

fixture_new

GCROOTS="$TMP/gcroots"
mkdir -p "$GCROOTS"
export NM_GCROOTS="$GCROOTS"
export NS_OPS_TEST_MODE=1

# ── the fake store ──────────────────────────────────────────────────────────
#
# A tiny model of a Nix store: a directory of paths, a closure map, and a
# collector that deletes anything not reachable from a root or a generation.
FAKE_STORE="$TMP/store"
mkdir -p "$FAKE_STORE"
# The script validates that the executable really is a store path; a fixture
# cannot write to /nix/store, so the store root is a seam (see the script).
export NS_OPS_STORE_ROOT="$FAKE_STORE"
FAKE_CLOSURE="$TMP/closure"
FAKE_GENERATIONS="$TMP/generations"

add_path() {
	local name="$1"
	mkdir -p "$FAKE_STORE/$name/bin"
	: >"$FAKE_STORE/$name/bin/herdr"
	printf '%s' "$FAKE_STORE/$name"
}

add_edge() { printf '%s -> %s\n' "$1" "$2" >>"$FAKE_CLOSURE"; }

reachable() {
	# Basename the start path: the closure map is keyed by store path NAME, and
	# the delete loop compares basenames. Mixing the two makes every path look
	# unreachable and the collector deletes the pin's target — which is exactly
	# the bug this fake exists to be able to detect.
	local start p
	start="$(basename "$1")"
	local -A seen=()
	local -a queue=("$start")
	while ((${#queue[@]} > 0)); do
		p="${queue[0]}"
		queue=("${queue[@]:1}")
		[[ -n "${seen[$p]:-}" ]] && continue
		seen["$p"]=1
		while IFS=' ' read -r _ _ dep; do
			[[ -n "$dep" ]] && queue+=("$dep")
		done < <(grep "^$p " "$FAKE_CLOSURE" 2>/dev/null || true)
	done
	printf '%s\n' "${!seen[@]}"
}

collect() {
	# Delete every path not reachable from a generation or from a root. This is
	# the property under test: a pinned closure must not be collectable.
	local -A keep=()
	local g
	while IFS= read -r g; do
		[[ -n "$g" ]] || continue
		while IFS= read -r p; do
			[[ -n "$p" ]] && keep["$p"]=1
		done < <(reachable "$g")
	done <"$FAKE_GENERATIONS"
	local root target
	shopt -s nullglob
	for root in "$GCROOTS"/*; do
		[[ -L "$root" ]] || continue
		target="$(readlink -f "$root" 2>/dev/null || true)"
		while IFS= read -r p; do
			[[ -n "$p" ]] && keep["$p"]=1
		done < <(reachable "$target")
	done
	shopt -u nullglob
	local deleted=0
	for p in "$FAKE_STORE"/*; do
		[[ -d "$p" ]] || continue
		if [[ -z "${keep[$(basename "$p")]:-}" ]]; then
			rm -rf -- "$p"
			deleted=$((deleted + 1))
		fi
	done
	printf '%s\n' "$deleted"
}

# Exactly the two invocations ns-agent-daemon-roots makes, parsed positionally
# and readably. A clever argument loop here would be a second thing that has to
# be correct before the thing under test can be measured.
fake nix-store <<'FAKE'
#!/bin/bash
printf 'nix-store %s\n' "$*" >>"${TMP}/log/calls"
case "$1" in
--query)
	# --query --requisites <path>. The exit status must come from the query
	# itself: swallowing it makes a path that is NOT in the store look like a
	# successful query of an empty closure.
	"$FAKE_REACHABLE" "$3"
	exit $?
	;;
--add-root)
	# --add-root <name> --realise <path>
	ln -sfn "$4" "$2"
	printf 'gc-root %s -> %s\n' "$2" "$4" >>"${TMP}/log/calls"
	exit 0
	;;
--gc)
	dryrun=no
	for a in "$@"; do [[ "$a" == "--dry-run" ]] && dryrun=yes; done
	printf 'gc --dry-run=%s\n' "$dryrun" >>"${TMP}/log/calls"
	exit "${FAKE_GC_EXIT:-0}"
	;;
esac
exit 1
FAKE

: >"$FAKE_CLOSURE"
: >"$FAKE_GENERATIONS"
export FAKE_CLOSURE FAKE_GENERATIONS
# The closure walker, written with `fake` so it gets a HARD-CODED interpreter
# path. `#!/bin/bash` does not exist on a NixOS system and `#!/usr/bin/env bash`
# does not exist in a nix build sandbox — and a fake that cannot find its
# interpreter exits 126, which reads like a bug in the tool under test.
FAKE_REACHABLE="$TMP/bin/reachable"
fake reachable <<'FAKE'
# Model the real nix-store's behaviour for a path that is not in the store: the
# query FAILS. Without this, "already collected" could not be detected at all.
if [[ ! -e "$1" ]]; then
	printf 'error: path %s is not valid\n' "$1" >&2
	exit 1
fi
start="$(basename "$1")"
declare -A seen=()
queue=("$start")
while ((${#queue[@]} > 0)); do
	p="${queue[0]}"; queue=("${queue[@]:1}")
	[[ -n "${seen[$p]:-}" ]] && continue
	seen["$p"]=1
	while IFS=' ' read -r _ _ dep; do
		[[ -n "$dep" ]] && queue+=("$dep")
	done < <(grep "^$p " "$FAKE_CLOSURE" 2>/dev/null || true)
done
for k in "${!seen[@]}"; do printf '%s\n' "$k"; done | sort
FAKE
export FAKE_REACHABLE

# ── the store the daemon is running from ─────────────────────────────────────
EXE="$(add_path herdr-0.9.3)"
LIB="$(add_path glibc-2.39)"
LIBSSL="$(add_path openssl-3.3)"
add_edge "$(basename "$EXE")" "$(basename "$LIBSSL")"
add_edge "$(basename "$LIBSSL")" "$(basename "$LIB")"

# ── a fake /proc with one "herdr server" process ────────────────────────────
mk_proc() {
	local pid="$1" exe_path="$2"
	mkdir -p "$TMP/proc/$pid"
	printf 'herdr\n' >"$TMP/proc/$pid/comm"
	printf '%s\0server\0' "$exe_path" >"$TMP/proc/$pid/cmdline"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" >"$TMP/proc/$pid/status"
	printf '%s (herdr) S' "$pid" >"$TMP/proc/$pid/stat"
	printf ' 0%.0s' {1..18} >>"$TMP/proc/$pid/stat"
	printf ' %s\n' "$pid" >>"$TMP/proc/$pid/stat"
	# /proc/PID/exe is a symlink; readlink -f resolves it.
	ln -sfn "$exe_path" "$TMP/proc/$pid/exe"
}
mk_proc 4711 "$EXE/bin/herdr"
export PROC_ROOT="$TMP/proc"

# ── a fake systemd ──────────────────────────────────────────────────────────
fake systemctl <<'FAKE'
#!/bin/bash
if [[ "$*" == *"MainPID"* ]]; then printf '%s\n' "${FAKE_SYSTEMCTL_MAINPID:-}"; exit 0; fi
printf '%s\n' "${FAKE_SYSTEMCTL_ACTIVE:-unknown}"
FAKE

# ═══════════════════════════════════════════════════════════════════════════
_t_start "nothing pinned yet"
out="$(bash "$DAEMON_ROOTS" list 2>&1)"
assert_contains "$out" 'no ns-ops-* daemon roots are pinned' 'list says so plainly'
out="$(bash "$DAEMON_ROOTS" verify 2>&1)"
assert_contains "$out" 'nothing to verify' 'verify is a no-op, not a failure'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "pin the ACTUAL RUNNING executable, not the unit's path"
export FAKE_SYSTEMCTL_MAINPID=4711
export FAKE_SYSTEMCTL_ACTIVE=active
out="$(bash "$DAEMON_ROOTS" pin --unit herdr.service 2>&1)"
assert_contains "$out" "$EXE" 'the pin names the binary from /proc/PID/exe'
assert_file "$GCROOTS/ns-ops-herdr.service" 'a root exists in the shared gcroots dir'
assert_symlink_target "$GCROOTS/ns-ops-herdr.service" "$EXE" 'and it points at the running binary'
assert_contains "$(cat "$TMP/log/calls")" 'gc-root' 'via nix-store --add-root'

# The old ns-maint roots use a different prefix and must not be confused with
# these — the whole point is that ns-maint's roots know nothing about this daemon.
out="$(bash "$DAEMON_ROOTS" list 2>&1)"
assert_contains "$out" 'ns-ops-herdr.service' 'list shows the new root'
assert_not_contains "$out" 'ns-maint-' 'and does not pretend to be an ns-maint root'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "THE POINT: the pinned closure survives a collection"
# Nothing in this scenario is reachable from a generation. That is exactly the
# situation herdr.service creates: no generation references the store path the
# live server is executing.
printf '' >"$FAKE_GENERATIONS"
collect >/dev/null
after="$(bash "$DAEMON_ROOTS" verify 2>&1)"
rc=$?
assert_eq '0' "$rc" 'verify passes after a collection'
assert_contains "$after" 'ok   ns-ops-herdr.service' 'and the root still resolves'
assert_file "$EXE" 'the daemon binary itself was NOT collected'
assert_file "$LIBSSL" 'its dependency was not collected'
assert_file "$LIB" 'nor the dependency of the dependency'

# And the contrast: an UNPINNED daemon would have been collected.
UNPINNED="$(add_path herdr-0.10.0)"
mk_proc 4712 "$UNPINNED/bin/herdr"
collect >/dev/null
assert_no_file "$UNPINNED" 'an unpinned store path IS collectable — so the pin is doing something'
rm -rf "$TMP/proc/4712"

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the pin survives CONFIRMATION and a GC, independently of any transaction"
# ns-maint's own roots were released when its transaction was confirmed. There
# is no transaction record here at all, which is the point: a daemon pin must not
# depend on one existing.
mkdir -p "$TMP/nonexistent-maint-dir"
printf 'phase=idle\ntxid=\n' >"$TMP/record.env"

printf '%s\n' "$(basename "$EXE")" >"$FAKE_GENERATIONS"
bash "$DAEMON_ROOTS" pin --unit herdr.service >/dev/null 2>&1
# Simulate a confirmation: every ns-maint-* root is removed.
touch "$GCROOTS/ns-maint-some-transaction"
assert_file "$GCROOTS/ns-maint-some-transaction" 'a transaction root exists to be released'
rm -f "$GCROOTS/ns-maint-some-transaction"
collect >/dev/null
out="$(bash "$DAEMON_ROOTS" verify 2>&1)"
assert_contains "$out" 'ok   ns-ops-herdr.service' 'the daemon pin is untouched by the confirmation'
assert_file "$EXE" 'and the binary survives the following GC'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "gc-check: the collector's own dry run, then verify"
out="$(bash "$DAEMON_ROOTS" gc-check 2>&1)"
assert_contains "$out" 'survived the collector' 'gc-check reports survival'
assert_contains "$out" 'independent of any transaction' 'and says why that is guaranteed'
assert_contains "$(cat "$TMP/log/calls")" 'gc --dry-run=yes' 'it really asked for a dry run, not a real collection'
out="$(FAKE_GC_EXIT=1 bash "$DAEMON_ROOTS" gc-check 2>&1)"
assert_eq '1' "$?" 'failed collector dry run cannot verify retention'
assert_contains "$out" 'retention is not verified' 'failed collector is reported'
assert_not_contains "$out" 'survived the collector' 'no survival claim without a successful collector'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a manually started daemon is still pinned"
# MainPID 0 is what systemd reports when the server was launched from a terminal
# and the unit owns nothing. Refusing to pin here would leave the most at-risk
# daemon unprotected.
export FAKE_SYSTEMCTL_MAINPID=0
# A status CLI and a foreign owner's daemon must not win the /proc scan.
CLI="$(add_path herdr-new-cli)"
mk_proc 100 "$CLI/bin/herdr"
printf '%s\0status\0server\0' "$CLI/bin/herdr" >"$TMP/proc/100/cmdline"
mk_proc 101 "$CLI/bin/herdr"
printf 'Uid:\t98765\t98765\t98765\t98765\n' >"$TMP/proc/101/status"
rm -f "$GCROOTS"/ns-ops-*
out="$(bash "$DAEMON_ROOTS" pin --unit herdr.service 2>&1)"
assert_contains "$out" 'pid 4711' 'the daemon is found through /proc instead'
assert_file "$GCROOTS/ns-ops-herdr.service" 'and it is pinned'
assert_symlink_target "$GCROOTS/ns-ops-herdr.service" "$EXE" 'a newer CLI or foreign user cannot replace the daemon pin'
export FAKE_SYSTEMCTL_MAINPID=100
out="$(bash "$DAEMON_ROOTS" pin --unit herdr.service 2>&1)"
rc=$?
assert_eq 1 "$rc" 'a status client MainPID is explicitly refused'
assert_symlink_target "$GCROOTS/ns-ops-herdr.service" "$EXE" 'refusal preserves the old root'
export FAKE_SYSTEMCTL_MAINPID=4711
out="$(bash "$DAEMON_ROOTS" pin --unit herdr.service --unit other.service 2>&1)"
assert_file "$GCROOTS/ns-ops-other.service" 'every configured unit is pinned, not only the first'
rm -rf "$TMP/proc/100" "$TMP/proc/101"

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a non-store executable is reported honestly, not given a fake pin"
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/herdr"
chmod +x "$TMP/bin/herdr"
mk_proc 4713 "$TMP/bin/herdr"
export FAKE_SYSTEMCTL_MAINPID=4713
rm -f "$GCROOTS"/ns-ops-*
out="$(bash "$DAEMON_ROOTS" pin --unit herdr.service 2>&1)"
assert_contains "$out" 'not a Nix store path' 'it says there is no closure to pin'
assert_contains "$out" 'not by a GC root' 'and does not pretend otherwise'
assert_no_file "$GCROOTS/ns-ops-herdr.service" 'and creates no root'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a daemon whose binary was already collected is reported, not ignored"
rm -rf "$EXE"
export FAKE_SYSTEMCTL_MAINPID=4711
out="$(bash "$DAEMON_ROOTS" pin --unit herdr.service 2>&1)"
assert_contains "$out" 'still in the store' 'the query failing is named'
assert_contains "$out" 'this script exists to make impossible' 'and says what it means'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a missing root is a visible failure"
rm -f "$GCROOTS"/ns-ops-*
printf '%s\n' "$(basename "$EXE")" >"$FAKE_GENERATIONS"
out="$(bash "$DAEMON_ROOTS" verify 2>&1)"
rc=$?
assert_eq '0' "$rc" 'verify with no roots is not an error'

printf '%s\n' "$(basename "$EXE")" >>"$FAKE_GENERATIONS"
ln -sfn "$FAKE_STORE/does-not-exist" "$GCROOTS/ns-ops-dangling"
out="$(bash "$DAEMON_ROOTS" verify 2>&1)"
rc=$?
assert_eq '1' "$rc" 'a dangling root makes verify exit 1'
assert_contains "$out" 'DANGLING' 'and says DANGLING'

out="$(bash "$DAEMON_ROOTS" list 2>&1)"
assert_contains "$out" 'ns-ops-dangling' 'list still names the broken root rather than hiding it'
assert_not_contains "$out" 'no ns-ops' 'and does not claim there are none'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "release removes exactly one root"
rm -f "$GCROOTS"/ns-ops-*
STILL_THERE="$(add_path still-here)"
ln -sfn "$STILL_THERE" "$GCROOTS/ns-ops-a"
ln -sfn "$STILL_THERE" "$GCROOTS/ns-ops-b"
out="$(bash "$DAEMON_ROOTS" release a 2>&1)"
assert_no_file "$GCROOTS/ns-ops-a" 'the named root is gone'
assert_file "$GCROOTS/ns-ops-b" 'the other root is untouched'
out="$(bash "$DAEMON_ROOTS" release nonexistent 2>&1)"
assert_contains "$out" 'no such root' 'releasing an unknown root says so'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "no daemon running is a no-op, not a failure"
rm -rf "$TMP/proc"/[0-9]*
export FAKE_SYSTEMCTL_MAINPID=0
out="$(bash "$DAEMON_ROOTS" pin --unit herdr.service 2>&1)"
rc=$?
assert_eq '0' "$rc" 'pinning with no daemon exits 0'
assert_contains "$out" 'Nothing to pin' 'and says why'

assert_no_reboot "$TMP/reboots"
summary