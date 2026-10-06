#!/usr/bin/env bash
# nixos/tests/update-dotfiles-scope.sh
#
# What update_dotfiles.fish is and is not allowed to do.
#
# The function this replaces ran a recursive root chown, `git add -A`, and an
# unconditional `git push origin master` — so invoking it to fix a file
# permission could publish an unrelated secret to a public repository. These
# tests drive the real function against a THROWAWAY git repository created in
# a temp directory. Nothing here touches ~/.dotfiles, and no push is ever
# performed: `push` and `pr` are tested for their refusal behaviour on master,
# and for their refusal to run without a configured remote.
#
# Set NM_SKIP_FISH=1 if fish is unavailable; the runner treats that as a skip
# that must be declared, not a silent pass.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FUNC="$ROOT/config/home/fish/functions/update_dotfiles.fish"

# shellcheck source=lib/harness.sh
source "$HERE/lib/harness.sh"

printf '\033[1mupdate_dotfiles scope — no blanket chown, add-all, or master push\033[0m\n'

# ── fixture ─────────────────────────────────────────────────────────────────
# A disposable repo per test, so no test can see another's staging area.
make_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q -b master
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "Test"
  git -C "$dir" config commit.gpgsign false
  echo "original" >"$dir/tracked.txt"
  echo "original" >"$dir/other.txt"
  git -C "$dir" add tracked.txt other.txt
  git -C "$dir" commit -qm "initial"
  FIXTURE_REPOS+=("$dir")
}

FIXTURE_REPOS=()
cleanup() {
  local d
  for d in ${FIXTURE_REPOS[@]+"${FIXTURE_REPOS[@]}"}; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
  # Explicitly succeed. This runs from an EXIT trap, and a trap whose last
  # command is a failing test turns the whole script's exit status into that
  # failure — so a suite that had correctly decided to skip was reporting
  # itself as failed.
  return 0
}
trap cleanup EXIT

# Run the function against a fixture repo, capturing output and exit status.
#
# Never runs `push`/`pr` against a real remote — see individual tests.
#
# The XDG_CONFIG_HOME override is load-bearing, not hygiene. fish autoloads
# `update_dotfiles.fish` from `$XDG_CONFIG_HOME/fish/functions`, so if the
# `source` below ever fails to find the repo's copy, fish silently runs
# whatever version is INSTALLED instead. The installed copy is the old one,
# which does `sudo chown -R` and `git push origin master` — so a broken path
# in this test file would chown and push the operator's real dotfiles
# repository. Pointing XDG_CONFIG_HOME at an empty directory means there is no
# installed copy to fall back to: a bad path becomes a hard failure instead.
run_ud() {
  local dir="$1"
  shift
  # Refuse to drive anything that is not a fixture. The function falls back to
  # `$HOME/.dotfiles` when NM_DOTFILES_REPO is unset, and driving THAT would
  # create branches and stage files in the operator's real repository. This
  # check is the last line of defence; the pre-flight above catches the source
  # path, and this catches the target path.
  if [[ -z "$dir" || "$dir" == "$HOME/.dotfiles" || ! -e "$dir/.git" ]] ||
    ! printf '%s\n' "${FIXTURE_REPOS[@]}" | grep -Fxq "$dir"; then
    echo "update-dotfiles-scope: FATAL — refusing to run against '$dir'." >&2
    echo "  run_ud must be given a throwaway fixture repository." >&2
    exit 91
  fi
  # Each argument is shell-quoted individually. Joining with "$*" would split
  # a commit message like "a scoped change" into three argv entries.
  local cmd="source '$FUNC'; or exit 90; update_dotfiles" a q
  for a in "$@"; do
    printf -v q '%q' "$a"
    cmd+=" $q"
  done
  set +e
  UD_OUT="$(XDG_CONFIG_HOME="$EMPTY_CONFIG_HOME" NM_DOTFILES_REPO="$dir" \
    fish --no-config -c "$cmd" 2>&1)"
  UD_STATUS=$?
  set -e

  # exit 90 is our "the source failed" signal. If fish fell back to an
  # installed function, `update_dotfiles` would have done something real to a
  # real repository before this check could see it — so this must also be
  # caught by the pre-flight checks below, and is asserted here as a backstop.
  if [[ "$UD_STATUS" -eq 90 ]]; then
    echo "update-dotfiles-scope: FATAL — could not source $FUNC" >&2
    echo "$UD_OUT" >&2
    exit 90
  fi
}

