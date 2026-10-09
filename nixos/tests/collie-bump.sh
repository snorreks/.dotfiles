#!/usr/bin/env bash
# nixos/tests/collie-bump.sh — the bump helper, driven against fakes.
#
# WHAT THIS IS FOR
#
# `collie-bump` edits a tracked file in a git repo, rewrites flake.lock, and is
# meant to be run from a phone over SSH on an unattended server. Every one of
# those is a place where a plausible-looking success hides a real failure:
#
#   * a `sed` pattern loose enough to also repoint herdr or bun2nix;
#   * a "already up to date" branch that silently skips the lock;
#   * a `nix flake lock` that fails and leaves the pin moved with no lock to
#     match it, which does not build again until someone notices;
#   * a tag that resolved fine but whose LOCKED revision reports a different
#     payload, which means upstream moved mid-bump and the operator's number is
#     wrong;
#   * and the big one: anything that builds or ACTIVATES. The whole reason the
#     helper stops at `nix flake lock` is that activation is where the 20-minute
#     dead-man timer lives, and a helper that activated would remove the window
#     in which a human can still verify from a second connection.
#
# So the suite asserts on the calls made, not on the prose printed.
#
# NOTHING HERE TOUCHES THE NETWORK. curl is faked and serves a fixture tree of
# sources.json files, so a test can never depend on what upstream published
# today, and cannot pass merely because GitHub is reachable. `nix` is faked too:
# the real one is never run, so no test can lock, fetch, or build anything.
#
# Run directly:  bash nixos/tests/collie-bump.sh
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUMP="$ROOT/config/home/scripts/scripts/collie-bump.sh"

TESTS_RUN=0
TESTS_FAILED=0
FAILURES=()
CURRENT_TEST=""

# shellcheck source=agent-operations/lib/fixture.sh
source "$HERE/agent-operations/lib/fixture.sh"

SUITE_NAME=collie-bump

# fixture.sh has _t_start but no _t_done — that one lives in the ns-maint
# harness, which this suite deliberately does not source. Only the label reset is
# wanted here; there is no reboot invariant to check, because nothing in this
# suite can reach systemd at all.
_t_done() { CURRENT_TEST=""; }

# ── fixture ──────────────────────────────────────────────────────────────────

# The payload each tag "delivers", standing in for upstream's one-release-late
# manifest. This is the shape the real repository has at every tag: the tag and
# the version it wraps are different numbers.
#
# The lock file's own pinned rev is listed too, because the helper re-reads the
# payload from the revision that actually landed rather than from the tag.
DEFAULT_PAYLOADS='v1.15.3 1.15.0
v1.16.2 1.16.1
v1.18.1 1.17.2
v1.19.0 1.18.0
033bf1f546c14afae930f2358de80ab554794c2e 1.15.0'

# A flake directory whose collie input is pinned at $1 (default v1.15.3), with a
# lock file the fake `nix` can answer for.
make_flake() {
  local tag="${1:-v1.15.3}"
  mkdir -p "$TMP/flake"
  {
    echo '{'
    echo '  description = "fixture";'
    echo '  inputs.collie.url = "github:AltanS/collie/'"$tag"'";'
    echo '  inputs.herdr.url = "github:danielpocock/panai/panai";'
    echo '  inputs.bun2nix.url = "github:Mic92/bun2nix/llm-agents";'
    echo '}'
  } >"$TMP/flake/flake.nix"
  cat >"$TMP/flake/flake.lock" <<'LOCK'
{
  "nodes": {
    "root": { "inputs": { "bun2nix": "bun2nix", "collie": "collie" } },
    "collie": {
      "locked": {
        "lastModified": 1790932122,
        "narHash": "sha256-KO8FGm6411axP/V3nE+gKS4xdr/ovqc+52watujnR3Y=",
        "owner": "AltanS",
        "repo": "collie",
        "rev": "033bf1f546c14afae930f2358de80ab554794c2e",
        "type": "github"
      },
      "original": { "owner": "AltanS", "ref": "v1.15.3", "repo": "collie", "type": "github" }
    },
    "bun2nix": {
      "locked": { "rev": "07a5bfc8ac36c5370199343fa620b69f63186e33", "type": "github" },
      "original": { "owner": "Mic92", "ref": "llm-agents", "repo": "bun2nix", "type": "github" }
    }
  },
  "root": "root",
  "version": 7
}
LOCK
}

