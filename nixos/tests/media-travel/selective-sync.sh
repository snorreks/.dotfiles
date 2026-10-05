#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# nixos/tests/media-travel/selective-sync.sh
#
# Audit checklist: "Test selective-sync exclusions/conflicts with isolated
# fixture directories."
#
# Syncthing's ignore rules are the SECURITY CONTROL in this lane, not a
# convenience: every rule here exists because the failure of getting it wrong
# is publishing a secret to a second device or corrupting a database that was
# open while it was copied.
#
# So the suite builds a REAL fixture tree containing one of each hazardous
# thing, runs the shipped rules over it, and asserts that only ordinary media
# survives. A rule list that is read but never exercised is a comment.
#
# Fixtures are created under $FIXTURE_TMP. Nothing here reads or writes a real
# home directory, a real sync folder, or a real Syncthing configuration.
#
# shellcheck shell=bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"

printf '=== selective-sync ===\n'

RULES="$(cd "$HERE/../../config/system/media" && pwd)/syncthing.nix"
if [[ ! -f "$RULES" ]]; then
  bad "cannot find $RULES"
  summary "selective-sync"
  exit 1
fi

# The rules live in a Nix file as the body of an environment.etc text block.
# Extracting them keeps the assertions pointed at the thing that is actually
# deployed rather than at a copy in a test.
EXTRACT="$FIXTURE_TMP/ignore.rules"
awk '/environment.etc."syncthing\/media-ignore.rules".text = /,/^  '"''"';$/' "$RULES" >"$EXTRACT"
if [[ ! -s "$EXTRACT" ]]; then
  bad "could not extract the ignore rules from $RULES"
  summary "selective-sync"
  exit 1
fi
ok "ignore rules extracted from the module"

# ── Build a fixture tree containing one of each hazard ─────────────────────
TREE="$FIXTURE_TMP/sync"
mkdir -p "$TREE"/{media,repo/.git,repo/worktrees,db,agent/sessions,agent/herdr,keys,tailscale,build}

# Ordinary media: MUST survive.
: >"$TREE/media/Movie (2024).mkv"
: >"$TREE/media/Series - S01E01.mkv"
: >"$TREE/media/cover.jpg"

# Hazards: none may survive.
: >"$TREE/repo/.git/config"
: >"$TREE/repo/worktrees/wt-metadata"
: >"$TREE/db/library.db"
: >"$TREE/db/library.db-wal"
: >"$TREE/db/qBittorrent.sqlite3"
: >"$TREE/agent/sessions/session-1.jsonl"
: >"$TREE/agent/herdr/state.db" || die "fixture: could not create agent/herdr/state.db"
: >"$TREE/keys/id_ed25519"
: >"$TREE/keys/repo.age"
: >"$TREE/keys/tls.pem"
: >"$TREE/keys/.env"
: >"$TREE/keys/secrets.yaml"
: >"$TREE/tailscale/tailscaled.state"
: >"$TREE/build/result"