# The harness has no exit-status assertion, and every claim this file makes is
# about a command that must NOT have succeeded, so status is the assertion.
assert_status() {
  local want="$1" got="$2" what="$3"
  if [[ "$want" == "$got" ]]; then _ok "$what"; else _fail "$what" "expected exit [$want] got [$got]: $UD_OUT"; fi
}

if ! command -v fish >/dev/null 2>&1; then
  # Fail closed, like every other suite in this repository: a suite that did
  # not run must not be reported as one that ran. `NM_REQUIRE_ALL=0` is the
  # explicit opt-out, and is what the flake checks set for their own reasons.
  if [[ "${NM_REQUIRE_ALL:-1}" != "0" ]]; then
    echo "update-dotfiles-scope: fish not on PATH, and this run requires every" >&2
    echo "  suite to actually run. Re-run where fish is available, or set" >&2
    echo "  NM_REQUIRE_ALL=0 if a skip is expected here." >&2
    exit 1
  fi
  printf '    SKIPPED update_dotfiles scope (fish not on PATH)\n'
  exit 0
fi

if [[ "${NM_SKIP_FISH:-0}" == "1" ]]; then
  printf '    NM_SKIP_FISH=1 — skipping by request\n'
  exit 0
fi

# ── pre-flight: prove we are about to test the REPO's function ─────────────
#
# Everything below this block drives `update_dotfiles`. If we are not driving
# the copy in this repository, we are driving the installed one — and the
# installed one chowns and pushes the operator's real dotfiles repo. So these
# checks run before a single test, and abort the suite rather than proceed.

EMPTY_CONFIG_HOME="$(mktemp -d)"
# Register it with the fixture cleanup so the EXIT trap removes it. It was
# created outside make_repo, so nothing else was going to.
FIXTURE_REPOS+=("$EMPTY_CONFIG_HOME")
export EMPTY_CONFIG_HOME

# Ignore the operator's global/system git config entirely. It cannot point a
# fixture at a real remote, and it cannot supply credentials if a `push` is
# ever reached. Fixture repos set their own user.name/email.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

if [[ ! -f "$FUNC" ]]; then
  echo "update-dotfiles-scope: FATAL — $FUNC does not exist." >&2
  echo "  Refusing to run: with no repo copy, fish would autoload the" >&2
  echo "  INSTALLED update_dotfiles, which chowns and pushes ~/.dotfiles." >&2
  exit 90
fi

# The loaded definition must be this repository's. `NM_DOTFILES_REPO` is the
# first thing the rewritten function sets; the old implementation never had it.
if ! XDG_CONFIG_HOME="$EMPTY_CONFIG_HOME" fish --no-config -c "source '$FUNC'; functions update_dotfiles" 2>/dev/null |
  grep -q 'NM_DOTFILES_REPO'; then
  echo "update-dotfiles-scope: FATAL — $FUNC is not the rewritten function." >&2
  echo "  Refusing to run against the installed copy." >&2
  exit 90
fi

# No live `chown -R` command. Comment lines are stripped first: the file
# deliberately *quotes* the old `sudo chown -R sonny:users ~/.dotfiles` in its
# header to explain what it replaced, so a naive grep over the whole body would
# match the documentation of the very thing this test forbids.
if XDG_CONFIG_HOME="$EMPTY_CONFIG_HOME" fish --no-config -c "source '$FUNC'; functions update_dotfiles" 2>/dev/null |
  grep -v '^[[:space:]]*#' | grep -q 'chown[[:space:]].*-R'; then
  echo "update-dotfiles-scope: FATAL — $FUNC still runs 'chown ... -R'." >&2
  exit 90
fi

# No blanket staging or a push to master, checked the same way.
if XDG_CONFIG_HOME="$EMPTY_CONFIG_HOME" fish --no-config -c "source '$FUNC'; functions update_dotfiles" 2>/dev/null |
  grep -v '^[[:space:]]*#' | grep -qE 'add[[:space:]]+(-A|\.)|push[[:space:]].*origin[[:space:]]+master'; then
  echo "update-dotfiles-scope: FATAL — $FUNC still does a blanket add or pushes to master." >&2
  exit 90
