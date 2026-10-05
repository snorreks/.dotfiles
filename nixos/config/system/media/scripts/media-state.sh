#!/usr/bin/env bash
# Durable application-consistent media exports. Never copy live SQLite raw.
set -euo pipefail
umask 0077
SQLITE="${MEDI_SQLITE:-sqlite3}"
STATE_DIR="${MEDI_STATE_DIR:-/var/lib/agent-ops/media-exports}"
HEALTH_DIR="${MEDI_HEALTH_DIR:-/var/lib/agent-ops}"
LOCK="${MEDI_LOCK:-${STATE_DIR}.lock}"
log() { printf '[media-state] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }
staging=''
restart_unit=''
cleanup() {
  local status=$?
  [[ -z "$staging" ]] || rm -rf -- "$staging"
  if [[ -n "$restart_unit" ]]; then
    systemctl start "$restart_unit" || status=1
  fi
  exit "$status"
}
trap cleanup EXIT

export_state() {
  local database="${MEDI_JELLYFIN_DB:-}" paths="${MEDI_QBITTORRENT_PATHS:-}"
  local unit="${MEDI_QBITTORRENT_UNIT:-}" source label result nonempty=0
  local plain_paths=()
  if [[ -n "${MEDI_QBITTORRENT_PATHS_JSON:-}" ]]; then
    jq -e 'type == "array" and all(.[]; type == "string" and startswith("/") and . != "/" and (index("\u0000") == null))' \
      <<<"$MEDI_QBITTORRENT_PATHS_JSON" >/dev/null || die 'invalid configured plain-state path list'
    mapfile -d '' -t plain_paths < <(jq -j '.[] + "\u0000"' <<<"$MEDI_QBITTORRENT_PATHS_JSON")
  elif [[ -n "$paths" ]]; then
    # Legacy operator/test interface; Nix-generated lists use JSON instead.
    IFS=: read -r -a plain_paths <<<"$paths"
  fi
  [[ -n "$database" || ${#plain_paths[@]} -gt 0 ]] || die 'no configured media state'
  local previous="$STATE_DIR.previous"
  if [[ -e "$previous" ]]; then
    # Recover an interrupted rename, including an empty directory re-created
    # by tmpfiles at boot. Never silently discard a retained old export.
    if [[ ! -e "$STATE_DIR" ]]; then
      mv -- "$previous" "$STATE_DIR"
    elif [[ -d "$STATE_DIR" && -z "$(find "$STATE_DIR" -mindepth 1 -print -quit)" ]]; then
      rmdir -- "$STATE_DIR"
      mv -- "$previous" "$STATE_DIR"
    else
      die "previous export retained at $previous; inspect both trees before retrying"
    fi
  fi
  if [[ -n "$unit" ]] && systemctl is-active --quiet "$unit"; then
    restart_unit="$unit"
    systemctl stop "$unit" || die "cannot quiesce $unit"
  fi
  if [[ -n "$database" ]]; then
    [[ -s "$database" ]] || die "configured database missing or empty: $database"
  fi
  for source in "${plain_paths[@]}"; do
    [[ "$source" != / && -e "$source" ]] || die "configured state missing or unsafe: $source"
  done
  mkdir -p -- "$(dirname -- "$STATE_DIR")"
  staging="$(mktemp -d "$STATE_DIR.new.XXXXXX")"
  if [[ -n "$database" ]]; then
    label="$(basename -- "$database")"
    # Fixed destination name makes verification independent of source extension.
    "$SQLITE" "$database" ".backup '$staging/library.db'" || die "sqlite .backup failed: not a database or backup error: $label"
    result="$("$SQLITE" "$staging/library.db" 'PRAGMA integrity_check;')"
    [[ "$result" == ok ]] || die "integrity_check failed: $result"
  fi
  for source in "${plain_paths[@]}"; do
    label="plain-$(basename -- "$source")"
    [[ ! -e "$staging/$label" ]] || die "duplicate export label: $label"
    cp -a -- "$source" "$staging/$label"
    if [[ -d "$staging/$label" ]]; then
      if [[ -n "$(find "$staging/$label" -type f -size +0c -print -quit)" ]]; then nonempty=$((nonempty + 1)); fi
      # A plain-state source may not smuggle raw SQLite into the backup tree.
      [[ -z "$(find "$staging/$label" \( -name '*.db' -o -name '*.sqlite*' -o -name '*-wal' -o -name '*-journal' \) -print -quit)" ]] || die "raw database in plain state: $source"
    else
      [[ -s "$staging/$label" ]] || die "empty state file: $source"
      nonempty=$((nonempty + 1))
    fi
  done
  [[ -n "$database" || "$nonempty" -gt 0 ]] || die 'empty state export'
  [[ ! -e "$STATE_DIR" ]] || mv -- "$STATE_DIR" "$previous"
  if ! mv -- "$staging" "$STATE_DIR"; then
    [[ ! -e "$previous" ]] || mv -- "$previous" "$STATE_DIR"
    die 'publishing export failed; previous export preserved'
  fi
  staging=''
  rm -rf -- "$previous"
  log 'export complete'
}
verify_state() {
  local exports="$1" health="$2" checked=0 plain=0 bad=0 nonempty=0 file result
  mkdir -p -- "$health"
  if [[ ! -d "$exports" ]]; then
    printf '{"mediaExport":"missing"}\n' >"$health/media-state.json"
    return 1
  fi
  for file in "$exports"/*.db; do
    [[ -e "$file" ]] || continue
    checked=$((checked + 1))
    result="$("$SQLITE" "$file" 'PRAGMA integrity_check;' 2>/dev/null || echo ERROR)"
    [[ "$result" == ok ]] || bad=$((bad + 1))
  done
  for file in "$exports"/plain-*; do
    [[ -e "$file" ]] || continue
    plain=$((plain + 1))
    if [[ -d "$file" ]]; then
      if [[ -n "$(find "$file" -type f -size +0c -print -quit)" ]]; then nonempty=$((nonempty + 1)); fi
    else
      if [[ -s "$file" ]]; then nonempty=$((nonempty + 1)); else bad=$((bad + 1)); fi
    fi
  done
  if ((checked + nonempty == 0)); then bad=$((bad + 1)); fi
  result=ok
  ((bad == 0)) || result=corrupt
  printf '{"mediaExport":"%s","checked":%d,"plain":%d,"bad":%d}\n' "$result" "$checked" "$plain" "$bad" >"$health/media-state.json"
  ((bad == 0))
}
mkdir -p -- "$(dirname -- "$LOCK")"
exec 9>"$LOCK"
flock 9
case "${1:-}" in
  export) export_state ;;
  verify)
    shift
    exports="$STATE_DIR" health="$HEALTH_DIR"
    while (($#)); do
      case "$1" in
        --exports) exports="$2"; shift 2 ;;
        --health-dir) health="$2"; shift 2 ;;
        *) die "unknown verify argument: $1" ;;
      esac
    done
    verify_state "$exports" "$health"
    ;;
  *) die 'usage: media-state.sh {export|verify [--exports DIR] [--health-dir DIR]}' ;;
esac