# install_fakes — curl, nix, and the payload table the fake curl serves.
#
# A function rather than top-level code because `fake` writes into $TMP, which
# only exists once fixture_new has run, and every test gets a fresh one.
install_fakes() {
  # The mapping the fake curl greps: "<ref> <payload>" per line.
  printf '%s\n' "$DEFAULT_PAYLOADS" >"$TMP/payloads"
  export FIXTURE_PAYLOADS="$TMP/payloads"

  # curl answers the raw sources.json fetch and the releases API, and only for a
  # ref the table knows. Anything else fails, which is what a wrong tag looks
  # like for real. jq is deliberately NOT faked: the helper's own parsing is
  # part of what is under test.
  fake curl <<'FAKE'
set -u
url="${*: -1}"
case "$url" in
  *api.github.com/repos/*/releases/latest)
    printf '{"tag_name": "v1.19.0"}\n'
    exit 0
    ;;
  *raw.githubusercontent.com/*/packaging/nix/sources.json)
    # Owner and repo first, THEN the ref — the other order strips at the first
    # slash and leaves "AltanS", which matches nothing and fails as a 404.
    ref="${url#*raw.githubusercontent.com/}"
    ref="${ref#AltanS/collie/}"
    ref="${ref%%/*}"
    payload="$(grep "^$ref " "$FIXTURE_PAYLOADS" 2>/dev/null | cut -d' ' -f2)"
    if [ -z "$payload" ]; then
      printf 'curl: (22) The requested URL returned error: 404\n' >&2
      exit 22
    fi
    printf '{ "version": "%s" }\n' "$payload"
    exit 0
    ;;
esac
printf 'curl: (22) unexpected URL %s\n' "$url" >&2
exit 22
FAKE

  # nix records what it was asked. It never locks for real — the fixture's lock
  # file is rewritten in place so the assertion sees a consistent pair of flake
  # and lock, which is the whole point of the "failed lock restores the pin" test.
  fake nix <<'FAKE'
set -u
printf 'nix %s\n' "$*" >>"$TMP/log/calls"
case "$*" in
  "flake lock")
    if [ "${FAKE_LOCK_FAILS:-0}" != 0 ]; then
      printf 'error: lock failed\n' >&2
      exit 1
    fi
    ref="$(sed -n 's|.*AltanS/collie/v\([0-9.]*\)".*|\1|p' flake.nix)"
    rev="${FAKE_LOCKED_REV:-cfaf95a93df3c9404a03f5f840bf222f0cd6c2ee}"
    sed -i.bak \
      -e "s|\"rev\": \"033bf1f546c14afae930f2358de80ab554794c2e\"|\"rev\": \"$rev\"|" \
      -e "s|\"ref\": \"v1.15.3\"|\"ref\": \"v$ref\"|" flake.lock
    rm -f flake.lock.bak
    exit 0
    ;;
  "flake metadata --json")
    rev="$(sed -n 's|.*"rev": "\([0-9a-f]*\)".*|\1|p' flake.lock | head -1)"
    printf '{"locks":{"nodes":{"collie":{"locked":{"rev":"%s"}}}}}\n' "$rev"
    exit 0
    ;;
esac
printf 'nix: unexpected invocation: %s\n' "$*" >&2
exit 2
FAKE
}

# Every test starts here: a fresh disposable root, the fakes, and the two knobs
# the fakes read. Resetting both explicitly is the point of the harness's own
# comment — a leftover FAKE_LOCK_FAILS would silently invert a later assertion.
new_fixture() {
  fixture_new
  unset FAKE_LOCK_FAILS FAKE_LOCKED_REV
  install_fakes
}

# Run the helper. stdout+stderr are merged because the interesting refusals are
# on stderr, and every run happens inside the fixture so `nix` and `curl` resolve
# to the fakes via $TMP/bin.
bump() {
  (cd "$TMP/flake" && COLLIE_FLAKE_DIR="$TMP/flake" bash "$BUMP" "$@" 2>&1)
}
rc_of() {
  (cd "$TMP/flake" && COLLIE_FLAKE_DIR="$TMP/flake" bash "$BUMP" "$@" >/dev/null 2>&1)
}
calls() { cat "$TMP/log/calls" 2>/dev/null; }
reset_calls() { : >"$TMP/log/calls"; }