fi

printf '    driving %s\n' "$FUNC"

# Decisive sandbox check, run before any test touches git.
#
# `update_dotfiles` defaults to $HOME/.dotfiles. If NM_DOTFILES_REPO ever stops
# reaching it, every test silently targets the operator's real repository and
# has been observed to create branches and stage files there. Pointing it at a
# path that does not exist MUST therefore fail; if it succeeds, the override
# is not visible and the suite aborts before running anything.
#
# Written as an `if` condition rather than a bare command: `set -e` is on, and
# the non-zero exit this probe EXPECTS would otherwise abort the script before
# the branch could run.
if XDG_CONFIG_HOME="$EMPTY_CONFIG_HOME" NM_DOTFILES_REPO="$EMPTY_CONFIG_HOME/does-not-exist" \
  fish --no-config -c "source '$FUNC'; or exit 90; update_dotfiles status" >/dev/null 2>&1; then
  echo "update-dotfiles-scope: FATAL — NM_DOTFILES_REPO is not reaching the" >&2
  echo "  function; it is falling back to \$HOME/.dotfiles and would drive the" >&2
  echo "  operator's real repository. Refusing to run." >&2
  exit 91
fi
printf '    sandboxed: NM_DOTFILES_REPO override reaches the function\n'

# ── stage must require explicit paths ───────────────────────────────────────

t_start "stage with no arguments"
make_repo
d="${FIXTURE_REPOS[-1]}"
echo "unrelated" >"$d/unrelated.txt"
run_ud "$d" stage
assert_status 1 "$UD_STATUS" "stage with no arguments must fail"
assert_contains "$UD_OUT" "needs at least one path" "stage with no arguments must explain itself"

# ── add-all is gone ─────────────────────────────────────────────────────────
#
# The old function ran `git add -A` unconditionally. The new one must not be
# able to reach that behaviour through any subcommand, and a bare `stage`
# must never stage an unrelated file.
make_repo
d="${FIXTURE_REPOS[-1]}"
echo "modified" >>"$d/tracked.txt"
echo "brand new" >"$d/surprise.txt"
run_ud "$d" stage tracked.txt
assert_status 0 "$UD_STATUS" "explicit stage must succeed"
assert_not_contains "$(git -C "$d" diff --cached --name-only)" "surprise.txt" \
  "an untracked file must not be staged by naming a different file"
assert_contains "$(git -C "$d" diff --cached --name-only)" "tracked.txt" \
  "the named file must be staged"
# Git pathspecs are not explicit filenames: quoted globs/magic used to stage
# synthetic private files even though every literal secret name was refused.
for path in '*.txt' ':(glob)*' ':(top)*' 'missing.txt'; do
  make_repo
  d="${FIXTURE_REPOS[-1]}"
  echo 'synthetic private data' >"$d/keys.txt"
  run_ud "$d" stage "$path"
  assert_status 1 "$UD_STATUS" "nonexistent literal '$path' must fail"
  assert_eq '' "$(git -C "$d" diff --cached --name-only)" "a pathspec must not stage any files"
done

# Literal metacharacters in a real filename remain usable.
make_repo
d="${FIXTURE_REPOS[-1]}"
echo 'safe' >"$d/literal*.txt"
echo 'synthetic private data' >"$d/keys.txt"
run_ud "$d" stage 'literal*.txt'
assert_status 0 "$UD_STATUS" "a literal wildcard filename can be staged"
assert_eq 'literal*.txt' "$(git -C "$d" diff --cached --name-only)" "only the literal filename is staged"

# Linked worktrees have a .git FILE, not a directory.
make_repo
d="${FIXTURE_REPOS[-1]}"
wt="$(mktemp -d)"
FIXTURE_REPOS+=("$wt")
git -C "$d" worktree add -q -b topic/linked "$wt"
echo 'linked edit' >>"$wt/tracked.txt"
run_ud "$wt" stage tracked.txt
assert_status 0 "$UD_STATUS" "staging in a linked worktree works"
assert_eq 'tracked.txt' "$(git -C "$wt" diff --cached --name-only)" "the linked index is staged"
assert_eq '' "$(git -C "$d" diff --cached --name-only)" "the original worktree is untouched"

