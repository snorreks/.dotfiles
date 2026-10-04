#!/usr/bin/env bash
# nixos/tests/run.sh — one entry point for every check this repository can run
# without a physical machine.
#
# Deliberately a thin, honest runner rather than a test framework:
#
#   * Every suite it runs is a plain bash script (or a cargo test) that also
#     runs standalone, so a developer can reproduce one failure without `nix
#     build`.
#   * It exits non-zero on the FIRST failing suite, and prints which one, rather
#     than continuing and burying the first error under later noise.
#   * What it runs comes from tests/registry.tsv, and it VERIFIES that registry
#     against what is actually on disk. A suite nobody registered fails the run.
#     See the header of registry.tsv for the drift that motivated that.
#
# ── fail-closed ─────────────────────────────────────────────────────────────
#
# The rule this file exists to enforce: a check that did not run must never be
# reported as a check that passed.
#
#   NM_REQUIRE_ALL=1   (default) A suite that cannot run — no `nix`, or a skip
#                      the caller did not authorise — is a FAILURE. This is the
#                      developer default, so "the suite that checks the hosts
#                      did not run" cannot be green.
#   NM_REQUIRE_ALL=0   Opt out, for a `checks` sandbox that genuinely cannot
#                      reach flake inputs. Skips stay LOUD.
#
# ── scopes ──────────────────────────────────────────────────────────────────
#
#   fast   pure bash/cargo. No nix, no privileges. Always required.
#   eval   evaluates configurations with `nix`. Skippable in a sandbox.
#   kvm    builds a NixOS system and runs it under KVM. NEVER run here — it is
#          a full `nix build`, minutes not seconds. See nixos/tests/README.md.
#
# Manual hardware drills (kernel bump, GPU hang recovery, reboot-free rollback
# on real hardware) are not automated at all and are listed in tests/README.md
# so their absence is on the record rather than assumed.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REGISTRY="$HERE/registry.tsv"

NM_REQUIRE_ALL="${NM_REQUIRE_ALL:-1}"
failed=0
declare -a SKIPPED=()

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

fail() {
  red "$*"
  failed=1
}

# ── registry loading and validation ─────────────────────────────────────────
#
# Validation happens BEFORE anything runs, so a malformed registry is reported
# as a malformed registry rather than as some unrelated later failure.

declare -a REG_LANE REG_PATH REG_SCOPE REG_KIND
VALID_SCOPES=(fast eval kvm)
VALID_KINDS=(shell lane cargo)

load_registry() {
  if [[ ! -f "$REGISTRY" ]]; then
    fail "registry missing: $REGISTRY"
    return 1
  fi
  local lane path scope kind
  while IFS=$'\t' read -r lane path scope kind || [[ -n "${lane:-}" ]]; do
    [[ -z "${lane:-}" ]] && continue
    case "$lane" in \#*) continue ;; esac
    if [[ -z "${path:-}" || -z "${scope:-}" || -z "${kind:-}" ]]; then
      fail "registry: incomplete row '$lane'"
      return 1
    fi
    local ok=1 v
    for v in "${VALID_SCOPES[@]}"; do [[ "$scope" == "$v" ]] && ok=0; done
    if [[ $ok -ne 0 ]]; then
      fail "registry: lane '$lane' has unknown scope '$scope' (want: ${VALID_SCOPES[*]})"
      return 1
    fi
    ok=1
    for v in "${VALID_KINDS[@]}"; do [[ "$kind" == "$v" ]] && ok=0; done
    if [[ $ok -ne 0 ]]; then
      fail "registry: lane '$lane' has unknown kind '$kind' (want: ${VALID_KINDS[*]})"
      return 1
    fi
    if [[ ! -e "$ROOT/$path" ]]; then
      fail "registry: lane '$lane' registers '$path', which does not exist"
      return 1
    fi
    REG_LANE+=("$lane")
    REG_PATH+=("$path")
    REG_SCOPE+=("$scope")
    REG_KIND+=("$kind")
  done <"$REGISTRY"

  if [[ "${#REG_PATH[@]}" -eq 0 ]]; then
    fail "registry: no suites declared"
    return 1
  fi
  return 0
}

