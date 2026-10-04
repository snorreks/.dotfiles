#!/usr/bin/env bash
# nixos/config/system/media/scripts/media-state.sh
#
# Application-consistent export and verification of the media services' own
# state. Two subcommands:
#
#   export   sqlite3 .backup each live database into a durable export tree,
#            then integrity_check each result. Runs BEFORE the backup.
#   verify   confirm the exports exist, are non-empty and still pass
#            integrity_check. Runs AFTER a successful backup.
#
# ── Why this lane exports instead of using the backup lane's quiesce ────────
# The backup module already has a generic `quiesce` table that exports SQLite
# databases with `.backup` and then runs integrity_check, and using it would
# have been less code. It is not used, for one reason: the export produced here
# has to be DURABLE.
#
# The quiesce table exports into a staging directory that is created per run and
# removed afterwards — which is correct for "back this up right now" and wrong
# for "here is the state to restore", because nothing survives to be verified
# after the fact. A media library database is worth exactly as much as its last
# good copy, and a backup whose verification step has nothing to look at is a
# backup that cannot fail loudly.
#
# So this writes to a tree that outlives the run, registers it with
# agentOps.backup.sources, and `verify` re-checks it afterwards. One mechanism,
# and the thing being verified is the thing that was shipped.
#
# ── Why `.backup` and never `cp` ────────────────────────────────────────────
# `cp` of a database being written yields a file that passes integrity_check and
# is still corrupt: SQLite writes pages in place, so a copy taken mid-write is
# structurally valid and semantically wrong. `.backup` goes through the
# backup API, which takes a read lock for the duration and produces a
# transactionally consistent image.
#
# Corrupt is also worse than missing here, so a failed export is a HARD failure
# and an empty export directory is never left behind looking like success.
set -euo pipefail

SQLITE="${MEDI_SQLITE:-sqlite3}"
STATE_DIR="${MEDI_STATE_DIR:-/var/lib/agent-ops/media-exports}"
HEALTH_DIR="${MEDI_HEALTH_DIR:-/var/lib/agent-ops}"
LOCK="${MEDI_LOCK:-/run/lock/media-state.lock}"

log() { printf '[media-state] %s\n' "$*" >&2; }
die() {
  printf '[media-state] FATAL: %s\n' "$*" >&2
  exit 1
}

# `METHOD:PATH` pairs. Method is `sqlite` (backup API + integrity_check) or
# `plain` (a copy). They are not interchangeable: qBittorrent's state is a flat
# INI file and one file per torrent, not a database, and running `.backup` on it
# would fail; while Jellyfin's library index is a live SQLite database where a
# plain copy is exactly the corruption this script exists to prevent.
databases=()
plains=()

collect() {
  local jellyfin_db="${MEDI_JELLYFIN_DB:-}"
  local qbit_paths="${MEDI_QBITTORRENT_PATHS:-}"
  local p
  [[ -n "$jellyfin_db" && -e "$jellyfin_db" ]] && databases+=("$jellyfin_db")
  # Colon-separated so several paths can be given without an array, which a
  # systemd Environment= value cannot carry.
  if [[ -n "$qbit_paths" ]]; then
    local IFS=':'
    for p in $qbit_paths; do
      [[ -n "$p" && -e "$p" ]] && plains+=("$p")
    done
  fi
}

