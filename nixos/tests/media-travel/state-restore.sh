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
SQLITE="$(command -v "${MEDI_SQLITE:-sqlite3}" || true)"
if [[ -z "$SQLITE" ]]; then
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

# ── Fresh, qbit-only, missing-state and quiesce regressions ─────────────────
rm -rf "$STATE"
mkdir -p "$STATE"
if MEDI_SQLITE="$SQLITE" bash "$MEDIA_SCRIPTS/media-state.sh" verify \
  --exports "$STATE" --health-dir "$HEALTH" >/dev/null 2>&1; then
  bad "verify accepted an empty export tree"
else
  ok "verify refuses a fresh empty export tree"
fi
if MEDI_JELLYFIN_DB='' MEDI_QBITTORRENT_PATHS='' bash "$MEDIA_SCRIPTS/media-state.sh" export >/dev/null 2>&1; then
  bad "export accepted no configured state"
else
  ok "export refuses absent configured state"
fi
if MEDI_JELLYFIN_DB='' bash "$MEDIA_SCRIPTS/media-state.sh" export >/dev/null 2>&1 \
  && MEDI_SQLITE="$SQLITE" bash "$MEDIA_SCRIPTS/media-state.sh" verify --exports "$STATE" --health-dir "$HEALTH" >/dev/null 2>&1; then
  ok "qbit-only state is exported without a Jellyfin database"
else
  bad "qbit-only export failed"
fi
if MEDI_JELLYFIN_DB='' MEDI_QBITTORRENT_PATHS="$FIXTURE_TMP/missing" \
  bash "$MEDIA_SCRIPTS/media-state.sh" export >/dev/null 2>&1; then
  bad "export accepted missing configured state"
else
  ok "export refuses missing configured state"
fi
if [[ -s "$STATE/plain-qBittorrent.conf" ]]; then
  ok "missing-state refusal preserves the good qbit export"
else
  bad "missing-state refusal lost the good export"
fi
# A fake systemctl exercises ordering and restart without touching services.
mkdir -p "$FIXTURE_TMP/bin"
# shellcheck disable=SC2016 # Expanded only inside the fake systemctl.
printf '#!%s\nprintf "%%s\\n" "$*" >>"$MEDI_TEST_CALLS"\n' "$(command -v bash)" >"$FIXTURE_TMP/bin/systemctl"
chmod +x "$FIXTURE_TMP/bin/systemctl"
export MEDI_TEST_CALLS="$FIXTURE_TMP/systemctl.log"
if PATH="$FIXTURE_TMP/bin:$PATH" MEDI_JELLYFIN_DB='' MEDI_QBITTORRENT_UNIT=fixture.service \
  bash "$MEDIA_SCRIPTS/media-state.sh" export >/dev/null 2>&1 \
  && [[ "$(tail -2 "$MEDI_TEST_CALLS")" == $'stop fixture.service\nstart fixture.service' ]]; then
  ok "plain export quiesces and restarts only the previously active unit"
else
  bad "plain export did not quiesce/restart the fixture unit"
fi
: >"$MEDI_TEST_CALLS"
if PATH="$FIXTURE_TMP/bin:$PATH" MEDI_JELLYFIN_DB='' MEDI_QBITTORRENT_UNIT=fixture.service \
  MEDI_QBITTORRENT_PATHS="$FIXTURE_TMP/missing" bash "$MEDIA_SCRIPTS/media-state.sh" export >/dev/null 2>&1; then
  bad "quiesced missing-state export unexpectedly passed"
elif [[ "$(tail -1 "$MEDI_TEST_CALLS")" == 'start fixture.service' ]]; then
  ok "failed export restarts the previously active fixture unit"
else
  bad "failed export left the fixture unit stopped"
fi

# ── 5. No usage output means the script is not silently permissive ─────────
if MEDI_SQLITE="$SQLITE" bash "$MEDIA_SCRIPTS/media-state.sh" bogus >/dev/null 2>&1; then
  bad "an unknown subcommand was accepted"
else
  ok "an unknown subcommand is refused"
fi

# A fresh daemon can have no torrents yet; its nonempty config is still valid
# restorable state. Include both trees without colon/newline path splitting.
mkdir -p "$FIXTURE_TMP/qbit-empty" "$FIXTURE_TMP/qbit:config"
printf '[Preferences]\nWebUI\\Address=10.77.0.2\n' >"$FIXTURE_TMP/qbit:config/qBittorrent.conf"
path_json="$(jq -cn --arg a "$FIXTURE_TMP/qbit-empty" --arg b "$FIXTURE_TMP/qbit:config" '[$a,$b]')"
if MEDI_JELLYFIN_DB='' MEDI_QBITTORRENT_PATHS_JSON="$path_json" \
  bash "$MEDIA_SCRIPTS/media-state.sh" export >/dev/null 2>&1 \
  && MEDI_SQLITE="$SQLITE" bash "$MEDIA_SCRIPTS/media-state.sh" verify --exports "$STATE" --health-dir "$HEALTH" >/dev/null 2>&1 \
  && [[ -s "$STATE/plain-qbit:config/qBittorrent.conf" && -d "$STATE/plain-qbit-empty" ]]; then
  ok 'fresh empty torrent data and nonempty config are both preserved via JSON paths'
else
  bad 'fresh torrent/config export lost state or split a colon-containing path'
fi
# An interrupted publish retains an old tree instead of removing it first.
mv "$STATE" "$STATE.previous"
mkdir -p "$STATE"
if MEDI_JELLYFIN_DB='' MEDI_QBITTORRENT_PATHS_JSON='["/nonexistent-audit-fixture"]' \
  bash "$MEDIA_SCRIPTS/media-state.sh" export >/dev/null 2>&1; then
  bad 'interrupted-publish fixture unexpectedly exported missing state'
elif [[ -s "$STATE/plain-qbit:config/qBittorrent.conf" && ! -e "$STATE.previous" ]]; then
  ok 'interrupted publish recovers the previous tree even after tmpfiles creates an empty target'
else
  bad 'interrupted publish lost the retained previous export'
fi

summary "state-restore"