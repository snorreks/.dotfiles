#!/usr/bin/env bash
# nixos/tests/disk-cleanup-safety.sh — the cleanup rules that must not regress.
#
# The old disk-cleanup.sh did four destructive things by default or under
# --deep, and this suite exists to prove it no longer does:
#
#   1. Nix store collection with -d in the DEFAULT sweep (deletes generations).
#   2. `podman volume prune` under --deep (deletes stopped services' data).
#   3. `find ~/.herdr/worktrees -mtime +7 -exec rm -rf` (deletes uncommitted work).
#   4. Age-based /tmp deletion at 3 days in the DEFAULT sweep.
#
# Everything runs against a disposable HOME with real git worktrees in it and
# fake podman/journalctl/sudo on PATH. Nothing here touches the real home
# directory, the real store, or the real container runtime: the script under
# test is invoked with HOME overridden and the tool names it shells out to
# resolved from the fixture's bin directory.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/harness.sh"

DISK_CLEANUP="${DISK_CLEANUP:-$HERE/../config/home/scripts/scripts/disk-cleanup.sh}"

printf '\n\033[1mdisk-cleanup safety — nothing destructive by default\033[0m\n'

# ── a disposable HOME, with real git worktrees in it ────────────────────────
cleanup_home() {
  HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dc-test.XXXXXX")"
  export HOME="$HOME_DIR"
  export FAKE_BIN="$HOME_DIR/bin"
  mkdir -p "$HOME/.herdr/worktrees" "$HOME/.cache/.bun/install/cache" \
    "$HOME/.local/share/Trash/files" "$HOME/Downloads/tmp" "$FAKE_BIN"
  # Fill the bun cache so a clear is observable if one happens. The path matches
  # the first entry of CACHE_DIRS in disk-cleanup.sh exactly.
  for i in 1 2 3; do
    echo "cached-object-$i" >"$HOME/.cache/.bun/install/cache/obj-$i"
  done
  PATH="$FAKE_BIN:$PATH"
  export PATH
  CALLS="$HOME_DIR/calls"
  : >"$CALLS"

  # Every external command the script uses is replaced by an absolute-path fake.
  # Absolute paths and an explicit dispatcher are the point: a PATH-based fake
  # for `sudo` that then execs `nix-collect-garbage` can fall through to the REAL
  # binary, and the real one deletes from the real store. Nothing in this suite
  # is allowed to reach a real tool.
  cat >"$FAKE_BIN/_dispatch" <<'DISPATCH'
#!/usr/bin/env bash
# $0 is <bin>/_dispatch; $1 is the tool, the rest its arguments.
tool="$1"
shift
printf '%s %s\n' "$tool" "$*" >>"${DISPATCH_CALLS}"
case "$tool" in
sudo)
  # `sudo -n true` is the script's passwordless probe; everything after sudo's own
  # flags is the command to run — through this same dispatcher.
  while [[ $# -gt 0 && "$1" == -* ]]; do shift; done
  [ $# -gt 0 ] || exit 0
  exec "$DISPATCH_BIN/_dispatch" "$@"
  ;;
podman)
  case "$*" in
  *"volume ls"*) printf 'abandoned-vol\n' ;;
  *"system df"*) printf 'Images  10  5  5\n' ;;
  esac
  exit 0
  ;;
fuser | lsof)
  # ${DISPATCH_BUSY:+} is set by the "busy cache" test to make every check busy.
  if [[ -n "${DISPATCH_BUSY:-}" && "$*" == *"bun"* ]]; then exit 0; fi
  exit 1
  ;;