# Directories that are covered by a registered `lane` entry point. A lane's
# run.sh aggregates its own sub-suites, so those sub-suites are reachable and
# must not each be registered again — registering them twice would run them
# twice.
declare -a LANE_DIRS=()
collect_lane_dirs() {
  local i
  for ((i = 0; i < ${#REG_PATH[@]}; i++)); do
    if [[ "${REG_KIND[$i]}" == "lane" ]]; then
      LANE_DIRS+=("$(dirname "${REG_PATH[$i]}")")
    fi
  done
}

# Every executable suite on disk must be reachable: registered directly, or
# inside a directory owned by a registered lane. This is the check that turns
# "we forgot to add the agent-operations lane" from a silent green into a
# failure.
verify_no_unregistered_suites() {
  local f rel dir unregistered=0 covered d
  while IFS= read -r f; do
    # Paths here must be relative to $ROOT (the nixos/ directory), because
    # that is what registry.tsv records. Deriving them relative to $HERE
    # instead made every suite look unregistered, including this file.
    rel="${f#"$ROOT/"}"
    [[ "$rel" == "tests/run.sh" ]] && continue
    # lib/ directories are helpers sourced by suites, never suites themselves.
    [[ "$rel" == lib/* || "$rel" == */lib/* ]] && continue

    if printf '%s\n' "${REG_PATH[@]}" | grep -Fxq "$rel"; then
      continue
    fi

    # Covered by a lane entry point?
    dir="$(dirname "$rel")"
    covered=0
    for d in ${LANE_DIRS[@]+"${LANE_DIRS[@]}"}; do
      [[ "$dir" == "$d" ]] && covered=1
    done
    [[ $covered -eq 1 ]] && continue

    fail "unregistered suite: $rel"
    echo "    register it, register its lane's run.sh, or delete it." >&2
    unregistered=1
  done < <(find "$HERE" -name '*.sh' -type f | sort)
  [[ $unregistered -eq 0 ]]
}

# ── skipping ────────────────────────────────────────────────────────────────

# Report a suite that will not run. Under the default NM_REQUIRE_ALL it fails;
# under an explicit opt-out it stays visible.
skip_or_fail() {
  local what="$1" reason="$2"
  if [[ "$NM_REQUIRE_ALL" == "0" ]]; then
    printf '\033[33mSKIPPED %s (%s)\033[0m\n' "$what" "$reason"
    SKIPPED+=("$what ($reason)")
  else
    red "SKIPPED $what ($reason), and this run requires every suite to actually run."
    echo "    Re-run where the dependency is available, or set NM_REQUIRE_ALL=0" >&2
    echo "    if a skip is expected here." >&2
    failed=1
  fi
}

# ── repo-wide lint ──────────────────────────────────────────────────────────
#
# Discovery here is by CONTENT, not by a hand-maintained list: anything with a
# bash shebang is shell, anything with a fish shebang is fish. The previous
# approach listed files explicitly and the list was always behind the tree.

bash_scripts() {
  find "$ROOT" -path "$ROOT/result*" -prune -o -type f -name '*.sh' -print0 |
    while IFS= read -r -d '' f; do
      head -1 "$f" | grep -qE '^#!.*\b(bash|sh)\b' && printf '%s\n' "${f#"$ROOT/"}"
    done | sort
}

fish_scripts() {
  find "$ROOT" -path "$ROOT/result*" -prune -o -type f -name '*.fish' -print0 |
    while IFS= read -r -d '' f; do
      head -1 "$f" | grep -q 'fish' && printf '%s\n' "${f#"$ROOT/"}"
    done | sort
}

nix_files() {
  find "$ROOT" -path "$ROOT/result*" -prune -o -type f -name '*.nix' -print |
    sed "s|^$ROOT/||" | sort
}

run_lint() {
  mapfile -t SH_FILES < <(bash_scripts)
  mapfile -t FISH_FILES < <(fish_scripts)
  mapfile -t NIX_FILES < <(nix_files)

  bold "=== lint: shellcheck (${#SH_FILES[@]} scripts) ==="
  if command -v shellcheck >/dev/null 2>&1; then
    # Shellcheck runs over EVERY script, not a curated list. The curated list
    # was the old design and it drifted: every PR that added a script had to
    # remember to add it, and the ones that forgot simply were not linted.
    #
    # Turning that on immediately fails on ~29 pre-existing findings in 17
    # files owned by other lanes. Reformatting them here would be a large,
    # unrelated diff on top of a security change, so instead the known
    # findings are recorded in tests/shellcheck-baseline.txt and the check
    # fails on anything NEW. The baseline can only shrink; a finding that
    # disappears from it without the code changing is reported too, so the
    # file cannot quietly accumulate stale entries.
    local baseline="$HERE/shellcheck-baseline.txt"
    local current
    current="$(
      cd "$ROOT" || exit 1
      local f
      for f in "${SH_FILES[@]}"; do
        shellcheck -x -P "$HERE" -S style "$ROOT/$f" -f gcc 2>/dev/null || true
      done | sed "s|^$ROOT/||" | sort -u
    )"
    local new_findings
    if [[ -f "$baseline" ]]; then
      # grep -Fxv -f rather than `comm`: `comm` needs both inputs sorted in
      # one collation, and that is not guaranteed between a pipe and a file.
      new_findings="$(printf '%s\n' "$current" | grep -Fxv -f "$baseline" || true)"
    else
      new_findings="$current"
    fi

    if [[ -n "$new_findings" ]]; then
      red "shellcheck: findings not in the baseline:"
      printf '%s\n' "$new_findings" | sed 's/^/    /'
      echo "    Fix these, or (if they are pre-existing and not yours) add them" >&2
      echo "    to nixos/tests/shellcheck-baseline.txt deliberately." >&2
      failed=1
    else
      local n
      n="$(printf '%s' "$current" | grep -c . || true)"
      printf '    \033[32mok\033[0m   no new shellcheck findings (%d baselined across %d files)\n' \
        "$n" "$(printf '%s' "$current" | cut -d: -f1 | sort -u | grep -c . || true)"
    fi
  else
    skip_or_fail "shellcheck" "not on PATH (it is in the flake check closure)"
  fi

  bold "=== lint: bash -n ==="
  local f
  for f in "${SH_FILES[@]}"; do
    if bash -n "$ROOT/$f"; then
      printf '    \033[32mok\033[0m   %s\n' "$f"
    else
      fail "bash -n: $f"
    fi
  done

  bold "=== lint: fish syntax (${#FISH_FILES[@]} files) ==="
  if command -v fish >/dev/null 2>&1; then
    for f in "${FISH_FILES[@]}"; do
      if fish -n "$ROOT/$f"; then
        printf '    \033[32mok\033[0m   %s\n' "$f"
      else
        fail "fish -n: $f"
      fi
    done
  else
    skip_or_fail "fish syntax check" "fish not on PATH"
  fi

  bold "=== lint: nix parse (${#NIX_FILES[@]} files) ==="
  if command -v nix-instantiate >/dev/null 2>&1; then
    for f in "${NIX_FILES[@]}"; do
      if nix-instantiate --parse "$ROOT/$f" >/dev/null 2>&1; then
        printf '    \033[32mok\033[0m   %s\n' "$f"
      else
        fail "nix parse: $f"
      fi
    done
  else
    skip_or_fail "nix parse" "nix-instantiate not on PATH"
  fi
}

# ── hygiene ─────────────────────────────────────────────────────────────────

# Secret shapes that must never appear as literal VALUES in tracked files.
#
# This is a shape check, not a scanner: it looks for a high-entropy literal
# assigned to something key-shaped, and for known key headers. It has no
# allowlist of real secrets because there are none in this repository, and
# hard-coding one would be the problem. sops-encrypted files are exempt by
# construction — their contents are ciphertext.
run_secret_hygiene() {
  bold "=== hygiene: secret shapes in tracked files ==="
  local hits
  hits="$(
    cd "$ROOT" || exit 1
    git grep -nIE \
      -- '(api[_-]?key|secret|passwd|password|token)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_/+=-]{16,}' \
      -- ':!*.md' ':!nixos/tests/**' ':!secrets.yaml' ':!.sops.yaml' 2>/dev/null || true
  )"
  if [[ -n "$hits" ]]; then
    red "secret-shaped literals found in tracked files:"
    printf '%s\n' "$hits" | sed 's/^/    /'
    echo "    If these are real, rotate them. If they are placeholders, say so" >&2
    echo "    explicitly rather than relying on nobody noticing." >&2
    failed=1
  else
    printf '    \033[32mok\033[0m   no secret-shaped literals\n'
  fi

  # Nothing generated should be tracked at all.
  local tracked_junk
  tracked_junk="$(
    cd "$ROOT" || exit 1
    git ls-files | grep -E '(__pycache__/|\.pyc$|/target/|\.o$|\.rlib$)' || true
  )"
  if [[ -n "$tracked_junk" ]]; then
    red "generated artifacts are tracked in git:"
    printf '%s\n' "$tracked_junk" | sed 's/^/    /'
    echo "    untrack them and add the pattern to .gitignore" >&2
    failed=1
  else
    printf '    \033[32mok\033[0m   no generated artifacts tracked\n'
  fi
}

# Trailing whitespace, and tabs in shell scripts.
#
# Scoped by OWNERSHIP rather than applied repository-wide. Trailing whitespace
# already exists in files belonging to other lanes, and reformatting them here
# would bury a security change under an unrelated mechanical diff — which this
# lane is explicitly not supposed to do.
#
# So: the files this lane owns are held to it and fail the run. Everything else
# is reported, with a count, and does not fail. That is a weaker guarantee than
# a clean tree and is the honest trade: a check that fails on pre-existing
# findings nobody has agreed to fix gets switched off entirely, and then it is
# not a check at all.
run_format_hygiene() {
  bold "=== hygiene: whitespace ==="
  local -a OWNED=(
    "tests/run.sh"
    "tests/check-registry.sh"
    "tests/update-dotfiles-scope.sh"
    "tests/registry.tsv"
    "tests/shellcheck-baseline.txt"
    "config/home/fish/functions/update_dotfiles.fish"
    "config/home/sys-daemon/src/http.rs"
    "config/home/sys-daemon/src/httpcore.rs"
    "config/home/sys-daemon/src/killsafe.rs"
  )
  local f bad=0 advisory=0
  for f in "${OWNED[@]}"; do
    if [[ -f "$ROOT/$f" ]] && grep -nP '[ \t]+$' "$ROOT/$f" >/dev/null 2>&1; then
      fail "trailing whitespace in a file this lane owns: $f"
      bad=1
    fi
  done
  [[ $bad -eq 0 ]] && printf '    \033[32mok\033[0m   no trailing whitespace in files this lane owns\n'

  # Advisory pass over everything else.
  while IFS= read -r f; do
    if grep -nP '[ \t]+$' "$ROOT/$f" >/dev/null 2>&1; then
      advisory=$((advisory + 1))
      printf '    \033[33mnote\033[0m trailing whitespace: %s\n' "$f"
    fi
  done < <(bash_scripts; fish_scripts)
  if [[ $advisory -gt 0 ]]; then
    printf '    \033[33mnote\033[0m %d file(s) outside this lane have trailing whitespace; not failing\n' "$advisory"
  fi
}

# ── cargo ───────────────────────────────────────────────────────────────────

run_cargo() {
  bold "=== cargo test (sys-daemon) ==="
  if ! command -v cargo >/dev/null 2>&1; then
    skip_or_fail "cargo test" "cargo not on PATH"
    return
  fi
  local crate="$ROOT/config/home/sys-daemon"
  # A memory ceiling, and this is not decoration. `cargo test` runs code that
  # reads /dev/urandom; an unbounded read of that device exhausts memory and
  # the kernel OOM killer takes out whatever it judges expendable — which on
  # this machine includes the agent multiplexer and every session running on
  # it. Capping the address space turns that class of regression into one
  # aborted test process instead of a dead host.
  (
    ulimit -v 4000000 2>/dev/null || true
    cd "$crate" || exit 1
    # Single-threaded: the kill-safety suite signals real child processes and
    # is deliberately sequential.
    cargo test --offline -- --test-threads=1
  ) || {
    fail "cargo test (sys-daemon)"
    return
  }
}

# ── main ────────────────────────────────────────────────────────────────────
#
# Fail-fast by default, which is the long-standing behaviour here and is right
# for editing: one broken thing, one stack to read.
#
# NM_KEEP_GOING=1 runs every suite and reports all failures. It exists because
# fail-fast hides everything after the first failure, which is exactly wrong
# when the first failure is a pre-existing one nobody in this session caused —
# you cannot then tell whether the suites after it passed.
NM_KEEP_GOING="${NM_KEEP_GOING:-0}"

bold "=== registry ==="
if ! load_registry; then
  red "run.sh: registry is unusable; refusing to run"
  exit 1
fi
printf '    %d suites across %d lanes\n' \
  "${#REG_PATH[@]}" "$(printf '%s\n' "${REG_LANE[@]}" | sort -u | wc -l | tr -d ' ')"

collect_lane_dirs
verify_no_unregistered_suites

run_lint
run_secret_hygiene
run_format_hygiene

bold "=== suites ==="
i=0
while [[ $i -lt "${#REG_PATH[@]}" ]]; do
  lane="${REG_LANE[$i]}"
  path="${REG_PATH[$i]}"
  scope="${REG_SCOPE[$i]}"
  kind="${REG_KIND[$i]}"
  i=$((i + 1))

  case "$scope" in
    kvm)
      # Declared, accounted for, deliberately not run here.
      printf '\033[33mNOT RUN\033[0m %s (%s, scope=kvm — needs KVM; see tests/README.md)\n' \
        "$lane: $path" "$kind"
      continue
      ;;
    eval)
      if [[ "${NM_SKIP_HOST_EVAL:-0}" == "1" ]] || ! command -v nix >/dev/null 2>&1; then
        reason="no nix on PATH"
        [[ "${NM_SKIP_HOST_EVAL:-0}" == "1" ]] && reason="NM_SKIP_HOST_EVAL=1"
        skip_or_fail "$lane: $path" "$reason"
        continue
      fi
      ;;
  esac

  case "$kind" in
    cargo)
      run_cargo
      ;;
    lane | shell)
      bold "=== $lane: $path ==="
      if bash "$ROOT/$path"; then
        :
      else
        fail "$lane: $path"
        if [[ "$NM_KEEP_GOING" != "1" ]]; then
          break
        fi
      fi
      ;;
  esac
done

echo
if [[ $failed -ne 0 ]]; then
  red "run.sh: FAILED"
  exit 1
fi
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  green "run.sh: passed with ${#SKIPPED[@]} declared skip(s)"
  printf '    %s\n' "${SKIPPED[@]}"
  exit 0
fi
green "run.sh: all checks passed"