# ── tests ────────────────────────────────────────────────────────────────────

printf '\n\033[1mcollie-bump — pin rewriting, locking, and the payload it reports\033[0m\n'

_t_start "a normal bump moves exactly one URL and locks once"
new_fixture
make_flake v1.15.3
reset_calls
out="$(bump 1.18.1 --yes)"
rc=$?
assert_eq 0 "$rc" "the bump succeeds"
assert_contains "$(cat "$TMP/flake/flake.nix")" 'AltanS/collie/v1.18.1' "the collie tag moved"
assert_not_contains "$(cat "$TMP/flake/flake.nix")" 'AltanS/collie/v1.15.3' "the old tag is gone"
assert_eq 1 "$(grep -c 'nix flake lock' <<<"$(calls)")" "exactly one nix flake lock"
assert_not_contains "$(calls)" "nix flake update" "a bare flake update is never run"
assert_contains "$out" "1.17.2" "the payload the tag wraps is reported"
fixture_free
_t_done

_t_start "the rewrite touches only the collie input"
new_fixture
make_flake v1.15.3
reset_calls
bump 1.18.1 --yes >/dev/null
flake="$(cat "$TMP/flake/flake.nix")"
assert_contains "$flake" 'github:Mic92/bun2nix/llm-agents' "bun2nix is untouched"
assert_contains "$flake" 'github:danielpocock/panai/panai' "herdr is untouched"
assert_eq 3 "$(grep -c 'url = ' <<<"$flake")" "no input was added or removed"
assert_eq 1 "$(grep -c 'collie/v1.18.1' <<<"$flake")" "the collie URL appears exactly once"
fixture_free
_t_done

_t_start "v-prefixed input is accepted and stored bare"
new_fixture
make_flake v1.15.3
bump v1.18.1 --yes >/dev/null
assert_contains "$(cat "$TMP/flake/flake.nix")" 'AltanS/collie/v1.18.1' "v1.18.1 is stored as v1.18.1"
assert_not_contains "$(cat "$TMP/flake/flake.nix")" 'vv1.18.1' "the tag is not doubled"
fixture_free
_t_done

_t_start "re-running the same bump is a no-op, not a second edit"
new_fixture
make_flake v1.15.3
reset_calls
bump 1.18.1 --yes >/dev/null
before="$(cat "$TMP/flake/flake.nix")"
reset_calls
out="$(bump 1.18.1 --yes)"
assert_eq "$before" "$(cat "$TMP/flake/flake.nix")" "the file is byte-identical"
assert_not_contains "$(calls)" "nix flake lock" "an already-current pin does not lock again"
assert_contains "$out" "Nothing to do" "and says so"
fixture_free
_t_done

_t_start "a failed lock puts the old tag back"
new_fixture
make_flake v1.15.3
reset_calls
out="$(FAKE_LOCK_FAILS=1 bump 1.18.1 --yes)"; rc=$?
assert_ne 0 "$rc" "the failure is not swallowed"
assert_contains "$(cat "$TMP/flake/flake.nix")" 'AltanS/collie/v1.15.3' "the pin was restored"
assert_not_contains "$(cat "$TMP/flake/flake.nix")" 'v1.18.1' "the failed tag is not left behind"
assert_contains "$out" "put back" "and the operator is told the pin moved back"
fixture_free
_t_done

_t_start "a tag whose manifest is unreadable changes nothing"
new_fixture
make_flake v1.15.3
reset_calls
out="$(bump 9.9.9 --yes)"; rc=$?
assert_ne 0 "$rc" "an unknown tag fails"
assert_contains "$(cat "$TMP/flake/flake.nix")" 'AltanS/collie/v1.15.3' "the flake is untouched"
assert_not_contains "$(calls)" "nix flake lock" "nothing was locked"
assert_contains "$out" "cannot read" "and the reason is the manifest, not a generic error"
fixture_free
_t_done

_t_start "a malformed version never reaches the file"
new_fixture
make_flake v1.15.3
for bad in 1.18 "1.18.1; rm -rf /" "v1.18.1 && evil" "../../etc/passwd"; do
  reset_calls
  out="$(bump "$bad" --yes)"; rc=$?
  assert_ne 0 "$rc" "'$bad' is refused"
  assert_contains "$(cat "$TMP/flake/flake.nix")" 'AltanS/collie/v1.15.3' "'$bad' left the pin alone"