# ── secret-shaped paths are refused ─────────────────────────────────────────

for path in \
  "nixos/secrets.nix" \
  "keys.txt" \
  "id_rsa" \
  "id_ed25519" \
  "id_ecdsa" \
  "some.age" \
  "nixos/config/home/files/.ssh/github_snorreks" \
  "nixos/config/home/files/.aws/credentials" \
  "nixos/local.nix"; do
  make_repo
  d="${FIXTURE_REPOS[-1]}"
  mkdir -p "$d/$(dirname "$path")"
  echo "PLAINTEXT" >"$d/$path"
  run_ud "$d" stage "$path"
  assert_status 1 "$UD_STATUS" "staging '$path' must be refused"
  assert_contains "$UD_OUT" "refusing to stage" "staging '$path' must say why"
done

# ── path normalisation: the guard must not be defeated by typing ───────────
#
# The forbidden-pattern check compared the literal string the caller typed.
# `./keys.txt` and `nixos/./secrets.nix` are the same files, and both walked
# straight past it.

for path in \
  "./keys.txt" \
  "nixos/./secrets.nix" \
  "./nixos/local.nix" \
  "nixos//secrets.nix"; do
  make_repo
  d="${FIXTURE_REPOS[-1]}"
  mkdir -p "$d/$(dirname "$path")"
  echo "PLAINTEXT" >"$d/$path"
  run_ud "$d" stage "$path"
  assert_status 1 "$UD_STATUS" "staging '$path' must be refused after normalisation"
  assert_contains "$UD_OUT" "refusing to stage" "staging '$path' must say why"
done

# ── the repository root and directories are refused ─────────────────────────
#
# `stage .` is `git add -A` with extra steps — precisely what this function
# exists to prevent.

make_repo
d="${FIXTURE_REPOS[-1]}"
run_ud "$d" stage .
assert_status 1 "$UD_STATUS" "staging '.' must be refused"
assert_contains "$UD_OUT" "repository root" "staging '.' must say why"

run_ud "$d" stage "$d"
assert_status 1 "$UD_STATUS" "staging the repo path must be refused"
assert_contains "$UD_OUT" "repository root" "staging the repo path must say why"

make_repo
d="${FIXTURE_REPOS[-1]}"
mkdir -p "$d/nixos/config"
run_ud "$d" stage nixos/config
assert_status 1 "$UD_STATUS" "staging a directory must be refused"
assert_contains "$UD_OUT" "directory" "staging a directory must say why"

# ── generated artifacts are refused ─────────────────────────────────────────

for path in \
  "pkg/__pycache__/mod.cpython-314.pyc" \
  "sub/target/debug/bin" \
  "result"; do
  make_repo
  d="${FIXTURE_REPOS[-1]}"
  mkdir -p "$d/$(dirname "$path")"
  echo "generated" >"$d/$path"
  run_ud "$d" stage "$path"
  assert_status 1 "$UD_STATUS" "staging generated path '$path' must be refused"
done

# ── commit on master is refused ────────────────────────────────────────────

make_repo
d="${FIXTURE_REPOS[-1]}"
echo "modified" >>"$d/tracked.txt"
run_ud "$d" stage tracked.txt
assert_status 0 "$UD_STATUS" "staging on master is fine"
run_ud "$d" commit "should not happen"
assert_status 1 "$UD_STATUS" "committing directly on master must be refused"
assert_contains "$UD_OUT" "refusing to work directly on master" "the master refusal must be explicit"
assert_contains "$(git -C "$d" log --oneline | head -1)" "initial" \
  "the refused commit must not have been created"

# ── commit on a topic branch works ──────────────────────────────────────────

make_repo
d="${FIXTURE_REPOS[-1]}"
echo "modified" >>"$d/tracked.txt"
run_ud "$d" branch topic/one
assert_status 0 "$UD_STATUS" "branch creation must succeed"
run_ud "$d" stage tracked.txt
assert_status 0 "$UD_STATUS" "staging must succeed"
run_ud "$d" commit "a scoped change"
assert_status 0 "$UD_STATUS" "committing on a topic branch must succeed"
assert_contains "$(git -C "$d" log --oneline | head -1)" "a scoped change" \
  "the commit must be recorded"

