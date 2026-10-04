#!/usr/bin/env bash
# nixos/config/system/media/scripts/media-offline-prep.sh
#
# Prepare a chosen set of media for travel, and refuse to claim it is ready
# when it is not.
#
# ── Scope, deliberately narrow ──────────────────────────────────────────────
# This copies files that are ALREADY in the library, which the operator has
# already chosen, into a cache the travel laptop can carry. It does not:
#
#   * fetch anything from the internet;
#   * start, stop or reconfigure any service;
#   * subscribe to anything, or talk to any external account;
#   * copy the whole library by default.
#
# That last one is the point. "Copy the library" is a multi-terabyte operation
# that fills the laptop's disk and then fails at 90%, which is the usual outcome
# and never a useful one. So the selector is required, and nothing is copied
# until it has been shown what would be copied and how big it is.
#
# 🔴 SYNCHRONISATION IS NOT A BACKUP. This script COPIES. The distinction is
# load-bearing for the offline cache in particular: a travel cache that is a
# Syncthing folder will PROPAGATE a deletion back to the library, so removing a
# file from the laptop while offline deletes it on the server. Restic is the
# backup; see docs/media-travel.md.
set -euo pipefail

CACHE_ROOT="${MEDI_TRAVEL_CACHE:?MEDI_TRAVEL_CACHE must be set (the cache root on this machine)}"
LIBRARY_ROOT="${MEDI_LIBRARY_ROOT:?MEDI_LIBRARY_ROOT must be set}"
DRY_RUN="${MEDI_DRY_RUN:-0}"
# Refuse to run when the cache is on a filesystem that cannot hold the set.
MIN_FREE_MB="${MEDI_MIN_FREE_MB:-512}"

log() { printf '[offline-prep] %s\n' "$*" >&2; }
die() {
  printf '[offline-prep] FATAL: %s\n' "$*" >&2
  exit 1
}

[[ -d "$CACHE_ROOT" ]] || die "cache root $CACHE_ROOT does not exist"
[[ -d "$LIBRARY_ROOT" ]] || die "library root $LIBRARY_ROOT does not exist"

# A relative selector is a path relative to the library; a leading slash is
# interpreted against the library root too, because the operator is thinking in
# terms of what Jellyfin shows them, not in terms of this script's cwd.
selectors=()
for arg in "$@"; do
  [[ -n "$arg" ]] || continue
  selectors+=("${arg#/}")
done

if ((${#selectors[@]} == 0)); then
  die "no items selected.
  Pass library-relative paths, e.g.:
    $0 'Films/Example (2024)/Example (2024).mkv'
This script never copies the whole library on its own."
fi

# ── Resolve every selector, and refuse to continue if any is missing ────────
#
# All-or-nothing, checked before any copying starts. A partial offline cache is
# the worst outcome: it is indistinguishable from a complete one until someone
# is on a plane, which is exactly when it cannot be fixed.
missing=()
selected=()
total_bytes=0

for rel in "${selectors[@]}"; do
  src="$LIBRARY_ROOT/$rel"
  if [[ ! -e "$src" ]]; then
    missing+=("$rel")
    continue
  fi
  if [[ -d "$src" ]]; then
    size="$(du -sb -- "$src" | cut -f1)"
  else
    size="$(stat -c %s -- "$src")"
  fi
  selected+=("$rel")
  total_bytes=$((total_bytes + size))
  printf '  %-70s %s\n' "$rel" "$(
    numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || printf '%s bytes' "$size"
  )" >&2
done

if ((${#missing[@]} > 0)); then
  log "these selectors do not exist under $LIBRARY_ROOT:"
  printf '    %s\n' "${missing[@]}" >&2
  die "refusing to prepare a partial cache"
fi

printf '\n%s item(s), %s total\n' \
  "${#selected[@]}" \
  "$(numfmt --to=iec-i --suffix=B "$total_bytes" 2>/dev/null || printf '%s bytes' "$total_bytes")" >&2

# ── Space check, before copying ─────────────────────────────────────────────
avail_kb="$(df -Pk -- "$CACHE_ROOT" | awk 'NR==2 {print $4}')"
need_kb=$(((total_bytes + 1024 * 1024 - 1) / 1024 / 1024))
if ((avail_kb < need_kb + MIN_FREE_MB * 1024)); then
  die "not enough room in $CACHE_ROOT.
  need ${need_kb} MiB + ${MIN_FREE_MB} MiB headroom, have $((avail_kb / 1024)) MiB free.
  The headroom is not optional: a full disk mid-copy leaves a cache that looks
  present and is not."
fi
log "space ok: $((avail_kb / 1024)) MiB free"

if [[ "$DRY_RUN" == "1" ]]; then
  log "MEDI_DRY_RUN=1 — reporting only, nothing copied"
  exit 0
fi

# ── Copy ────────────────────────────────────────────────────────────────────
#
# `cp -a` preserves mode and ownership, which matters because Jellyfin reads
# these as the `jellyfin` user. A cache copy that arrives unreadable produces a
# library that looks empty in the UI, and the cause is not obvious from inside
# Jellyfin.
for rel in "${selected[@]}"; do
  src="$LIBRARY_ROOT/$rel"
  dst="$CACHE_ROOT/$rel"
  mkdir -p -- "$(dirname -- "$dst")"
  if [[ -d "$src" ]]; then
    cp -a -- "$src" "$dst"
  else
    cp -a -- "$src" "$dst"
  fi
  log "copied $rel"
done

# ── Verify what landed, rather than trusting cp's exit status ───────────────
#
# cp returning 0 means it wrote what it was asked to write. It does not mean the
# result is readable by the service that will read it, which is the failure that
# actually happens.
log "verifying readability of the prepared cache"
unreadable=0
if [[ -n "${MEDI_MEDIA_USER:-}" ]]; then
  while IFS= read -r -d '' f; do
    if ! sudo -u "$MEDI_MEDIA_USER" test -r "$f" 2>/dev/null; then
      log "  NOT readable by $MEDI_MEDIA_USER: ${f#"$CACHE_ROOT"/}"
      unreadable=$((unreadable + 1))
    fi
  done < <(find "$CACHE_ROOT" -maxdepth 6 -type f -print0)
else
  log "  MEDI_MEDIA_USER unset — skipping the readability check"
fi

if ((unreadable > 0)); then
  die "$unreadable cached file(s) are not readable by ${MEDI_MEDIA_USER}.
  Copy with -a and set the cache group to match the media group, or Jellyfin
  will show a library full of items it cannot open."
fi

log "offline cache ready: ${#selected[@]} item(s) under $CACHE_ROOT"
log "remember: restic backs this up, Syncthing does not — a deletion on the"
log "          laptop propagates back to the server."
exit 0