done
fixture_free
_t_done

_t_start "no input path builds or activates anything"
new_fixture
make_flake v1.15.3
reset_calls
bump 1.18.1 --yes >/dev/null
# The only permitted nix invocations are the two lock/metadata reads.
assert_not_contains "$(calls)" "nix build" "nothing is built"
assert_not_contains "$(calls)" "nixos-rebuild" "nothing is activated"
assert_not_contains "$(calls)" "ns-maint" "no maintenance transaction is started"
assert_not_contains "$(calls)" "systemctl" "no unit is restarted"
assert_not_contains "$(calls)" "nix profile" "the profile is not switched"
fixture_free
_t_done

_t_start "--current and --check are read-only"
new_fixture
make_flake v1.15.3
reset_calls
before_nix="$(cat "$TMP/flake/flake.nix")"
before_lock="$(cat "$TMP/flake/flake.lock")"
out="$(bump --current)"
assert_contains "$out" "v1.15.3" "--current names the pinned tag"
assert_contains "$out" "1.15.0" "--current names the payload it wraps"
reset_calls
out="$(bump --check 1.18.1)"
assert_contains "$out" "1.17.2" "--check reports the payload"
assert_contains "$out" "nothing was changed" "--check says it changed nothing"
assert_eq "$before_nix" "$(cat "$TMP/flake/flake.nix")" "flake.nix is byte-identical"
assert_eq "$before_lock" "$(cat "$TMP/flake/flake.lock")" "flake.lock is byte-identical"
assert_eq "" "$(calls)" "neither even read the lock"
fixture_free
_t_done

_t_start "a locked revision that disagrees with the tag is flagged"
new_fixture
make_flake v1.15.3
# The tag advertises 1.17.2, but land a revision whose manifest names something
# else — upstream moved between the check and the lock.
export FAKE_LOCKED_REV="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 1.16.9\n' >>"$TMP/payloads"
reset_calls
out="$(bump 1.18.1 --yes)"
assert_contains "$out" "WARNING" "the disagreement is surfaced, not swallowed"
assert_contains "$out" "1.16.9" "the locked payload is named"
assert_contains "$out" "moved under you" "and the operator is told why the numbers differ"
fixture_free
_t_done

_t_start "--latest resolves the newest tag, then pins it"
new_fixture
make_flake v1.15.3
reset_calls
out="$(bump --latest --yes)"
assert_contains "$out" "v1.19.0" "the newest tag is reported"
assert_contains "$(cat "$TMP/flake/flake.nix")" 'AltanS/collie/v1.19.0' "and pinned"
assert_contains "$out" "1.18.0" "with the payload it wraps"
fixture_free
_t_done

_t_start "a non-interactive run without --yes refuses rather than assuming"
new_fixture
make_flake v1.15.3
reset_calls
out="$(bump 1.18.1 </dev/null)"; rc=$?
assert_ne 0 "$rc" "no silent default-to-yes"
assert_contains "$(cat "$TMP/flake/flake.nix")" 'AltanS/collie/v1.15.3' "nothing was rewritten"
assert_contains "$out" "--yes" "the refusal names the flag that allows it"
fixture_free
_t_done

_t_start "the helper refuses a flake whose collie input it cannot find"
new_fixture
mkdir -p "$TMP/flake"
printf '{ inputs.herdr.url = "github:danielpocock/panai/panai"; }\n' >"$TMP/flake/flake.nix"
out="$(bump --current)"; rc=$?
assert_ne 0 "$rc" "a reshaped input is an error, not a guess"
assert_contains "$out" "shape of the collie input" "the operator is told what to look at"
fixture_free
_t_done

_t_start "a missing flake directory is reported, not created"
new_fixture
out="$(COLLIE_FLAKE_DIR="$TMP/absent" bash "$BUMP" --current 2>&1)"; rc=$?
assert_ne 0 "$rc" "a wrong COLLIE_FLAKE_DIR fails"
assert_contains "$out" "COLLIE_FLAKE_DIR" "the override is named"
assert_no_file "$TMP/absent" "and nothing was created on the way"
fixture_free
_t_done

summary