df) printf 'Filesystem Size Used Avail Use%% Mounted on\n/dev/fake 1G 0 1G 0%% /\n'; exit 0 ;;
du) printf '1.0G\t%s\n' "${*: -1}"; exit 0 ;;
*) exit 0 ;;
esac
DISPATCH
  chmod +x "$FAKE_BIN/_dispatch"
  # Absolute interpreter path; /usr/bin/env does not exist in a nix build sandbox.
  local shebang
  shebang="#!$(command -v bash)"
  for tool in podman sudo journalctl nix-collect-garbage pnpm gio herdr fuser lsof du df; do
    printf '#!/usr/bin/env bash\nDISPATCH_BIN=%q DISPATCH_CALLS=%q exec %q/_dispatch %q "$@"\n' \
      "$FAKE_BIN" "$CALLS" "$FAKE_BIN" "$tool" >"$FAKE_BIN/$tool"
    chmod +x "$FAKE_BIN/$tool"
  done
  local f
  for f in "$FAKE_BIN"/*; do
    sed -i "1s|^#!.*|$shebang|" "$f"
  done
  # git is deliberately NOT faked: the worktree tests need REAL git worktrees,
  # because the property under test is `git status --porcelain` being empty, and
  # a stubbed git would make that meaningless.
  PATH="$FAKE_BIN:$PATH"
  export PATH
}

# make_worktree NAME — a real git worktree registered under ~/.herdr/worktrees.
# `dirty` leaves an unstaged modification, `untracked` leaves an untracked file,
# and `clean` leaves it genuinely empty. Age is set by touch -d.
make_worktree() {
  local name="$1" kind="$2" age="${3:-30}"
  local origin="$HOME/.herdr/worktrees/.origin-$name"
  local wt="$HOME/.herdr/worktrees/$name"
  mkdir -p "$origin"
  git -C "$origin" init -q -b main >/dev/null 2>&1
  git -C "$origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  # `git worktree add --detach`: checking out a branch that the origin already
  # has checked out is refused, and what these tests care about is the STATE of
  # the worktree (clean / dirty / untracked), not which branch it is on.
  git -C "$origin" worktree add -q --detach "$wt" HEAD >/dev/null 2>&1
  case "$kind" in
  dirty) echo "uncommitted" >"$wt/file.txt" ;;
  untracked) echo "new" >"$wt/untracked.txt" ;;
  esac
  touch -d "$age days ago" "$wt"
  # The script keys its decision on `git status --porcelain` being empty. If the
  # fixture did not actually produce the state it claims, the test would be
  # asserting nothing, so the fixture checks itself first.
  local status
  status="$(git -C "$wt" status --porcelain 2>/dev/null || true)"
  case "$kind" in
  dirty | untracked)
    [[ -n "$status" ]] || {
      printf 'make_worktree: %s should be %s but git reports it clean\n' "$name" "$kind" >&2
      return 1
    }
    ;;
  clean)
    [[ -z "$status" ]] || {
      printf 'make_worktree: %s should be clean but git reports: %s\n' "$name" "$status" >&2
      return 1
    }
    ;;
  esac
  printf '%s' "$wt"
}

wt_count() { find "$HOME/.herdr/worktrees" -mindepth 1 -maxdepth 1 -type d -name '[!.]*' 2>/dev/null | wc -l | tr -d ' '; }

calls_of() { local n; n="$(grep -c "^$1 " "$CALLS" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }
calls_grep() { grep "^$1 " "$CALLS" 2>/dev/null || true; }

# run_cleanup ARGS... — invoke the script from the disposable HOME rather than
# from this repository.
#
# Not cosmetic: `git worktree remove <path>` only works when run inside the
# repository that owns the worktree. Invoked from the dotfiles checkout it would
# try to remove a worktree of THIS repository, fail, and leave the test asserting
# on a removal that never happened.
run_cleanup() {
  (cd "$HOME_DIR" && bash "$DISK_CLEANUP" "$@")
}

# ─────────────────────────────────────────────────────────────────────────────
t_start "the default sweep does not collect the Nix store"
cleanup_home
out="$(run_cleanup --dry-run 2>&1)"
assert_eq 0 "$(calls_of nix-collect-garbage)" "nix-collect-garbage is never invoked by default"
assert_contains "$out" "not run. Collection is opt-in" "and the reason is printed"
assert_contains "$out" "runs nix-collect-garbage without -d" "and states plainly that -d is not used"
# And the default sweep still does something useful.
assert_contains "$out" "User caches" "the re-downloadable caches are still swept"
t_done
fixture_free
rm -rf "$HOME_DIR"

# ─────────────────────────────────────────────────────────────────────────────
t_start "--gc collects but never passes -d"
cleanup_home
# A dry run must not collect at all — that is the point of --dry-run.
run_cleanup --gc --dry-run >/dev/null 2>&1
assert_eq 0 "$(calls_of nix-collect-garbage)" "a --gc --dry-run still collects nothing"
run_cleanup --gc --yes >/dev/null 2>&1
assert_eq 1 "$(calls_of nix-collect-garbage)" "a real --gc run collects exactly once"
assert_not_contains "$(calls_grep nix-collect-garbage)" " -d" "without -d"
assert_not_contains "$(calls_grep nix-collect-garbage)" "--delete" "or --delete"
t_done
fixture_free
rm -rf "$HOME_DIR"

# ─────────────────────────────────────────────────────────────────────────────
t_start "--deep never prunes container volumes"
cleanup_home
out="$(run_cleanup --deep --yes 2>&1)"
assert_contains "$out" "REPORTED, NOT REMOVED" "unused volumes are reported"
assert_contains "$out" "abandoned-vol" "by name"
assert_contains "$out" "removed nothing" "and it says it removed nothing"
assert_not_contains "$(calls_grep podman)" "volume prune" "no volume prune is issued at all"
assert_contains "$(calls_grep podman)" "image prune -a" "deep mode still drops unused images"
t_done
fixture_free
rm -rf "$HOME_DIR"

# ─────────────────────────────────────────────────────────────────────────────
t_start "the default sweep leaves /tmp alone and says how many entries exist"
cleanup_home
out="$(run_cleanup --dry-run 2>&1)"
assert_contains "$out" "stale /tmp entries" "/tmp is reported"
assert_contains "$out" "pass --tmp to act" "and removing them is a separate, explicit opt-in"
t_done
fixture_free
rm -rf "$HOME_DIR"

# ─────────────────────────────────────────────────────────────────────────────
t_start "a worktree with uncommitted changes is never removed"
cleanup_home
dirty="$(make_worktree dirty-wt dirty 30)"
out="$(run_cleanup --prune-worktrees --dry-run 2>&1)"
assert_contains "$out" "SKIPPED (uncommitted or untracked work present)" "the dirty worktree is skipped, with the reason"
assert_contains "$out" "$dirty" "and named"
assert_file "$dirty/file.txt" "its uncommitted file is untouched"
t_done
fixture_free
rm -rf "$HOME_DIR"

# ─────────────────────────────────────────────────────────────────────────────
t_start "a worktree with untracked files is never removed"
cleanup_home
untracked="$(make_worktree untracked-wt untracked 30)"
out="$(run_cleanup --prune-worktrees --dry-run 2>&1)"
assert_contains "$out" "SKIPPED (uncommitted or untracked work present)" "the untracked-only worktree is skipped"
assert_file "$untracked/untracked.txt" "its untracked file is untouched"
t_done
fixture_free
rm -rf "$HOME_DIR"

# ─────────────────────────────────────────────────────────────────────────────
t_start "a young worktree is skipped even when it is clean"
cleanup_home
young="$(make_worktree young-wt clean 1)"
out="$(run_cleanup --prune-worktrees --dry-run 2>&1)"
assert_contains "$out" "SKIPPED (younger than 7d)" "age alone is never sufficient, but age is still checked"
assert_contains "$out" "$young" "and the young one is named"
t_done
fixture_free
rm -rf "$HOME_DIR"

# ─────────────────────────────────────────────────────────────────────────────
t_start "only a clean, old, unowned worktree is a removal candidate"
cleanup_home
abandoned="$(make_worktree abandoned-wt clean 30)"
out="$(run_cleanup --prune-worktrees --dry-run 2>&1)"
assert_contains "$out" "[dry-run] git -C " "the dry run names the command it would run"
assert_contains "$out" "worktree remove $abandoned" "for the abandoned worktree specifically"
assert_file "$abandoned" "and a dry run still does not remove it"

# Now for real.
run_cleanup --prune-worktrees --yes >"$HOME_DIR/real.out" 2>&1
assert_contains "$(cat "$HOME_DIR/real.out")" "removed worktree $abandoned" "and with --yes it is removed"
assert_no_file "$abandoned" "the directory is gone"
t_done
fixture_free
rm -rf "$HOME_DIR"

# ─────────────────────────────────────────────────────────────────────────────
t_start "worktrees are reported and never removed without the opt-in"
cleanup_home
dirty="$(make_worktree dirty-wt dirty 30)"
out="$(run_cleanup --deep --dry-run 2>&1)"
assert_contains "$out" "not deleted. Cleaning one means you already decided it was junk" "the default says deletion is a human decision"
assert_contains "$out" "1 with uncommitted or untracked work" "and reports how many worktrees carry work"
assert_not_contains "$out" "[dry-run] git worktree remove" "with no removal command at all"
assert_file "$dirty/file.txt" "the dirty worktree survives a deep sweep"
t_done
fixture_free
rm -rf "$HOME_DIR"

# ─────────────────────────────────────────────────────────────────────────────
t_start "a cache a running process holds open is skipped, not cleared"
cleanup_home
# Make the dispatcher report the bun cache as held by a running process, which
# is the whole point: a cache an agent is using is not reclaimable at any age.
DISPATCH_BUSY=1
export DISPATCH_BUSY
out="$(run_cleanup --dry-run 2>&1)"
assert_contains "$out" "SKIPPED (in use by a running process)" "the busy cache is skipped"
assert_contains "$out" ".bun/install/cache" "and named"
assert_not_contains "$out" "[dry-run] clear $HOME/.cache/.bun/install/cache" "and not scheduled for clearing"
unset DISPATCH_BUSY
t_done
fixture_free
rm -rf "$HOME_DIR"

# ─────────────────────────────────────────────────────────────────────────────
t_start "the default sweep is safe to run unattended: nothing is deleted without consent"
cleanup_home
# Without --yes and with a destructive flag, it must stop and ask.
out="$(run_cleanup --deep --tmp --gc --prune-worktrees </dev/null 2>&1)" && rc=0 || rc=$?
assert_ne 0 "$rc" "a destructive sweep with no --yes aborts"
assert_contains "$out" "aborted" "after saying it aborted"
assert_eq 0 "$(calls_of nix-collect-garbage)" "and having collected nothing"
t_done
fixture_free
rm -rf "$HOME_DIR"

# Exercise the deletion entry points against one disposable cache/tmp tree.
# Load the production helpers without executing the machine-wide sweep.
# Functions below are called by the sourced production helpers.
# SC2329 as well as the older codes: these fakes are never invoked by name from
# this file — they exist to be FOUND on PATH by the sourced production script,
# which is the entire mechanism. A newer shellcheck flags the definition itself.
# shellcheck disable=SC2317,SC2034,SC2329
check_busy_tree() (
  set --
  # shellcheck disable=SC1090
  . <(sed '/^# confirmation$/,$d' "$DISK_CLEANUP")
  have() {
    case "$1" in
    lsof) [[ "$CHECKER" == lsof ]] ;;
    fuser) [[ "$CHECKER" == lsof || "$CHECKER" == fuser ]] ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }
  lsof() {
    printf 'lsof %s\n' "$*" >>"$CALLS"
    [[ "$*" == "+D $BUSY_ROOT" && "$BUSY" == 1 ]]
  }
  fuser() {
    printf 'fuser %s\n' "$*" >>"$CALLS"
    # Only the nested file is open: checking the root inode must not suffice.
    [[ "${*: -1}" == "$BUSY_FILE" && "$BUSY" == 1 ]]
  }
  find() {
    # Restrict prune_tmp's top-level discovery to our disposable directory.
    if [[ "$1" == /tmp ]]; then
      shift
      command find "$HOME_DIR/tmp" "$@"
    else
      command find "$@"
    fi
  }
  clear_dir "$BUSY_ROOT"
  touch -d '30 days ago' "$BUSY_ROOT"
  DO_TMP=1
  prune_tmp
)

for CHECKER in lsof fuser neither; do
  for BUSY in 1 0; do
    t_start "nested cache and tmp use: checker=$CHECKER busy=$BUSY"
    cleanup_home
    mkdir -p "$HOME_DIR/tmp/stale/nested"
    BUSY_ROOT="$HOME_DIR/tmp/stale"
    BUSY_FILE="$BUSY_ROOT/nested/file with spaces"$'\n''and a newline'
    echo keep >"$BUSY_FILE"
    touch -d '30 days ago' "$BUSY_ROOT"
    out="$(check_busy_tree 2>&1)"
    if [[ "$BUSY" == 1 || "$CHECKER" == neither ]]; then
      assert_file "$BUSY_FILE" "both clear_dir and prune_tmp preserve the nested file"
      assert_contains "$out" "SKIPPED" "deletion is refused visibly"
    else
      assert_no_file "$BUSY_ROOT" "an idle candidate is removed when a checker is available"
    fi
    if [[ "$CHECKER" == lsof ]]; then
      assert_eq 0 "$(calls_of fuser)" "lsof takes precedence over fuser"
    fi
    t_done
    rm -rf "$HOME_DIR"
  done
done

suite_summary "disk-cleanup safety"