# ── commit with nothing staged is refused ───────────────────────────────────

make_repo
d="${FIXTURE_REPOS[-1]}"
run_ud "$d" branch topic/two
run_ud "$d" commit "nothing to do"
assert_status 1 "$UD_STATUS" "committing with an empty index must be refused"
assert_contains "$UD_OUT" "nothing staged" "the empty-index refusal must say why"

# ── push to master is refused ───────────────────────────────────────────────

make_repo
d="${FIXTURE_REPOS[-1]}"
run_ud "$d" push
assert_status 1 "$UD_STATUS" "pushing from master must be refused"
assert_contains "$UD_OUT" "refusing to work directly on master" "the master push refusal must be explicit"

# ── pr from master is refused ───────────────────────────────────────────────

make_repo
d="${FIXTURE_REPOS[-1]}"
run_ud "$d" pr "a title"
assert_status 1 "$UD_STATUS" "opening a PR from master must be refused"
assert_contains "$UD_OUT" "refusing to work directly on master" "the master PR refusal must be explicit"

# ── fixperms must not become a recursive rewrite ────────────────────────────

make_repo
d="${FIXTURE_REPOS[-1]}"

run_ud "$d" fixperms
assert_status 1 "$UD_STATUS" "fixperms with no path must be refused"
assert_contains "$UD_OUT" "needs at least one explicit path" "fixperms must demand a path"

run_ud "$d" fixperms "."
assert_status 1 "$UD_STATUS" "fixperms on '.' must be refused"
assert_contains "$UD_OUT" "refusing to chown the repository root" \
  "the recursive-rewrite guard must name the reason"

run_ud "$d" fixperms "$d"
assert_status 1 "$UD_STATUS" "fixperms on the repo path must be refused"
assert_contains "$UD_OUT" "refusing to chown the repository root" \
  "the root guard must catch the absolute path too"

# A specific file is allowed through to the confirmation prompt, and the
# prompt is answered 'n' so sudo is never reached. This asserts the guard
# does not over-block, without ever running chown.
run_ud "$d" fixperms tracked.txt <<< "n"
assert_contains "$UD_OUT" "about to chown" "a specific path must reach the confirmation"
assert_contains "$UD_OUT" "cancelled" "answering 'n' must cancel"

# The chown must name the owner explicitly and act on the resolved absolute
# path. `sudo chown` with no OWNER sets the owner to root, which is the
# opposite of "fix permissions" — it leaves the file root-owned. And guarding
# `./x` while chowning `$argv` means guarding one string and operating on
# another.
#
# The owner is matched as "any non-empty value" rather than as `$USER`: the
# build sandbox has no USER set, and the property worth asserting is that an
# owner IS passed, not which one.
run_ud "$d" fixperms ./tracked.txt <<< "n"
if printf '%s' "$UD_OUT" | grep -qE "about to chown to [^[:space:]]+: $d/tracked\.txt"; then
  _ok "fixperms chowns the resolved absolute target, with an explicit owner"
else
  _fail "fixperms chowns the resolved absolute target, with an explicit owner" "got: $UD_OUT"
fi

# ── status is read-only ─────────────────────────────────────────────────────

make_repo
d="${FIXTURE_REPOS[-1]}"
echo "modified" >>"$d/tracked.txt"
echo "new" >"$d/fresh.txt"
before_head="$(git -C "$d" rev-parse HEAD)"
run_ud "$d" status
assert_status 0 "$UD_STATUS" "status must succeed"
assert_contains "$UD_OUT" "untracked" "status must list untracked files"
assert_contains "$UD_OUT" "fresh.txt" "status must name the untracked file"
assert_eq "$(git -C "$d" rev-parse HEAD)" "$before_head" \
  "status must not create a commit"
assert_eq "$(git -C "$d" diff --cached --name-only | wc -l | tr -d ' ')" "0" \
  "status must not stage anything"

# ── unknown subcommand ──────────────────────────────────────────────────────

make_repo
d="${FIXTURE_REPOS[-1]}"
run_ud "$d" frobnicate
assert_status 1 "$UD_STATUS" "an unknown subcommand must fail"
assert_contains "$UD_OUT" "usage:" "an unknown subcommand must print usage"

suite_summary "update_dotfiles scope"