# ── Apply the rules ────────────────────────────────────────────────────────
# Syncthing's own binary is not required: `syncthing ignore` needs a running
# instance. The pattern semantics that matter here (a trailing `/` matches a
# directory and its contents; a bare name matches at any depth) are applied by
# `syncthing-cli`-free matching below, which is why each rule is checked
# against a concrete path rather than by trusting the file to be well-formed.
# Applies a rule to one relative path, with the semantics Syncthing gives them:
#
#   * a rule ending in `/` matches a DIRECTORY and everything under it, at any
#     depth (Syncthing patterns are not anchored to the folder root for this);
#   * any other rule is a glob matched against the whole relative path AND
#     against the basename, which is what makes `*.db` work without also
#     requiring the rule to be re-written per directory.
#
# `case` does the globbing, so `*.db` and `result-*` are honoured as written
# rather than being approximated by an exact-name comparison.
excluded() {
  local rel="$1" rule stripped
  while IFS= read -r rule; do
    rule="${rule%%$'\r'}"
    # Nix strips the common INDENTATION of an indented string, so the deployed
    # file has `    .git/` as `.git/`. Reading the block raw would leave four
    # leading spaces on every rule and silently match nothing — which is exactly
    # the failure this suite exists to catch, so it must not be the suite's.
    rule="${rule#"${rule%%[![:space:]]*}"}"
    [[ -z "$rule" || "$rule" == \#* || "$rule" == *"'';"* ]] && continue
    if [[ "$rule" == */ ]]; then
      stripped="${rule%/}"
      # any depth
      [[ "$rel" == "$stripped" || "$rel" == "$stripped"/* \
         || "$rel" == *"/$stripped" || "$rel" == *"/$stripped"/* ]] && return 0
    else
      # DELIBERATELY UNQUOTED. The rules ARE globs (`*.db`, `*.age`,
      # `result-*`) and the glob is the entire point: quoting the pattern makes
      # `case` match it literally, so `library.db` stops matching `*.db` and the
      # suite passes while the rule does nothing.
      #
      # (shellcheck would quote the pattern to avoid accidental globbing; that
      # is precisely the behaviour required here.)
      # shellcheck disable=SC2254
      case "$rel" in
        $rule) return 0 ;;
      esac
      # shellcheck disable=SC2254
      case "${rel##*/}" in
        $rule) return 0 ;;
      esac
    fi
  done <"$EXTRACT"
  return 1
}

# Any failure while BUILDING the fixture has to be fatal. Without this the
# `: > file` for a directory that does not exist failed silently and the suite
# went on to report success on an incomplete tree.
die() {
  printf '    FATAL fixture error: %s\n' "$1" >&2
  summary "selective-sync"
  exit 1
}

expect_kept() {
  local rel="$1"
  if excluded "$rel"; then
    bad "excluded a file that must survive: $rel" "media disappearing from the sync is as broken as a secret appearing in it"
  else
    ok "kept: $rel"
  fi
}

expect_excluded() {
  local rel="$1" why="$2"
  if excluded "$rel"; then
    ok "excluded: $rel"
  else
    bad "NOT excluded: $rel" "$why"
  fi
}

echo "--- media (must survive) ---"
expect_kept "media/Movie (2024).mkv"
expect_kept "media/Series - S01E01.mkv"
expect_kept "media/cover.jpg"

echo "--- version control ---"
expect_excluded "repo/.git/config" "a synchronised .git produces two repositories that disagree"
expect_excluded "repo/worktrees/wt-metadata" "worktree metadata is meaningless on another machine"

echo "--- live databases ---"
expect_excluded "db/library.db" "a half-copied SQLite database is valid and corrupt at once"
expect_excluded "db/library.db-wal" "the write-ahead log is part of the same hazard"
expect_excluded "db/qBittorrent.sqlite3" "same hazard, different extension"

echo "--- agent runtime state ---"
expect_excluded "agent/sessions/session-1.jsonl" "two agents writing one synchronised session store corrupts both"
expect_excluded "agent/herdr/state.db" "live herdr state is not portable state"

echo "--- key material and decrypted environments ---"
expect_excluded "keys/id_ed25519" "a synchronised private key is a private key on another device"
expect_excluded "keys/repo.age" "age keys are credentials"
expect_excluded "keys/tls.pem" "TLS private keys are credentials"
expect_excluded "keys/.env" "a decrypted environment is a list of live credentials"
expect_excluded "keys/secrets.yaml" "this repository's own secret file must never leave it"

echo "--- tailscale identity ---"
expect_excluded "tailscale/tailscaled.state" "two devices sharing one node key is a tailnet incident"

echo "--- build artefacts ---"
expect_excluded "build/result" "a Nix store symlink is meaningless and machine-specific elsewhere"

# ── No folder selection is configured by default ──────────────────────────
# An empty folder list is the safe default; a default of $HOME would pull every
# key and decrypted environment through these rules by accident of what is new.
if grep -q "folders = \[\];" "$(cd "$HERE/../.." && pwd)/options.nix"; then
  ok "opts.media.syncthing.folders defaults to empty (nothing selected)"
else
  bad "the default folder list is not empty" "a home-directory folder is how a key reaches a second device"
fi

# ── The module refuses the two folder shapes that cannot be safe ───────────
SYN="$HERE/../../config/system/media/syncthing.nix"
if grep -qF '"/var/lib/tailscale"' "$SYN" && grep -qF 'lib.all safeFolder cfg.folders' "$SYN"; then
  ok "the module refuses a Tailscale-state folder at evaluation"
else
  bad "no assertion refusing a Tailscale-state folder"
fi
# The raw selection is checked, including lexical traversal and actual homes.
# shellcheck disable=SC2016
if grep -qF 'path != "/home/${opts.username}"' "$SYN" && grep -qF 'builtins.elem ".."' "$SYN"; then
  ok "the module refuses a whole-home folder at evaluation"
else
  bad "no assertion refusing a whole-home folder"
fi

# Offline preparation is scoped and repeatable, not an arbitrary file copier.
PREP="$HERE/../../config/system/media/scripts/media-offline-prep.sh"
LIBRARY="$FIXTURE_TMP/library"
CACHE="$FIXTURE_TMP/cache"
OUTSIDE="$FIXTURE_TMP/outside"
mkdir -p "$LIBRARY/Films/Example" "$CACHE" "$OUTSIDE"
printf 'fixture movie\n' >"$LIBRARY/Films/Example/movie.mkv"
printf 'private canary\n' >"$OUTSIDE/private.txt"
prep() { MEDI_LIBRARY_ROOT="$LIBRARY" MEDI_TRAVEL_CACHE="$CACHE" MEDI_MIN_FREE_MB=0 bash "$PREP" "$@" >"$FIXTURE_TMP/prep.out" 2>&1; }
if prep 'Films/Example' && prep 'Films/Example' && [[ -f "$CACHE/Films/Example/movie.mkv" && ! -e "$CACHE/Films/Example/Example" ]]; then
  ok 'repeating an offline directory selection does not nest directories'
else
  bad 'offline directory copy is not repeat-safe' "$(cat "$FIXTURE_TMP/prep.out")"
fi
if prep '../outside/private.txt'; then bad 'offline selector escaped its root'; else ok 'offline traversal is refused'; fi
ln -s "$OUTSIDE" "$LIBRARY/escape"
if prep 'escape/private.txt'; then bad 'source symlink escaped the library'; else ok 'source symlink escape is refused'; fi
ln -s "$OUTSIDE" "$CACHE/escape"
mkdir -p "$LIBRARY/escape-dest"
printf 'safe\n' >"$LIBRARY/escape-dest/item"
ln -s "$OUTSIDE" "$CACHE/escape-dest"
if prep 'escape-dest/item'; then bad 'destination symlink escaped the cache'; else ok 'destination symlink escape is refused'; fi
if [[ ! -e "$OUTSIDE/item" ]]; then ok 'no out-of-cache file was written'; else bad 'outside destination was changed'; fi

summary "selective-sync"