#!/usr/bin/env bash
# nixos/tests/media-travel/state-restore.sh
#
# Audit checklist: "storage missing, ... and state restore".
#
# Exercises the SHIPPED media-state.sh against a real SQLite database:
#
#   * a live database is exported with the backup API and passes integrity_check
#   * a CORRUPT database is refused rather than exported — and the refusal
#     leaves the previous good export in place instead of replacing it with
#     something broken
#   * `verify` reports a missing export directory as a FAILURE (a backup whose
#     verification has nothing to look at must not pass quietly)
#   * `verify` re-checks the exported copy independently of the export run
#
# The corrupt case is the one that matters. `cp` of a database being written
# produces a file that PASSES integrity_check and is still wrong, so a suite
# that only tests the happy path would pass while the backup silently rotted.
#
# shellcheck shell=bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"

printf '=== state-restore ===\n'

# Resolved explicitly rather than assumed on PATH: the suite is expected to run
# inside the flake check sandbox, where sqlite3 is in the build inputs rather
# than on the developer's PATH.
SQLITE="${MEDI_SQLITE:-sqlite3}"
if ! command -v "$SQLITE" >/dev/null 2>&1; then
  # find, not ls: a store path is fine today, but ls parsing is what breaks
  # first on a path with an unexpected character in it.
  SQLITE="$(find /nix/store -maxdepth 3 -path '*-sqlite-*/bin/sqlite3' -type f 2>/dev/null | sort | tail -1)"
fi
if [[ -z "$SQLITE" || ! -x "$SQLITE" ]]; then
  printf 'sqlite3 not available — cannot exercise the export path.\n' >&2
  printf 'It is in the flake check closure (nativeBuildInputs) for nix build.\n' >&2
  exit 1
fi

STATE="$FIXTURE_TMP/exports"
HEALTH="$FIXTURE_TMP/health"
LIB="$FIXTURE_TMP/library.db"
QBIT="$FIXTURE_TMP/qBittorrent.conf"
mkdir -p "$STATE" "$HEALTH"

"$SQLITE" "$LIB" 'CREATE TABLE media (id INTEGER PRIMARY KEY, path TEXT);'
"$SQLITE" "$LIB" "INSERT INTO media (path) VALUES ('/srv/media/library/Movies/x.mkv');"
printf '[Preferences]\nWebUI\Port=18080\n' >"$QBIT"

# MEDI_LOCK is redirected into the fixture: /run/lock is root-owned, and a
# suite that cannot create its own lock cannot test anything. Overridable in
# the script precisely so it can be run unprivileged.
export MEDI_STATE_DIR="$STATE" MEDI_HEALTH_DIR="$HEALTH" \
  MEDI_LOCK="$FIXTURE_TMP/media-state.lock" \
  MEDI_JELLYFIN_DB="$LIB" MEDI_QBITTORRENT_PATHS="$QBIT"

# ── 1. A healthy database exports and verifies ─────────────────────────────
if MEDI_SQLITE="$SQLITE" bash "$MEDIA_SCRIPTS/media-state.sh" export >"$FIXTURE_TMP/exp.log" 2>&1; then
  ok "export succeeded"
else
  bad "export failed" "$(tail -3 "$FIXTURE_TMP/exp.log")"
fi

if [[ -f "$STATE/library.db" ]]; then
  ok "the library index was exported"
else
  bad "no exported library index" "$(ls -la "$STATE" 2>&1)"
fi
if [[ -f "$STATE/plain-qBittorrent.conf" ]]; then
  ok "the qBittorrent settings were copied plainly (it is not a database)"
else
  bad "qBittorrent settings were not copied" "$(ls "$STATE" 2>&1)"
fi

if MEDI_SQLITE="$SQLITE" bash "$MEDIA_SCRIPTS/media-state.sh" verify \
  --exports "$STATE" --health-dir "$HEALTH" >"$FIXTURE_TMP/ver.log" 2>&1; then
  ok "verify passed on a good export"
else
  bad "verify failed on a good export" "$(tail -3 "$FIXTURE_TMP/ver.log")"
fi
if [[ -f "$HEALTH/media-state.json" ]] && grep -q '"mediaExport":"ok"' "$HEALTH/media-state.json"; then
  ok "verify wrote a health record"
else
  bad "no health record written" "$(cat "$HEALTH/media-state.json" 2>&1)"
fi

# ── 2. A corrupt database is REFUSED, and the good export survives ─────────
#
# The important property is the second half: a failed export must not leave a
# broken or empty tree where a good one used to be. A backup that replaces a
# working export with nothing on the first bad run is worse than one that fails
# loudly and keeps what it had.
printf 'this is definitely not a sqlite database\n' >"$LIB"
if MEDI_SQLITE="$SQLITE" bash "$MEDIA_SCRIPTS/media-state.sh" export >"$FIXTURE_TMP/bad.log" 2>&1; then
  bad "export SUCCEEDED on a corrupt database" "a corrupt export that passes integrity_check is the failure this guards"
else
  ok "export refused a corrupt database"
fi
if grep -qiE "integrity|not a database" "$FIXTURE_TMP/bad.log"; then
  ok "the refusal names the reason"
else
  bad "the refusal does not explain itself" "$(tail -3 "$FIXTURE_TMP/bad.log")"
fi
if [[ -f "$STATE/library.db" ]]; then
  ok "the previous good export was left in place"
else
  bad "the failed export destroyed the previous good export" "$(ls "$STATE" 2>&1)"
fi

# ── 3. A missing export directory is a FAILURE, not a quiet pass ───────────
rm -rf "$STATE"
if MEDI_SQLITE="$SQLITE" bash "$MEDIA_SCRIPTS/media-state.sh" verify \
  --exports "$STATE" --health-dir "$HEALTH" >"$FIXTURE_TMP/missing.log" 2>&1; then
  bad "verify passed with no export directory" "a backup that verified nothing must not report success"
else
  ok "verify fails when the export directory is absent"
fi
if grep -q '"mediaExport":"missing"' "$HEALTH/media-state.json"; then
  ok "the missing export is recorded distinctly from 'nothing to check'"
else
  bad "the missing export is not recorded" "$(cat "$HEALTH/media-state.json" 2>&1)"
fi

# ── 4. An empty plain copy is treated as a failure ─────────────────────────
mkdir -p "$STATE"
: >"$STATE/plain-empty"
if MEDI_SQLITE="$SQLITE" bash "$MEDIA_SCRIPTS/media-state.sh" verify \
  --exports "$STATE" --health-dir "$HEALTH" >"$FIXTURE_TMP/empty.log" 2>&1; then
  bad "verify passed with an empty plain export" "a zero-byte state file is a failure, not a success"
else
  ok "verify fails on an empty plain export"
fi

# ── 5. No usage output means the script is not silently permissive ─────────
if MEDI_SQLITE="$SQLITE" bash "$MEDIA_SCRIPTS/media-state.sh" bogus >/dev/null 2>&1; then
  bad "an unknown subcommand was accepted"
else
  ok "an unknown subcommand is refused"
fi

summary "state-restore"