do_export() {
  command -v "$SQLITE" >/dev/null 2>&1 ||
    die "sqlite3 not found; refusing to copy databases raw."

  # One export at a time. Concurrent `.backup` against the same database is
  # safe but two exports writing the same destination is not.
  exec 9>"$LOCK"
  flock 9

  collect
  if ((${#databases[@]} == 0)); then
    # Nothing to export is a legitimate state (both services off), not an
    # error. Say so, so "the export dir is empty" is distinguishable from
    # "the export silently did not run".
    log "no media databases present on this machine; nothing to export"
    return 0
  fi

  # Build into a temporary tree and swap it in, so a crash mid-export cannot
  # leave a half-populated directory that `verify` would pass.
  local staging
  staging="$(mktemp -d "$STATE_DIR.new.XXXXXX")"
  # shellcheck disable=SC2064  # expand $staging NOW, not at trap time
  trap "rm -rf -- '$staging'" EXIT

  local entry src label dest
  for entry in "${databases[@]}"; do
    src="$entry"
    label="$(basename -- "$src")"
    dest="$staging/$label"
    log "exporting sqlite $src -> $label"
    if ! "$SQLITE" "$src" ".backup '$dest'"; then
      die "sqlite .backup failed for $src — NOT copying it raw.
A plain copy of a database being written is corrupt in a way that passes
integrity_check. Leaving the previous good export in place."
    fi
    local result
    result="$("$SQLITE" "$dest" 'PRAGMA integrity_check;' 2>/dev/null || echo ERROR)"
    if [[ "$result" != "ok" ]]; then
      die "the export of $src does not pass integrity_check (got: $result)"
    fi
  done

  for entry in "${plains[@]}"; do
    src="$entry"
    label="$(basename -- "$src")"
    # Prefixed so a plain copy can never be mistaken for an exported database
    # during a restore.
    dest="$staging/plain-$label"
    log "copying $src -> plain-$label"
    cp -a -- "$src" "$dest"
    if [[ ! -s "$dest" ]]; then
      die "copy of $src produced an empty file; refusing to record a success."
    fi
  done

  rm -rf -- "$STATE_DIR"
  mv -- "$staging" "$STATE_DIR"
  trap - EXIT
  log "export complete: ${#databases[@]} sqlite, ${#plains[@]} plain, in $STATE_DIR"
}

do_verify() {
  local exports="${1:-$STATE_DIR}"
  local health="${2:-$HEALTH_DIR}"
  local record="$health/media-state.json"

  # Created FIRST. The "missing" record below is the one an operator most needs
  # to see, and writing it into a directory that does not exist yet failed
  # silently — the missing report and the failure to write it look identical.
  mkdir -p "$health"

  # A missing export directory means the pre-backup export did not run, which
  # is a FAILURE of the backup's completeness, not a reason to pass quietly.
  if [[ ! -d "$exports" ]]; then
    log "FAIL: $exports does not exist — the media export did not run"
    printf '{"mediaExport":"missing"}\n' >"$record"
    return 1
  fi

  local checked=0
  local bad=0
  local f result
  for f in "$exports"/*.db; do
    [[ -e "$f" ]] || continue
    checked=$((checked + 1))
    result="$("$SQLITE" "$f" 'PRAGMA integrity_check;' 2>/dev/null || echo ERROR)"
    if [[ "$result" != "ok" ]]; then
      log "FAIL: $f does not pass integrity_check (got: $result)"
      bad=$((bad + 1))
    fi
  done

  # Plain copies get an existence-and-non-empty check. They cannot be
  # integrity-checked because they are not databases, and skipping them
  # silently would make the count below mean "verified N databases" when what
  # was really verified was "N databases and M files were present".
  local plain=0
  for f in "$exports"/plain-*; do
    [[ -e "$f" ]] || continue
    if [[ ! -s "$f" ]]; then
      log "FAIL: plain export $f is empty"
      bad=$((bad + 1))
    fi
    plain=$((plain + 1))
  done

  if ((bad > 0)); then
    printf '{"mediaExport":"corrupt","checked":%d,"plain":%d,"bad":%d}\n' \
      "$checked" "$plain" "$bad" >"$record"
    return 1
  fi

  # Written even when there was nothing to check: the useful distinction for an
  # operator is between "verified, and there was nothing to verify" and "never
  # ran".
  log "verified $checked database(s) and $plain plain export(s)"
  printf '{"mediaExport":"ok","checked":%d,"plain":%d}\n' "$checked" "$plain" >"$record"
  return 0
}

case "${1:-}" in
  export) do_export ;;
  verify)
    shift || true
    # Accept both "--exports DIR --health-dir DIR" and positional fallbacks, so
    # a hand-run of this script in a shell is as easy as the systemd call.
    exports="$STATE_DIR"
    health="$HEALTH_DIR"
    while (($#)); do
      case "$1" in
        --exports)
          exports="$2"
          shift 2
          ;;
        --health-dir)
          health="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    do_verify "$exports" "$health"
    ;;
  *)
    die "usage: media-state.sh {export|verify [--exports DIR] [--health-dir DIR]}"
    ;;
esac