#!/usr/bin/env bash
# ns-maint — the maintenance transaction for an unattended host.
#
# WHY THIS EXISTS (do not "simplify" any of it back into one command):
#
# The wrapper this replaces armed a 20-minute dead-man timer BEFORE it built,
# then rolled back by `systemctl reboot`. On a machine reached only over the
# tailnet that means a slow build reboots the server before activation has even
# started, and a nonzero activation exit was treated as "no new generation
# exists, nothing to revert" — while the pinned activation path had already run
# `switch-to-configuration test`, i.e. it had already reconfigured live units
# and only then failed to set the profile. Activation can therefore leave a
# half-applied runtime behind an *unchanged* profile, and that case is the one
# the old code declared safe.
#
# So the four things a human actually needs are now four separate commands:
#
#   prepare   build the exact selected host closure. Arms NOTHING. There is no
#             timeout that can fire during it, because nothing is armed, so a
#             build that takes six hours causes zero activation and zero
#             rollback. The candidate is pinned with a GC root.
#   activate  arm the deadline immediately before mutation, record what the
#             machine looks like right now, then hand activation to a system
#             service that does not care whether the caller is still connected.
#   confirm   bind the operator's yes to ONE transaction id, and require
#             evidence that a NEW client connection got in after the switch.
#             A surviving old SSH socket proves nothing.
#   stage / reboot   boot maintenance, always a separate, explicit operation.
#
# Nothing in this file reboots the machine except `ns-maint reboot`, which
# takes --yes and is reached only by a human. Recovery is live: it restores the
# profile and boot intent and re-activates the old closure *without* rebooting.
#
# A live switch cannot load a new kernel, so a candidate that carries a
# different kernel than the running closure is refused for live activation and
# must be staged instead.
#
# State is one atomically-replaced record (see record_* below). Every command
# that mutates it takes an exclusive lock first, so two transactions can never
# interleave, and a confirmation for txid N can never land on txid N+1.

set -o errexit -o nounset -o pipefail
export LC_ALL=C

# ── Deployment-overridable inputs ────────────────────────────────────────────
#
# Every external command and every absolute path is read from an NM_* variable
# so the failure-injection suite in nixos/tests can point the whole state
# machine at a temporary root with fakes on PATH. In production these are set by
# config/system/maintenance.nix (compile-time defaults) and nothing else; the
# suite is the only thing that overrides them.
NM_DIR="${NM_DIR:-/var/lib/nixos/maintenance}"
# TEST ONLY. Production always validates against /nix/store. The failure-injection
# suite cannot create directories there, so it points this at a disposable prefix
# and exercises the SAME validation: the 32-character hash, the name charset, and
# the absence of anything that could be a path traversal all still have to hold.
NM_STORE_PREFIX="${NM_STORE_PREFIX:-/nix/store}"
NM_GCROOTS="${NM_GCROOTS:-/nix/var/nix/gcroots}"
NM_PROFILE="${NM_PROFILE:-/nix/var/nix/profiles/system}"
NM_CURRENT_SYSTEM="${NM_CURRENT_SYSTEM:-/run/current-system}"
NM_BOOTED_SYSTEM="${NM_BOOTED_SYSTEM:-/run/booted-system}"
NM_FLAKE="${NM_FLAKE:-}"
NM_HOST="${NM_HOST:-}"
NM_NIX="${NM_NIX:-nix}"
NM_NIX_STORE="${NM_NIX_STORE:-nix-store}"
NM_ENV="${NM_ENV:-nix-env}"
NM_SYSTEMCTL="${NM_SYSTEMCTL:-systemctl}"
NM_SYSTEMD_RUN="${NM_SYSTEMD_RUN:-systemd-run}"
NM_SUDO="${NM_SUDO:-sudo}"
NM_SWITCH_TO_CONFIGURATION="${NM_SWITCH_TO_CONFIGURATION:-}"
NM_REBOOT_CMD="${NM_REBOOT_CMD:-systemctl reboot}"
# Deadline watchdog period, and the default confirmation window. Both are
# overridable so tests do not have to wait minutes.
NM_TICK_SECONDS="${NM_TICK_SECONDS:-30}"
NM_DEFAULT_TIMEOUT="${NM_DEFAULT_TIMEOUT:-20min}"
NM_RESTORE_TIMEOUT="${NM_RESTORE_TIMEOUT:-10min}"
# TEST ONLY. Lets the failure-injection suite drive the real state machine as
# an unprivileged user, because production requires uid 0 for every mutation.
# It changes nothing about the logic under test; see require_privileged below.
NM_TEST_MODE="${NM_TEST_MODE:-0}"

RECORD_FILE="$NM_DIR/record.env"
LOCK_FILE="$NM_DIR/lock"
LOG_FILE="$NM_DIR/log"

# ── Small helpers ───────────────────────────────────────────────────────────
progname() { printf 'ns-maint'; }
say() { printf '%s\n' "$*"; }
sayf() { printf '%s: %s\n' "$(progname)" "$*" >&2; }
die() {
  sayf "$*"
  exit 1
}
now_epoch() { date +%s; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log_event() {
  local msg="$*"
  mkdir -p "$NM_DIR"
  printf '%s [%s] %s\n' "$(iso_now)" "${LOG_FILE}" "$msg" >>"$LOG_FILE" 2>/dev/null || true
  # Also into the journal so the event is visible without an SSH session.
  if command -v logger >/dev/null 2>&1; then
    logger -t ns-maint -- "$msg" 2>/dev/null || true
  fi
}

# require_privileged — every mutating entry point calls this first.
#
# Mutating the transaction record, switching a profile or running activation
# are all root operations. NM_TEST_MODE exists because the failure-injection
# suite has to drive this same code path unprivileged; it is not a way to make
# a deployed copy of the script permissive, because in production NM_DIR is
# created root-owned and mode 0755 by maintenance.nix, so an unprivileged
# caller cannot get past the lock file either.
require_privileged() {
  if [[ "$(id -u)" -eq 0 || "$NM_TEST_MODE" == "1" ]]; then
    return 0
  fi
  die "this operation changes system state and must run as root (or via sudo)."
}

# ── Store-path / field validation ───────────────────────────────────────────
#
# A record can only be trusted if every field in it is validated on read: a
# corrupt or hand-edited record must never be able to smuggle a path into
# `switch-to-configuration` or a shell word into a command line.
# The prefix is interpolated into a regex rather than escaped, so it is
# CONSTRAINED instead: only the characters a real prefix is made of. Production
# uses /nix/store. The failure-injection suite uses a mktemp path, whose only
# "unusual" character is the dot, and a dot matches itself, so nothing loosens.
case "$NM_STORE_PREFIX" in
*[!A-Za-z0-9._/-]*)
  printf 'ns-maint: NM_STORE_PREFIX may only contain [A-Za-z0-9._/-], got %s\n' "$NM_STORE_PREFIX" >&2
  exit 78
  ;;
esac
STORE_PATH_RE="^${NM_STORE_PREFIX}/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+\$"
TXID_RE='^tx-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$'
HOSTNAME_RE='^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$'
PHASES=(idle prepared staging staged stage-interrupted armed activating awaiting-confirm restoring restored
  restore-failed confirmed aborted reconciled-booted reconciled-not-applied)

valid_store_path() { [[ "$1" =~ $STORE_PATH_RE ]]; }
valid_txid() { [[ "$1" =~ $TXID_RE ]]; }
valid_hostname() { [[ "$1" =~ $HOSTNAME_RE ]]; }
valid_operation() { [[ "$1" == "activate" || "$1" == "stage" ]]; }
valid_phase() {
  local p
  for p in "${PHASES[@]}"; do
    [[ "$p" == "$1" ]] && return 0
  done
  return 1
}
valid_integer() { [[ "$1" =~ ^-?[0-9]+$ ]]; }

# ── EFI space ────────────────────────────────────────────────────────────────
#
# Staging a boot means writing a kernel, an initrd and a boot entry to a FAT
# partition that is SHARED WITH WINDOWS and is usually small. Writing there is
# not atomic with respect to running out of room: the entry is written, and then
# the copy fails part-way, and `switch-to-configuration boot` fails — which on a
# machine reached only over the tailnet is an hour of guessing.
#
# So `stage` checks first. `df` needs no privilege to statvfs, so this is a
# plain read.
#
# NM_ESP_PATH is where the ESP is mounted (/boot here). NM_ESP_MIN_MIB is the
# floor: one NixOS entry with its kernel and initrd is tens of MiB, so 150 MiB
# leaves room for the entry being written now plus one more replacement.
NM_ESP_PATH="${NM_ESP_PATH:-/boot}"
NM_ESP_MIN_MIB="${NM_ESP_MIN_MIB:-150}"
NM_DF="${NM_DF:-df}"

esp_free_mib() {
  "$NM_DF" -P -k "$NM_ESP_PATH" 2>/dev/null | awk 'NR==2 { if ($4 !~ /^[0-9]+$/) exit 1; printf "%d", $4 / 1024 }'
}

esp_preflight() {
  local free
  if ! free="$(esp_free_mib)" || [[ ! "$free" =~ ^[0-9]+$ ]]; then
    sayf "stage: could not verify free space on $NM_ESP_PATH; refusing bootloader writes."
    return 1
  fi
  [[ "$NM_ESP_MIN_MIB" =~ ^[0-9]+$ ]] || die "invalid ESP minimum-space policy"
  if ((free < NM_ESP_MIN_MIB)); then
    sayf "stage: $NM_ESP_PATH has ${free} MiB free, and this stage needs at least"
    sayf "       ${NM_ESP_MIN_MIB} MiB for the kernel, the initrd and the boot entry."
    sayf "       Refusing to start: a half-written ESP entry is worse than none,"
    sayf "       because it is not obvious afterwards which entry is the good one."
    sayf ""
    sayf "       Reclaim space (this keeps the CURRENT boot and its profile):"
    sayf "         bootctl cleanup                  # entries no profile references"
    sayf "         nixos-rebuild boot               # reinstall the profile's entry"
    sayf "       If the ESP is full because of something other than stale NixOS"
    sayf "       entries, that is a disk problem, and 'bootCounting' in"
    sayf "       config/system/boot.nix is where the entry limit lives."
    return 1
  fi
  sayf "stage: ESP has ${free} MiB free on $NM_ESP_PATH (floor ${NM_ESP_MIN_MIB} MiB)"
  return 0
}

# PENDING_PHASES are the phases in which a transaction still owns the machine:
# a confirmation or a deadline is outstanding, or a restore is mid-flight.
PENDING_PHASES=(staging stage-interrupted armed activating awaiting-confirm restoring)

is_pending_phase() {
  local want="$1" p
  for p in "${PENDING_PHASES[@]}"; do
    [[ "$p" == "$want" ]] && return 0
  done
  return 1
}

# ── The record ──────────────────────────────────────────────────────────────
#
# A flat key=value file with a closed schema. Written by writing a sibling temp
# file and renaming it into place, so a reader never observes a half-written
# record and a crash mid-write cannot leave one. Deliberately NOT json: the
# schema is fixed and every value is a single scalar, and a hand-rolled JSON
# parser in bash is a much larger attack surface than a strict line format.
#
# schema_version — bumped if the field set changes incompatibly.
# phase         — see PHASES above.
# txid          — unique id of the transaction that owns this record. A
#                 confirmation carrying a different txid can never confirm this
#                 one.
# host          — the host this record was created for; a record whose host
#                 does not match the configured host is refused outright rather
#                 than acted on.
# operation     — "activate" | "stage". Nothing else is accepted.
# candidate     — store path of the closure being moved to.
# old_running   — /run/current-system target at arm time (the recovery closure).
# old_profile   — raw readlink of the system profile at arm time.
# old_gen       — generation number parsed out of old_profile.
# booted        — /run/booted-system target at arm time. Deliberately separate
#                 from old_running: they differ whenever a live switch has
#                 happened, and conflating them is how "the profile still looks
#                 fine" becomes mistaken for "the machine is fine".
# deadline      — epoch seconds after which the restore is due.
# armed_at      — epoch seconds the mutation window opened.
# activated_at  — APPLY completion time. NEW-connection evidence must be later.
# restore_*     — outcome of the last restore attempt, reported verbatim.
RECORD_KEYS=(schema_version phase txid host operation candidate old_running
  old_profile old_profile_closure old_gen booted deadline armed_at activated_at restore_result
  restore_detail staged_candidate confirmed_at confirm_peer confirm_connection
  health_failed_units health_checked_at reconciled_at note)

declare -A RECORD=()

record_defaults() {
  local k
  for k in "${RECORD_KEYS[@]}"; do RECORD["$k"]=""; done
  RECORD["profile_resolution_error"]=""
  RECORD["schema_version"]="1"
  RECORD["phase"]="idle"
}

record_file_exists() { [[ -f "$RECORD_FILE" ]]; }

record_load() {
  record_defaults
  if [[ -d "$NM_DIR" && ( ! -r "$NM_DIR" || ! -x "$NM_DIR" ) ]]; then
    die "maintenance state is inaccessible; run sudo ns-maint status."
  fi
  if [[ -e "$RECORD_FILE" && ! -r "$RECORD_FILE" ]]; then
    die "maintenance record is unreadable; run sudo ns-maint status."
  fi
  if ! record_file_exists; then
    return 0
  fi
  local line key value
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      die "record is corrupt (line without '='): $line"
    fi
    key="${line%%=*}"
    value="${line#*=}"
    local known=0 k
    for k in "${RECORD_KEYS[@]}"; do
      [[ "$k" == "$key" ]] && known=1 && break
    done
    [[ "$known" -eq 1 ]] || die "record contains unknown key '$key'"
    # No newlines or NULs are representable in this format by construction.
    [[ "$value" != *$'\n'* ]] || die "record value for '$key' contains a newline"
    RECORD["$key"]="$value"
  done <"$RECORD_FILE"
  record_validate
  resolve_recorded_profile || true
}

# record_validate — refuse to act on anything we cannot vouch for.
#
# The three classes that matter: a wrong/unknown phase, a record belonging to a
# different host, and a store path that is not a store path. All three turn a
# recoverable situation into an unrecoverable one if executed, so they are hard
# errors with an explicit repair hint rather than warnings.
record_validate() {
  local v
  v="${RECORD[schema_version]}"
  [[ "$v" == "1" ]] || die "record schema_version '$v' is not supported by this ns-maint; remove $RECORD_FILE after reading it."

  v="${RECORD[phase]}"
  valid_phase "$v" || die "record phase '$v' is not a known phase; refusing to act on it."

  if [[ -n "${RECORD[txid]}" ]]; then
    valid_txid "${RECORD[txid]}" || die "record txid '${RECORD[txid]}' is malformed."
  fi

  if [[ -n "${RECORD[host]}" ]]; then
    valid_hostname "${RECORD[host]}" || die "record host '${RECORD[host]}' is malformed."
    if [[ -n "$NM_HOST" && "${RECORD[host]}" != "$NM_HOST" ]]; then
      die "record belongs to host '${RECORD[host]}' but this is '${NM_HOST}'. Copy $RECORD_FILE aside and remove it before running maintenance here."
    fi
  fi

  if [[ -n "${RECORD[operation]}" ]]; then
    valid_operation "${RECORD[operation]}" || die "record operation '${RECORD[operation]}' is not an accepted operation."
  fi

  local p
  for p in candidate old_running old_profile_closure booted staged_candidate; do
    v="${RECORD[$p]}"
    if [[ -n "$v" ]]; then
      valid_store_path "$v" || die "record $p '$v' is not a Nix store path; refusing to use it."
    fi
  done

  for p in deadline armed_at activated_at confirmed_at health_checked_at reconciled_at old_gen; do
    v="${RECORD[$p]}"
    if [[ -n "$v" ]]; then
      valid_integer "$v" || die "record $p '$v' is not an integer timestamp."
    fi
  done
}

# record_save — atomic replace. Temp file in the SAME directory so the rename is
# a same-filesystem rename(2), which is atomic; the caller holds the lock.
record_save() {
  mkdir -p "$NM_DIR"
  local tmp k
  tmp="$(mktemp "$NM_DIR/.record.XXXXXX")"
  {
    printf '# ns-maint transaction record — written by ns-maint, do not hand-edit.\n'
    printf '# Delete this file only after reading it: it is the record of what was\n'
    printf '# armed and whether it was confirmed or restored.\n'
    for k in "${RECORD_KEYS[@]}"; do
      # Derived in memory; version 1 readers have a closed wire schema.
      [[ "$k" == old_profile_closure ]] && continue
      printf '%s=%s\n' "$k" "${RECORD[$k]}"
    done
  } >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$RECORD_FILE"
}

# ── Locking ─────────────────────────────────────────────────────────────────
#
# Every mutating command and the deadline tick take the same exclusive lock.
# That single lock is what serialises transactions, what makes the confirm-vs-
# deadline race decidable (whoever holds it first wins, and the loser is told
# so), and what makes a second concurrent activation a clean refusal rather
# than a corrupted record.
#
# Re-entrant on purpose: the deadline tick and the operator's abort both call
# do_restore while already holding it. flock() locks the open file description,
# so a second open+flock from the same process would fail — the restore would
# report "another operation holds the lock" about itself.
#
# WHY LOCK CONTENTION IS NOT UNIFORMLY FATAL
#
# lock_acquire exits 75 when the lock is held. That is right for an operator
# running a mutating command: 75/TEMPFAIL tells them to retry, and nothing was
# changed. It is WRONG for `tick` and `reconcile`, which systemd runs on timers
# and at multi-user.target rather than at an operator's request. Those two are
# re-triggered by `switch-to-configuration` on every single activation, because
# starting an active target re-pulls every Wants= unit of that target and both
# units are oneshots that are therefore always inactive. So an ns-maint-driven
# activation — which holds this very lock from arm to confirm — restarts
# `ns-maint reconcile`, which cannot take the lock, which exits 75, which
# switch-to-configuration reports as a failed unit, which it turns into exit 4,
# which ns-maint reads as "activation failed" and answers with a full rollback.
# The rollback re-activates the old closure, which re-triggers the same unit,
# which fails identically, so the restoration cannot complete either.
#
# Nothing is lost by deferring instead: the watchdog fires again on its next
# tick, and reconcile runs again at the next boot. What is lost by NOT
# deferring is every activation on this host. Hence the --defer form below,
# used only by the two commands that are classifiers rather than transactions.
#
LOCK_FD=
LOCK_DEPTH=0

# lock_acquire [--defer] — take the lock.
#
# Without --defer, a busy lock exits 75: a command an operator ran by hand must
# tell them to retry. With --defer it returns 1 instead and the caller decides,
# and the only two callers that pass it are the commands systemd starts on a
# timer or at boot. Their whole contract is
# `if ! lock_acquire --defer; then <report>; return 0; fi` — report the
# contention, exit successfully, and let the next tick or boot do the work.
lock_acquire() {
  local defer=0
  if [[ "${1-}" == "--defer" ]]; then
    defer=1
  elif [[ $# -gt 0 ]]; then
    die "lock_acquire: unknown argument '$1'"
  fi
  if [[ "$LOCK_DEPTH" -gt 0 ]]; then
    LOCK_DEPTH=$((LOCK_DEPTH + 1))
    return 0
  fi
  mkdir -p "$NM_DIR"
  exec {LOCK_FD}>"$LOCK_FILE"
  if ! flock -n "$LOCK_FD"; then
    say "another ns-maint operation holds the lock; retry once it finishes."
    if [[ "$defer" -eq 1 ]]; then
      return 1
    fi
    exit 75
  fi
  LOCK_DEPTH=1
}

# lock_release — drop the lock explicitly.
#
# Needed at exactly one place: `activate` has to hand off to a system service,
# and an inherited lock descriptor would follow into that service's process and
# make it conclude that "another ns-maint operation" holds the lock — which
# would be itself. systemd would not inherit it, but a shell started as a child
# does, and the test harness exercises exactly that path.
lock_release() {
  if [[ "$LOCK_DEPTH" -gt 0 ]]; then
    exec {LOCK_FD}>&- 2>/dev/null || true
    LOCK_FD=
    LOCK_DEPTH=0
  fi
}

# ── GC roots ────────────────────────────────────────────────────────────────
#
# Generation retention is not enough: a daemon can be running from a closure
# that no generation points at any more, and a candidate that was built but not
# yet activated has no generation either. So every closure a transaction might
# still need is pinned with an indirect GC root rather than merely kept alive by
# generation numbering.
#
# nix only honours roots it can FIND, and it finds symlinks under
# <stateDir>/gcroots (plus the auto/ subdirectory). `nix-store --add-root` with
# a bare name writes there, but only if the name is resolved from inside that
# directory — pass a path and it lands wherever you ran it from, which silently
# protects nothing. Hence the explicit cd, and hence gc_roots_list existing to
# show an operator exactly what is pinned.
gc_root_name() { printf 'ns-maint-%s' "$1"; }

gc_protect() {
  local name="$1" path="$2"
  valid_store_path "$path" || die "gc_protect: '$path' is not a store path"
  mkdir -p "$NM_GCROOTS"
  # -r realises it if it somehow is not present, so the root cannot dangle.
  (cd "$NM_GCROOTS" && "$NM_NIX_STORE" --add-root "$(gc_root_name "$name")" --realise "$path")
  log_event "gc root $(gc_root_name "$name") -> $path"
}

# Immutable transaction-specific anchor: generic roots may be replaced by later GC.
profile_anchor() {
  valid_txid "${RECORD[txid]}" || die "profile anchor requires a valid txid"
  printf '%s/%s' "$NM_GCROOTS" "$(gc_root_name "profile-${RECORD[txid]}")"
}

protect_recorded_profile() {
  local root
  root="$(profile_anchor)"
  if [[ -e "$root" || -L "$root" ]]; then
    [[ "$(readlink "$root")" == "${RECORD[old_profile_closure]}" ]] || die "profile anchor conflict"
    return 0
  fi
  gc_protect "profile-${RECORD[txid]}" "${RECORD[old_profile_closure]}"
}

# Never consult the mutable system profile when reading a transaction. The
# captured generation and the immutable anchor must agree; a persisted derived
# field from an intermediate writer is only a consistency hint.
resolve_recorded_profile() {
  local target="${RECORD[old_profile]}" gen="${RECORD[old_gen]}"
  local hint="${RECORD[old_profile_closure]}" closure="" anchor="" root="" link=""
  RECORD[old_profile_closure]=""
  RECORD[profile_resolution_error]=""
  if [[ -z "$target" ]]; then
    [[ -z "$gen$hint" ]] || die "absent recorded profile has generation or closure"
    return 0
  fi
  if valid_store_path "$target"; then
    [[ -z "$gen" ]] || die "direct recorded profile has a generation"
    closure="$target"
  else
    [[ "$gen" =~ ^[1-9][0-9]*$ ]] || die "recorded profile has no positive matching generation"
    link="${NM_PROFILE}-${gen}-link"
    [[ "$target" == "${link##*/}" || "$target" == "$link" ]] || die "recorded profile path does not match old_gen"
    if [[ -e "$link" || -L "$link" ]]; then
      closure="$(readlink "$link" 2>/dev/null || true)"
      valid_store_path "$closure" || die "recorded generation target is corrupt"
      [[ -d "$closure" ]] || closure=""
    fi
  fi
  if [[ -n "${RECORD[txid]}" ]]; then
    root="$(profile_anchor)"
    if [[ -e "$root" || -L "$root" ]]; then
      anchor="$(readlink "$root" 2>/dev/null || true)"
      valid_store_path "$anchor" || die "recorded profile anchor is corrupt"
      [[ -d "$anchor" ]] || anchor=""
    fi
  fi
  if [[ -n "$closure" && -n "$anchor" && "$closure" != "$anchor" ]]; then
    die "recorded profile generation and anchor conflict"
  fi
  closure="${closure:-$anchor}"
  if [[ -n "$hint" && -n "$closure" && "$hint" != "$closure" ]]; then
    die "recorded profile closure hint conflicts with captured intent"
  fi
  if [[ -z "$closure" ]]; then
    RECORD[profile_resolution_error]="recorded profile generation and transaction anchor are missing"
    return 1
  fi
  RECORD[old_profile_closure]="$closure"
}

gc_unprotect() {
  local name="$1"
  local root
  root="$NM_GCROOTS/$(gc_root_name "$name")"
  rm -f "$root" "$root.link"
  log_event "gc root $(gc_root_name "$name") released"
}

gc_roots_list() {
  local root name
  for root in "$NM_GCROOTS"/ns-maint-*; do
    [[ -e "$root" || -L "$root" ]] || continue
    name="${root##*/}"
    printf '%-40s %s\n' "$name" "$(readlink -f "$root" 2>/dev/null || echo '(unreadable)')"
  done
}

# ── Observing the machine ───────────────────────────────────────────────────
readlink_target() {
  # Prints the raw link target ('' if there is no link). Never -f: we want to
  # record what the symlink says, and we validate it separately.
  if [[ -L "$1" ]]; then
    readlink "$1"
  else
    printf ''
  fi
}

# These three answer DIFFERENT questions and must not be conflated:
#
#   current_closure  what the running system is          (/run/current-system)
#   booted_closure   what the running KERNEL is           (/run/booted-system)
#   profile_target   the raw link NAME of the profile, e.g. "system-852-link"
#   profile_closure  which closure that profile name resolves to
#
# The profile's raw target is a generation NAME, not a store path — which is
# exactly why `old_profile` is recorded raw (so the generation can be switched
# back to by number) while every health comparison uses profile_closure. Reading
# "the profile still points where it always did" as "nothing changed" is the
# mistake this separation exists to prevent.
current_closure() { readlink -f "$NM_CURRENT_SYSTEM" 2>/dev/null || printf ''; }
booted_closure() { readlink -f "$NM_BOOTED_SYSTEM" 2>/dev/null || printf ''; }
profile_target() { readlink_target "$NM_PROFILE"; }
profile_closure() { readlink -f "$NM_PROFILE" 2>/dev/null || printf ''; }

# Parse "system-852-link" into 852. Empty when the profile is not a generation
# link, which is a legitimate state (a profile symlinked straight at a store
# path) and is reported rather than assumed.
generation_of() {
  local link="$1" gen
  [[ -n "$link" ]] || {
    printf ''
    return 0
  }
  if [[ "$link" == "${NM_PROFILE}-"* ]]; then
    link="${link##*/}"
  fi
  gen="${link#"${NM_PROFILE##*/}"-}"
  gen="${gen%-link}"
  if [[ "$gen" =~ ^[1-9][0-9]*$ && "$link" == "${NM_PROFILE##*/}-${gen}-link" ]]; then
    printf '%s' "$gen"
  else
    printf ''
  fi
}

new_txid() {
  printf 'tx-%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
}

# ── Kernel / driver sensitivity ─────────────────────────────────────────────
#
# A live switch CANNOT load a new kernel: the running kernel is the one the
# machine booted, and switch-to-configuration reconfigures services and writes
# a bootloader entry. So a candidate whose kernel differs from the running
# closure's is not "an update you should confirm", it is an update that needs a
# reboot — and one whose activation may well FAIL, because the userspace NVIDIA
# library will not match the still-loaded kernel module. That failure is exactly
# the "Driver/library version mismatch" the kernel-bump skill is about.
#
# Comparing the resolved aggregate module store paths catches both kernel and
# out-of-tree driver changes, even when their kernel version names are identical. Unknown (a closure we cannot inspect) is
# treated as dirty rather than clean: refusing costs a flag, guessing costs an
# unreachable server.
kernel_signature() {
  local closure="$1"
  if [[ -z "$closure" ]]; then
    printf 'unknown'
    return 0
  fi
  local modules
  modules="$(readlink -e "$closure/kernel-modules" 2>/dev/null || true)"
  if ! valid_store_path "$modules" || [[ ! -d "$modules/lib/modules" ]]; then
    printf 'unknown'
    return 0
  fi
  printf '%s' "$modules"
}

kernel_is_dirty() {
  local candidate="$1" running="$2"
  case "$(kernel_signature "$candidate")" in
  unknown) return 0 ;;
  esac
  case "$(kernel_signature "$running")" in
  unknown) return 0 ;;
  esac
  [[ "$(kernel_signature "$candidate")" != "$(kernel_signature "$running")" ]]
}

# ── Local health evidence ───────────────────────────────────────────────────
#
# Collected automatically at confirm time and stored in the record, so a later
# reader can see what was actually true when the operator said yes. Deliberately
# a count plus a short list rather than a full journal dump: this record ends up
# in a backup and in a PR description.
collect_health() {
  local failed=0 out=""
  if out="$("$NM_SYSTEMCTL" --failed --no-legend --plain 2>/dev/null)"; then
    failed="$(printf '%s' "$out" | grep -c . || true)"
  else
    failed=-1
  fi
  RECORD["health_failed_units"]="$failed"
  RECORD["health_checked_at"]="$(now_epoch)"
}

# ── Rendering ───────────────────────────────────────────────────────────────
record_get() { printf '%s' "${RECORD[$1]-}"; }

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

render_json() {
  printf '{'
  local first=1 k
  for k in "${RECORD_KEYS[@]}"; do
    [[ "$first" -eq 1 ]] || printf ','
    first=0
    printf '"%s":"%s"' "$k" "$(json_escape "${RECORD[$k]-}")"
  done
  printf '}\n'
}

render_human() {
  local k v
  say "ns-maint status"
  if [[ -z "${RECORD[txid]}" && "${RECORD[phase]}" == "idle" ]]; then
    say "  no transaction has ever run here."
  fi
  for k in phase txid host operation candidate old_running booted old_profile \
    old_gen deadline armed_at staged_candidate restore_result confirm_peer \
    confirm_connection health_failed_units health_checked_at reconciled_at note; do
    v="${RECORD[$k]-}"
    [[ -n "$v" ]] || continue
    if [[ "$k" == "deadline" || "$k" == "armed_at" || "$k" == "activated_at" || "$k" == "confirmed_at" || "$k" == "health_checked_at" || "$k" == "reconciled_at" ]]; then
      v="$v ($(date -u -d "@$v" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?'))"
    fi
    printf '  %-20s %s\n' "$k" "$v"
  done
  local pending_root
  for pending_root in "$NM_GCROOTS"/ns-maint-*; do
    [[ -e "$pending_root" || -L "$pending_root" ]] || continue
    printf '  %-20s %s\n' "${pending_root##*/}" "$(readlink -f "$pending_root" 2>/dev/null || echo '(unreadable)')"
  done
}

cmd_status() {
  local as_json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --json) as_json=1 ;;
    -h | --help)
      say "usage: ns-maint status [--json]"
      return 0
      ;;
    *) die "status: unknown argument '$1'" ;;
    esac
    shift
  done
  record_load
  if [[ "$as_json" -eq 1 ]]; then render_json; else render_human; fi
}

# ── prepare ─────────────────────────────────────────────────────────────────
#
# Builds one exact closure and pins it. Arms nothing: there is no deadline, no
# record phase that can restore, and no unit that can run. A build that runs
# past any timeout the operator was told about simply finishes building.
#
# Input updates are NOT implicit. `--update-input NAME` updates exactly one
# named flake input and re-records the lock; `--update-all` is refused outright
# on the reasoning that an unattended host's whole input set should never move
# in one unreviewed step.
cmd_prepare() {
  require_privileged
  local host="" flake="" offline=0 update_input="" build_timeout=0 tag=""
  local output=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --host)
      host="$2"
      shift 2
      ;;
    --flake)
      flake="$2"
      shift 2
      ;;
    --offline) offline=1; shift ;;
    --online) offline=0; shift ;;
    --build-timeout)
      build_timeout="$2"
      shift 2
      ;;
    --update-input)
      update_input="$2"
      shift 2
      ;;
    --update-all) die "prepare --update-all is refused: on an unattended host an
              unreviewed all-input bump is the failure mode this tool exists to
              prevent. Name the input you mean:
                ns-maint prepare --update-input nixpkgs" ;;
    --tag)
      tag="$2"
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    -h | --help)
      usage
      return 0
      ;;
    *) die "prepare: unknown argument '$1'" ;;
    esac
  done

  host="${host:-$NM_HOST}"
  flake="${flake:-$NM_FLAKE}"
  [[ -n "$host" ]] || die "prepare: no host selected (--host, or NM_HOST from the deployed configuration)"
  valid_hostname "$host" || die "prepare: '$host' is not a valid hostname"
  [[ -n "$flake" ]] || die "prepare: no flake directory (--flake, or NM_FLAKE from the deployed configuration)"
  if [[ -n "$output" ]]; then
    valid_hostname "$output" || die "prepare: --output '$output' is not a valid flake output name"
    sayf "prepare: NOTE — building output '$output', not the host's default."
    sayf "         Flake outputs are separate closures. Building $output-fast does not"
    sayf "         change this host until it is activated, and activating it WILL apply"
    sayf "         whatever that output leaves out (for $host-fast: ollama-cuda)."
  fi

  lock_acquire
  record_load

  if is_pending_phase "${RECORD[phase]}"; then
    die "a transaction is already ${RECORD[phase]} (txid ${RECORD[txid]}). Finish or abort it first:
             ns-maint status
             ns-maint confirm ${RECORD[txid]}     # if the new build is good
             ns-maint abort                      # to restore the old closure"
  fi

  # --output selects a different flake output (e.g. "$host-fast") while the
  # record's `host` stays the real hostname, so host validation is unaffected.
  local attr="nixosConfigurations.${output:-$host}.config.system.build.toplevel"
  local -a nix_args=(build --no-link --print-out-paths)
  [[ "$offline" -eq 1 ]] && nix_args+=(--offline)

  if [[ -n "$update_input" ]]; then
    # A flake input name is an attribute-path element, not an arbitrary word.
    # Constraining it here also stops a leading dash from being read as an
    # OPTION by nix (e.g. --update-input --all would otherwise re-request the
    # blanket update this command refuses to do).
    [[ "$update_input" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
      die "prepare: '--update-input $update_input' is not a flake input name (use e.g. nixpkgs)"
    say "prepare: updating exactly ONE flake input ($update_input) — this rewrites $flake/flake.lock"
    say "prepare: review the lock diff before activating anything."
    # `nix flake update [option...] inputs...` — every POSITIONAL argument is an
    # INPUT NAME. The flake itself is selected by --flake. Passing the flake
    # positionally (the obvious reading of "update <flake> <input>") makes nix
    # resolve the path as an input attribute and fail with
    #   error: invalid flake input attribute path element '.dotfiles'
    # which says nothing about what was wrong.
    local update_rc=0
    "$NM_NIX" --extra-experimental-features 'nix-command flakes' \
      flake update --flake "$flake" "$update_input" || update_rc=$?
    if [[ "$update_rc" -ne 0 ]]; then
      die "prepare: updating input '$update_input' in $flake failed (exit $update_rc). The lock file was NOT updated, nothing was built, and nothing is armed."
    fi
  fi

  say "prepare: building $attr from $flake (nothing is armed; no timeout can fire)"
  say "prepare: this may take as long as it takes — a slow build causes zero"
  say "prepare: activation and zero rollback, by construction."

  local out rc=0
  if [[ "$build_timeout" -gt 0 ]]; then
    out="$(timeout "$build_timeout" "$NM_NIX" "${nix_args[@]}" "$flake#$attr")" || rc=$?
    if [[ "$rc" -eq 124 ]]; then
      die "prepare: build exceeded ${build_timeout}s and was stopped. Nothing was armed and nothing was activated; re-run to continue building."
    fi
  else
    out="$("$NM_NIX" "${nix_args[@]}" "$flake#$attr")" || rc=$?
  fi

  if [[ "$rc" -ne 0 ]]; then
    sayf "prepare: build FAILED (exit $rc). Nothing was armed, nothing was activated,"
    sayf "         and no rollback is pending: the running system is untouched."
    return "$rc"
  fi

  local candidate
  candidate="$(printf '%s\n' "$out" | tail -n 1)"
  valid_store_path "$candidate" || die "prepare: nix printed '$candidate', which is not a store path"

  record_defaults
  RECORD["host"]="$host"
  RECORD["phase"]="prepared"
  RECORD["operation"]="activate"
  RECORD["candidate"]="$candidate"
  RECORD["note"]="prepared ${tag:-closure} from $flake#$attr"
  record_save

  gc_protect "candidate" "$candidate"

  say ""
  say "prepare: candidate is $candidate"
  say "prepare: pinned with GC root $(gc_root_name candidate)"
  say "prepare: NOT activated. Arm a deadline and activate when you are ready:"
  say "           ns-maint activate"
}

# ── activate ────────────────────────────────────────────────────────────────
cmd_activate() {
  require_privileged
  local timeout_s="$NM_DEFAULT_TIMEOUT" allow_unknown_kernel=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --timeout)
      timeout_s="$2"
      shift 2
      ;;
    --allow-unknown-kernel)
      allow_unknown_kernel=1
      shift
      ;;
    -h | --help)
      usage
      return 0
      ;;
    *) die "activate: unknown argument '$1'" ;;
    esac
  done

  local duration
  duration="$(parse_duration "$timeout_s")" || return 1
  [[ "$duration" -gt 0 ]] || die "activate: timeout must be positive"
  lock_acquire
  record_load

  if is_pending_phase "${RECORD[phase]}"; then
    die "refusing to start a second transaction: ${RECORD[phase]} (txid ${RECORD[txid]}).
         Confirm it (ns-maint confirm ${RECORD[txid]}) or restore it (ns-maint abort)."
  fi

  [[ "${RECORD[phase]}" == "prepared" ]] || die "nothing to activate: run 'ns-maint prepare' first."
  local candidate="${RECORD[candidate]}"
  valid_store_path "$candidate" || die "activate: candidate '$candidate' is not a store path"
  [[ -d "$candidate" ]] || die "activate: candidate $candidate is not in the store any more. Re-run 'ns-maint prepare'."

  local running booted old_profile old_gen txid deadline
  running="$(current_closure)"
  booted="$(booted_closure)"
  old_profile="$(profile_target)"
  old_gen="$(generation_of "$old_profile")"
  txid="$(new_txid)"

  if [[ -z "$running" ]]; then
    die "activate: cannot read $NM_CURRENT_SYSTEM. Refusing to arm without knowing the recovery closure."
  fi
  if ! valid_store_path "$running"; then
    die "activate: $NM_CURRENT_SYSTEM points at '$running', which is not a store path. Refusing to arm."
  fi
  if ! valid_store_path "$booted"; then
    die "activate: $NM_BOOTED_SYSTEM points at '$booted', which is not a store path. Refusing to arm."
  fi

  local candidate_kernel running_kernel unknown_kernel=0
  candidate_kernel="$(kernel_signature "$candidate")"
  running_kernel="$(kernel_signature "$running")"
  if [[ "$candidate_kernel" == unknown || "$running_kernel" == unknown ]]; then
    unknown_kernel=1
  fi
  if kernel_is_dirty "$candidate" "$running" &&
    [[ "$unknown_kernel" -eq 0 || "$allow_unknown_kernel" -ne 1 ]]; then
    die "activate: refused. The candidate carries a different kernel than the running closure
             candidate kernel : $(kernel_signature "$candidate")
             running kernel   : $(kernel_signature "$running")
           A live switch cannot load a new kernel, and activating userspace that
           expects new kernel modules is how you get 'Driver/library version mismatch'.
           Stage it for a reboot instead — and reboot only when you have chosen to:
             ns-maint stage
             ns-maint reboot --yes
           (or re-run with --allow-unknown-kernel if the check could not inspect both closures)"
  fi
  if [[ "$unknown_kernel" -eq 1 ]]; then
    sayf "activate: WARNING -- kernel check could not compare both closures; continuing because --allow-unknown-kernel was given."
  fi

  # The recovery closure and the booted closure must both survive a GC that
  # happens while this transaction is pending. Pin them now — before the record
  # is written, so there is no window in which the rollback target can be
  # collected out from under a transaction that is about to exist.
  gc_protect "running" "$running"
  valid_store_path "$booted" && gc_protect "booted" "$booted"

  deadline=$(( $(now_epoch) + duration ))

  RECORD["phase"]="armed"
  RECORD["txid"]="$txid"
  RECORD["operation"]="activate"
  RECORD["host"]="${NM_HOST}"
  RECORD["candidate"]="$candidate"
  RECORD["old_running"]="$running"
  RECORD["old_profile"]="$old_profile"
  RECORD["old_profile_closure"]="$(profile_closure)"
  if [[ -n "$old_profile" ]]; then
    valid_store_path "${RECORD[old_profile_closure]}" || die "cannot record a usable profile closure"
    protect_recorded_profile
  else
    RECORD["old_profile_closure"]=""
  fi
  RECORD["old_gen"]="$old_gen"
  RECORD["booted"]="$booted"
  RECORD["deadline"]="$deadline"
  RECORD["armed_at"]="$((deadline - duration))"
  RECORD["note"]="armed ${timeout_s} window"
  resolve_recorded_profile || die "cannot resolve captured profile before arming"
  record_save

  log_event "armed txid=$txid candidate=$candidate running=$running booted=$booted deadline=$deadline"

  say ""
  say "activate: armed txid $txid"
  say "activate:   recovery closure $running (GC-rooted)"
  say "activate:   booted closure     $booted (GC-rooted)"
  say "activate:   confirm within $timeout_s or the old closure is restored (no reboot)"
  say ""
  say "activate: handing activation to a system service, so a dropped SSH session"
  say "activate: cannot abort it half-way."

  # Everything above is decided and written. Release the lock BEFORE handing off,
  # so the unit we are about to start can take it for itself.
  lock_release

  local unit="ns-maint-activate-${txid}"
  say "activate: waiting for $unit to finish (disconnecting does not stop it)."
  say "activate: log: journalctl -u $unit -f"
  local activation_rc=0
  "$NM_SYSTEMD_RUN" --unit="$unit" --collect --wait \
    --description="ns-maint activation $txid" \
    --property=Type=oneshot \
    "$(self_path)" __run-activation "$txid" "$candidate" || activation_rc=$?

  record_load
  if [[ "$activation_rc" -ne 0 || "${RECORD[txid]}" != "$txid" || "${RECORD[phase]}" != "awaiting-confirm" ]]; then
    sayf "activate: service finished with exit $activation_rc; transaction is ${RECORD[phase]}."
    sayf "activate: inspect sudo ns-maint status and journalctl -u $unit."
    return 1
  fi
  say "activate: activation completed. Check access from a NEW session, then run:"
  say "  sudo ns-maint confirm $txid"
}

parse_duration() {
  # Deliberately tiny: a number, optionally suffixed with s/m/h. A duration we
  # cannot parse must not silently become 0, which would mean "restore now".
  local v="$1" n u
  if [[ "$v" =~ ^([0-9]+)$ ]]; then
    printf '%s' "$((10#${BASH_REMATCH[1]}))"
    return 0
  fi
  if [[ "$v" =~ ^([0-9]+)(s|sec|m|min|h)$ ]]; then
    n="$((10#${BASH_REMATCH[1]}))"
    u="${BASH_REMATCH[2]}"
    case "$u" in
    s | sec) printf '%s' "$n" ;;
    m | min) printf '%s' "$((n * 60))" ;;
    h) printf '%s' "$((n * 3600))" ;;
    esac
    return 0
  fi
  die "'$v' is not a duration this tool understands (use e.g. 90, 90s, 20m, 1h)"
}

# Normalize our duration syntax before any GNU timeout invocation. Zero would
# disable its deadline entirely, including for bootloader restoration.
NM_RESTORE_TIMEOUT="$(parse_duration "$NM_RESTORE_TIMEOUT")" || exit 1
if [[ ! "$NM_RESTORE_TIMEOUT" =~ ^[0-9]+$ ]] || ((NM_RESTORE_TIMEOUT <= 0)); then
  die "NM_RESTORE_TIMEOUT must be a positive duration"
fi

# self_path — absolute path to this script, so the transient unit runs the same
# build regardless of PATH or working directory.
self_path() {
  local src="${BASH_SOURCE[0]}"
  if command -v readlink >/dev/null 2>&1; then
    local resolved
    resolved="$(readlink -f "$src" 2>/dev/null || true)"
    [[ -n "$resolved" ]] && {
      printf '%s' "$resolved"
      return 0
    }
  fi
  printf '%s' "$src"
}

# __run-activation — runs inside the transient system unit. Not a public command.
#
# Deliberately re-checks the record under the lock before doing anything: by the
# time systemd starts us, the operator may have aborted, or a deadline may have
# fired, and applying a candidate nobody is waiting for any more is exactly the
# surprise this tool exists to prevent.
cmd_run_activation() {
  local txid="${1-}" candidate="${2-}"
  [[ -n "$txid" && -n "$candidate" ]] || {
    sayf "internal: __run-activation needs <txid> <candidate>"
    return 2
  }

  lock_acquire
  record_load
  if [[ "${RECORD[txid]}" != "$txid" || "${RECORD[phase]}" != "armed" ]]; then
    log_event "activation $txid not started: record is ${RECORD[phase]}/${RECORD[txid]}"
    sayf "activation $txid abandoned: the transaction is ${RECORD[phase]}, not armed."
    return 3
  fi

  RECORD["phase"]="activating"
  RECORD["activated_at"]=""
  record_save
  log_event "activating txid=$txid candidate=$candidate"

  local rc=0 remaining
  remaining=$(( RECORD[deadline] - $(now_epoch) ))
  if [[ "$remaining" -le 0 ]]; then
    do_restore "$txid" "deadline-expired"
    return $?
  fi

  timeout --signal=KILL "$remaining" "$NM_ENV" --profile "$NM_PROFILE" --set "$candidate" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    RECORD["note"]="profile update failed (exit $rc); restoring"
    record_save
    log_event "activation $txid profile update failed rc=$rc; restoring"
    lock_release
    do_restore "$txid" "profile-update-failed-rc-$rc"
    return $?
  fi

  # Keep the lock through activation. The watchdog cannot acquire it here, so
  # bound the entire activation process group by the remaining deadline.
  remaining=$(( RECORD[deadline] - $(now_epoch) ))
  if [[ "$remaining" -le 0 ]]; then
    do_restore "$txid" "deadline-expired"
    return $?
  fi
  switch_to_configuration "$candidate" switch "$remaining" || rc=$?
  if [[ "$(now_epoch)" -ge "${RECORD[deadline]}" ]]; then
    do_restore "$txid" "deadline-expired"
    return $?
  fi

  if [[ "$rc" -eq 0 ]]; then
    RECORD["phase"]="awaiting-confirm"
    # Completion, not arming or start time. Reject same-second evidence too:
    # journald's seconds-only query cannot order events within that second.
    RECORD["activated_at"]="$(now_epoch)"
    record_save
    log_event "activation $txid applied, awaiting confirmation"
    sayf "activation $txid applied. Confirm it from a NEW session:"
    sayf "  sudo ns-maint confirm $txid"
    return 0
  fi

  # Nonzero is NOT "nothing happened". Activation can leave changed services
  # behind after failing. Restore regardless of what the profile says.
  sayf "activation $txid FAILED (exit $rc)."
  sayf "This may be a PARTIAL application: units can already have been reconfigured even"
  sayf "before activation failed. Restoring the previous closure."
  log_event "activation $txid failed rc=$rc; restoring"
  RECORD["note"]="activation exited $rc; restoring (partial application is possible)"
  record_save
  do_restore "$txid" "activation-failed-rc-$rc"
}

# switch_to_configuration — the one place activation and restore actually happen.
#
# Runs the CANDIDATE's own switch-to-configuration, not the running system's:
# the activation scripts that must be executed are the ones from the closure
# being applied. Overridable so the VM test and the unit suite can inject a
# fake without pretending to run a real activation.
switch_to_configuration() {
  local closure="$1" mode="$2" bin
  local -a limit=()
  if [[ -n "${3:-}" ]]; then
    # KILL bounds even an activation that ignores TERM, including its children.
    limit=(timeout --signal=KILL "$3")
  fi
  valid_store_path "$closure" || die "switch_to_configuration: '$closure' is not a store path"
  case "$mode" in
  switch | boot | test) ;;
  *) die "switch_to_configuration: '$mode' is not a mode" ;;
  esac
  if [[ -n "$NM_SWITCH_TO_CONFIGURATION" ]]; then
    "${limit[@]}" "$NM_SWITCH_TO_CONFIGURATION" "$closure" "$mode"
    return $?
  fi
  bin="$closure/bin/switch-to-configuration"
  [[ -x "$bin" ]] || die "activate: $bin is missing or not executable."
  "${limit[@]}" "$bin" "$mode"
}

# do_restore — the recovery path. NEVER reboots.
#
# Runtime is restored with `test`, then the recorded profile is restored and
# its closure's `boot` rebuilds boot intent. Those closures may differ. Every
# step is bounded and any failure is recorded, even if another step succeeds.
# Existing bootloader default overrides are not observable from the profile;
# this restores profile-derived boot intent, not arbitrary manual overrides.
do_restore() {
  local txid="$1" reason="$2" rc=0 boot_rc=0 detail=""
  lock_acquire
  record_load
  if [[ "${RECORD[txid]}" != "$txid" ]]; then
    sayf "restore for $txid skipped: the record now belongs to '${RECORD[txid]}'."
    return 0
  fi
  if [[ "${RECORD[phase]}" == "restored" ]]; then
    return 0
  fi

  local old="${RECORD[old_running]}"
  if [[ -z "$old" ]] || ! valid_store_path "$old"; then
    RECORD["phase"]="restore-failed"
    RECORD["restore_result"]="no-usable-recovery-closure"
    RECORD["restore_detail"]="the record has no valid old_running closure to return to; profile=$NM_PROFILE currently resolves to $(profile_closure)"
    record_save
    log_event "restore $txid: no usable recovery closure recorded"
    sayf "RESTORATION FAILED for $txid: the record has no usable recovery closure."
    sayf "  profile: $NM_PROFILE -> $(profile_closure)"
    sayf "  booted:  $NM_BOOTED_SYSTEM -> $(booted_closure)"
    sayf "  Read the record with: ns-maint status"
    return 1
  fi

  RECORD["phase"]="restoring"
  RECORD["note"]="restoring ($reason)"
  record_save
  log_event "restoring txid=$txid reason=$reason to $old"

  # Pin the recovery closure again: the deadline is long gone by the time we get
  # here, and nothing else guarantees it survives the next collection.
  gc_protect "running" "$old"

  # Runtime and profile may deliberately differ (e.g. an earlier test switch).
  # `test` restores runtime only; boot intent is then rebuilt from the recorded
  # profile closure. Never let `switch` silently collapse those two intents.
  local boot="${RECORD[old_profile_closure]}"
  sayf "restoring $txid runtime to $old (no reboot) because: $reason"
  switch_to_configuration "$old" test "$NM_RESTORE_TIMEOUT" || rc=$?
  restore_profile_intent || boot_rc=$?
  if [[ "$boot_rc" -ne 0 ]]; then
    detail="profile restoration failed with exit $boot_rc"
  else
    switch_to_configuration "$boot" boot "$NM_RESTORE_TIMEOUT" || boot_rc=$?
    [[ "$boot_rc" -eq 0 ]] || detail="switch-to-configuration boot also failed with exit $boot_rc"
  fi
  if [[ "$rc" -ne 0 ]]; then
    detail="switch-to-configuration test failed with exit $rc; $detail"
  fi
  if [[ "$rc" -eq 0 && "$boot_rc" -eq 0 ]]; then
    RECORD["phase"]="restored"
    RECORD["restore_result"]="restored-live"
    RECORD["restore_detail"]="runtime test, recorded profile and boot intent restored"
    record_save
    log_event "restore $txid ok (live)"
    sayf "restore $txid complete: runtime $old; recorded profile/boot intent restored. NO REBOOT WAS PERFORMED."
    return 0
  fi
  RECORD["phase"]="restore-failed"
  RECORD["restore_result"]="restore-failed"
  RECORD["restore_detail"]="$detail"
  record_save
  log_event "restore $txid FAILED: $detail"
  sayf "RESTORATION DID NOT COMPLETE for $txid: $detail"
  sayf "runtime may still be running SOME of the failed candidate's units. No reboot was performed."
  return 1
}

# restore_profile_intent — point the profile back at the recorded generation.
#
# Prefers the generation number, because that keeps nix's own bookkeeping
# consistent, and verifies the generation really is the recorded closure first.
# Falls back to rewriting the symlink when the generation is gone, because
# leaving the profile pointed at a failed candidate is worse than losing a
# generation number.
restore_profile_intent() {
  local target="${RECORD[old_profile]-}" gen="${RECORD[old_gen]-}" closure="${RECORD[old_profile_closure]-}"
  if [[ -n "${RECORD[profile_resolution_error]}" ]]; then
    sayf "restore: ${RECORD[profile_resolution_error]}"
    return 1
  fi
  if [[ -z "$target" ]]; then
    rm -f -- "$NM_PROFILE"
    sayf "restore: originally absent profile has no recorded boot intent"
    return 1
  fi
  valid_store_path "$closure" || { sayf "restore: recorded profile closure is missing or invalid"; return 1; }
  if [[ -n "$gen" ]]; then
    # Verify before switching: the recorded generation must still exist AND it
    # must still resolve to the recorded recovery closure. If either is false the
    # generation number is not the thing we recorded, and switching to it would
    # move the profile somewhere we never intended.
    local gen_path
    gen_path="$(readlink -e "${NM_PROFILE}-${gen}-link" 2>/dev/null || true)"
    if [[ -n "$gen_path" ]] && valid_store_path "$gen_path" && [[ "$gen_path" == "$closure" ]]; then
      if timeout --signal=KILL "$NM_RESTORE_TIMEOUT" "$NM_ENV" --profile "$NM_PROFILE" --switch-generation "$gen"; then
        log_event "profile restored to generation $gen"
        return 0
      fi
      sayf "restore: nix-env could NOT restore recorded generation $gen"
      return 1
    fi
  fi
  if ln -sfn "$closure" "$NM_PROFILE"; then
    log_event "profile symlink rewritten to $closure (generation bookkeeping skipped)"
    sayf "restore: profile symlink rewritten directly to $closure"
    return 0
  fi
  sayf "restore: could NOT restore the profile symlink to $closure"
  return 1
}

# ── confirm ─────────────────────────────────────────────────────────────────
#
# Requires the exact txid, so a confirmation left over from an earlier update
# cannot bless a newer one. The operator checks access from a new session;
# closure and profile checks ensure the decision applies to this candidate.
cmd_confirm() {
  require_privileged
  local txid_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --txid) txid_arg="$2"; shift ;;
    --assume-new-connection) ;; # Accepted for older operator scripts.
    -h | --help)
      say "usage: sudo ns-maint confirm <txid>"
      return 0
      ;;
    --*) die "confirm: unknown option '$1'" ;;
    *) [[ -n "$txid_arg" ]] && die "confirm: give at most one txid"; txid_arg="$1" ;;
    esac
    shift
  done

  if [[ -z "$txid_arg" ]]; then
    record_load
    die "confirm: name the transaction you are confirming.
             A confirmation is bound to ONE transaction id, so an old 'yes' can
             never bless a newer update. The current one is:
               ${RECORD[txid]:-none (phase ${RECORD[phase]})}"
  fi

  lock_acquire
  record_load

  [[ "${RECORD[phase]}" == "awaiting-confirm" || "${RECORD[phase]}" == "reconciled-booted" ]] || die "confirm: nothing is awaiting confirmation — the transaction is '${RECORD[phase]}'${RECORD[txid]:+ (txid ${RECORD[txid]})}."
  [[ "${RECORD[txid]}" == "$txid_arg" ]] || die "confirm: txid mismatch. The pending transaction is '${RECORD[txid]}', you passed '$txid_arg'.
             Refusing: a stale confirmation must never bless a newer transaction."

  local candidate="${RECORD[candidate]}"
  local profile_now running_now
  profile_now="$(profile_closure)"
  running_now="$(current_closure)"

  # ── The deadline is a hard bound, not a hint ──────────────────────────────
  # Once the window has closed, "yes" is not a late confirmation, it is a
  # confirmation of something the operator has not looked at in a while — and
  # the watchdog may be a few seconds away from restoring it. Refusing here is
  # what makes the confirm/deadline race decidable in one direction only:
  #
  #   * confirm before the deadline  -> confirmed; the watchdog then sees a
  #     non-pending phase and does nothing.
  #   * confirm after the deadline   -> refused, here and again once the
  #     watchdog has restored; `ns-maint abort` or a fresh prepare is the way
  #     forward.
  #
  # Both take the same lock, so there is no interleaving where a confirmation
  # lands between the watchdog's read and its restore.
  local deadline="${RECORD[deadline]}" now
  now="$(now_epoch)"
  if valid_integer "$deadline" && [[ "$now" -ge "$deadline" ]]; then
    die "confirm: the confirmation window for $txid_arg closed at $deadline (now $now).
             Nothing has been restored yet — the watchdog runs every 30s — but a
             confirmation this late is not a confirmation of something you just
             looked at. To go back deliberately:  ns-maint abort $txid_arg"
  fi

  # Local health evidence, collected and stored rather than asserted.
  collect_health
  local problems=0
  [[ "$profile_now" == "$candidate" ]] || {
    sayf "health: profile is $profile_now, not the candidate $candidate"
    problems=$((problems + 1))
  }
  [[ "$running_now" == "$candidate" ]] || {
    sayf "health: running system is $running_now, not the candidate $candidate"
    problems=$((problems + 1))
  }
  if [[ "${RECORD[health_failed_units]}" != "0" ]]; then
    sayf "health: WARNING — ${RECORD[health_failed_units]} failed systemd unit(s); review separately:"
    "$NM_SYSTEMCTL" --failed --no-legend --plain 2>/dev/null | sed 's/^/      /' >&2 || true
  fi
  [[ "$problems" -eq 0 ]] || die "confirm: running system or profile does not match the candidate; refusing confirmation."

  # The operator checks access from another device/session. Do not infer that
  # from transport-specific login logs: Tailscale SSH does not use sshd.
  local evidence="operator confirmed access and candidate; connection not automatically verified"
  RECORD["phase"]="confirmed"
  RECORD["confirmed_at"]="$(now_epoch)"
  RECORD["confirm_peer"]=""
  RECORD["confirm_connection"]="$evidence"
  RECORD["note"]="confirmed"
  record_save

  # The candidate is now simply the running system; the recovery roots are
  # released explicitly rather than left to accumulate. The booted closure is
  # still pinned until the operator actually reboots into something.
  gc_unprotect running
  gc_unprotect profile
  gc_unprotect candidate
  log_event "confirmed txid=$txid_arg; $evidence"
  sayf "confirm: $txid_arg is now permanent. $evidence."
  sayf "  failed units at confirmation: ${RECORD[health_failed_units]}"
  sayf "  the previously running closure stays pinned until you reboot or run 'ns-maint gc-release booted'."
}

# ── tick — the deadline watchdog ────────────────────────────────────────────
#
# Driven by a PERSISTENT systemd timer rather than a per-transaction transient
# timer, because a transient timer does not survive a reboot and this watchdog
# has to be the thing that is still there after an unexpected restart. See
# reconcile() for what happens then.
cmd_tick() {
  # --defer, and exit 0 on contention. The timer re-fires every NM_TICK_SECONDS,
  # so a tick skipped now is a tick that happens in 30 seconds; the alternative
  # is a watchdog that can fail the activation it is watching.
  if ! lock_acquire --defer; then
    sayf "tick: deferring to whoever holds the lock; the timer will fire again."
    return 0
  fi
  record_load

  if ! is_pending_phase "${RECORD[phase]}"; then
    return 0
  fi
  local deadline="${RECORD[deadline]}"
  valid_integer "$deadline" || return 0
  local now
  now="$(now_epoch)"
  [[ "$now" -ge "$deadline" ]] || return 0

  # Restoration changes system units, including this watchdog. A worker in
  # its own transient service survives the watchdog being stopped or replaced.
  local txid="${RECORD[txid]}"
  sayf "deadline passed for $txid (deadline $deadline, now $now)"
  lock_release
  "$NM_SYSTEMD_RUN" --unit="ns-maint-restore-${txid}" --collect --no-block \
    --description="ns-maint deadline restoration $txid" \
    --property=Type=oneshot --property=TimeoutStartSec=31min \
    "$(self_path)" __run-restore "$txid"
}

cmd_run_restore() {
  require_privileged
  local txid="${1-}"
  valid_txid "$txid" || die "internal: __run-restore needs a valid transaction id"
  # Another operation may win after tick submits us. The next tick retries.
  if ! lock_acquire --defer; then return 0; fi
  record_load
  [[ "${RECORD[txid]}" == "$txid" ]] || return 0
  is_pending_phase "${RECORD[phase]}" || return 0
  valid_integer "${RECORD[deadline]}" || return 0
  [[ "$(now_epoch)" -ge "${RECORD[deadline]}" ]] || return 0
  do_restore "$txid" "deadline-expired"
}

# ── reconcile — cold-boot handling of a persistent record ───────────────────
#
# Runs once at boot. A transaction record outlives reboots; a transient timer
# does not, so without this a machine that rebooted mid-window would come back
# with a record saying "awaiting confirmation" and nothing watching it.
#
# The contract here is deliberately passive: reconcile NEVER arms a deadline,
# NEVER activates and NEVER reboots. Re-arming on boot is how you get a machine
# that restores, reboots, restores, reboots. It only classifies what it finds
# and clears the deadline so no watchdog fires against a stale expectation.
cmd_reconcile() {
  require_privileged
  # --defer, and exit 0 on contention. This unit is WantedBy=multi-user.target
  # and is a oneshot, so switch-to-configuration restarts it during EVERY
  # activation — including one driven by ns-maint, which is holding this lock for
  # its whole duration. Failing here would make switch-to-configuration exit 4,
  # which ns-maint would answer by rolling the activation back. Reconciliation
  # runs again at the next boot, so deferring costs nothing and saves the
  # activation. See the comment above lock_acquire.
  if ! lock_acquire --defer; then
    sayf "reconcile: deferring to whoever holds the lock; reconciliation runs again at the next boot."
    return 0
  fi
  record_load

  if ! is_pending_phase "${RECORD[phase]}" && [[ "${RECORD[phase]}" != staged ]]; then
    sayf "reconcile: nothing pending (phase ${RECORD[phase]})."
    return 0
  fi

  local txid="${RECORD[txid]}" phase="${RECORD[phase]}"
  local booted now
  booted="$(booted_closure)"
  now="$(now_epoch)"

  # Clear the deadline first. Whatever we decide below, no watchdog should be
  # acting on a machine that has just rebooted.
  RECORD["deadline"]=""

  if [[ "$booted" == "${RECORD[candidate]}" ]]; then
    # The machine is running the candidate. Someone rebooted inside the window
    # (or an old nixos-rebuild did). The candidate is booted AND likely running;
    # that is a fact to confirm, not a fault to roll back.
    RECORD["phase"]="reconciled-booted"
    RECORD["reconciled_at"]="$now"
    RECORD["note"]="booted into the candidate during a pending transaction; deadline cleared, explicit confirmation required"
    record_save
    log_event "reconcile $txid: booted into candidate $booted; awaiting explicit confirm"
    sayf "reconcile: $txid was ${phase} and this machine booted INTO the candidate."
    sayf "  The deadline is cleared and NO rollback will fire."
    sayf "  Confirm it explicitly once you have checked from a new client:"
    sayf "    sudo ns-maint confirm $txid"
    return 0
  fi

  if [[ "$phase" == staging || "$phase" == stage-interrupted ]]; then
    RECORD[phase]=stage-interrupted
    RECORD[reconciled_at]="$now"
    RECORD[note]="staging was interrupted; profile/boot intent may have changed. Explicit abort or inspected recovery required; nothing retried automatically"
    record_save
    sayf "reconcile: interrupted stage $txid; inspect status and run ns-maint abort $txid to restore recorded intent. No runtime was activated."
    return 1
  fi

  if [[ "${RECORD[phase]}" == "restoring" ]]; then
    # A reboot onto A alone proves nothing about distinct profile/boot intent B.
    # Only bless a restore when all observed and recorded intents agree.
    if [[ -z "${RECORD[profile_resolution_error]}" && -n "${RECORD[old_profile_closure]}" &&
      "$booted" == "${RECORD[old_running]}" &&
      "$booted" == "${RECORD[old_profile_closure]}" &&
      "$(current_closure)" == "${RECORD[old_running]}" &&
      "$(profile_closure)" == "${RECORD[old_profile_closure]}" ]]; then
      RECORD["phase"]="restored"
      RECORD["restore_result"]="restored-by-reboot"
      RECORD["restore_detail"]="the machine rebooted onto the recovery closure while a restore was in flight"
    else
      RECORD["phase"]="restore-failed"
      RECORD["restore_result"]="restore-interrupted-by-reboot"
      local runtime profile
      runtime="$(current_closure)"
      profile="$(profile_closure)"
      [[ -n "$profile" && -e "$profile" ]] || profile="<unresolved>"
      RECORD["restore_detail"]="rebooted onto $booted; recovery state not established: current runtime=${runtime:-<unresolved>}, profile=$profile; recorded runtime=${RECORD[old_running]}, profile=${RECORD[old_profile_closure]:-<unresolved>}, profile resolution error=${RECORD[profile_resolution_error]:-none}"
    fi
    RECORD["reconciled_at"]="$now"
    record_save
    log_event "reconcile $txid: interrupted restore resolved to ${RECORD[phase]}"
    sayf "reconcile: $txid was restoring when this machine rebooted; now ${RECORD[phase]}."
    return 0
  fi

  # Booted on something that is not the candidate: the window never took effect
  # on the running kernel, or the candidate was staged only.
  RECORD["phase"]="reconciled-not-applied"
  RECORD["reconciled_at"]="$now"
  RECORD["note"]="rebooted on $booted with the transaction still ${phase}; deadline cleared, nothing retried automatically"
  record_save
  log_event "reconcile $txid: rebooted on $booted, transaction ${phase} not applied; no retry"
  sayf "reconcile: $txid was ${phase} and this machine came back on $booted."
  sayf "  The candidate was NOT applied to the running system."
  sayf "  The deadline is cleared, nothing was retried, and nothing was rebooted."
  sayf "  If the candidate is still what you want:"
  sayf "    ns-maint activate"
  sayf "  If it is not, the recovery closure is pinned at ${RECORD[old_running]}."
}

# ── stage / reboot — boot maintenance, always explicit ──────────────────────
#
# `stage` registers a system profile generation and writes its boot entry,
# without touching the live runtime. Generation discovery requires the profile.
cmd_stage() {
  require_privileged
  local candidate_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --candidate) candidate_arg="$2"; shift ;;
    -h | --help)
      say "usage: ns-maint stage [--candidate <store-path>]"
      return 0
      ;;
    *) die "stage: unknown argument '$1'" ;;
    esac
    shift
  done

  lock_acquire
  record_load
  if is_pending_phase "${RECORD[phase]}"; then
    die "stage: transaction ${RECORD[txid]} is ${RECORD[phase]}. Confirm or abort it first."
  fi
  local candidate="${candidate_arg:-${RECORD[candidate]}}"
  [[ -n "$candidate" ]] || die "stage: no candidate prepared. Run 'ns-maint prepare' first."
  valid_store_path "$candidate" || die "stage: '$candidate' is not a store path"
  [[ -d "$candidate" ]] || die "stage: $candidate is not in the store."

  gc_protect candidate "$candidate"
  local running booted
  running="$(current_closure)"
  booted="$(booted_closure)"
  valid_store_path "$running" || die "stage: no usable recovery runtime"
  valid_store_path "$booted" || die "stage: no usable booted closure"
  valid_store_path "$running" && gc_protect running "$running"
  valid_store_path "$booted" && gc_protect booted "$booted"

  # Before anything is written to the ESP. See esp_preflight for why this is
  # here rather than left to the bootloader.
  esp_preflight || die "stage: refusing to write a boot entry with this little EFI space."

  # Bootloader generation discovery reads the SYSTEM PROFILE. Register first,
  # without live activation, and restore the old profile/boot intent on failure.
  RECORD[txid]="$(new_txid)"
  RECORD["old_running"]="$running"
  RECORD["old_profile"]="$(profile_target)"
  RECORD["old_gen"]="$(generation_of "${RECORD[old_profile]}")"
  RECORD["old_profile_closure"]=""
  if [[ -n "${RECORD[old_profile]}" ]]; then
    RECORD["old_profile_closure"]="$(profile_closure)"
    valid_store_path "${RECORD[old_profile_closure]}" || die "stage: unusable previous profile"
    protect_recorded_profile
  fi
  RECORD[phase]=staging
  RECORD[operation]=stage
  RECORD[candidate]="$candidate"
  RECORD[booted]="$booted"
  RECORD[deadline]=""
  RECORD[activated_at]=""
  RECORD[staged_candidate]=""
  resolve_recorded_profile || die "cannot resolve captured profile before staging"
  record_save
  local rc=0 recovery_rc=0
  timeout --signal=KILL "$NM_RESTORE_TIMEOUT" "$NM_ENV" --profile "$NM_PROFILE" --set "$candidate" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    switch_to_configuration "$candidate" boot "$NM_RESTORE_TIMEOUT" || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    restore_profile_intent || recovery_rc=$?
    if [[ "$recovery_rc" -eq 0 ]]; then
      switch_to_configuration "${RECORD[old_profile_closure]}" boot "$NM_RESTORE_TIMEOUT" || recovery_rc=$?
    fi
    RECORD["restore_detail"]="stage failed exit $rc; profile/boot recovery exit $recovery_rc"
    RECORD["staged_candidate"]=""
    if [[ "$recovery_rc" -ne 0 ]]; then RECORD["phase"]="restore-failed"; else RECORD["phase"]="prepared"; fi
    record_save
    die "${RECORD[restore_detail]}"
  fi

  RECORD["phase"]="staged"
  RECORD["operation"]="stage"
  RECORD["candidate"]="$candidate"
  RECORD["staged_candidate"]="$candidate"
  RECORD["host"]="${NM_HOST}"
  RECORD["note"]="staged for boot; nothing was switched live"
  record_save

  sayf "stage: bootloader entry written for $candidate"
  sayf "stage: NOTHING was switched live. candidate generation selected; profile is $NM_PROFILE -> $(profile_closure)"
  sayf "stage: reboot only when you have chosen to, and only with console/remote access ready:"
  sayf "         ns-maint reboot --yes"
}

# cmd_reboot — the ONLY reboot in this file, and it takes --yes.
cmd_reboot() {
  require_privileged
  local yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --yes | -y) yes=1 ;;
    -h | --help)
      say "usage: ns-maint reboot --yes"
      return 0
      ;;
    *) die "reboot: unknown argument '$1'" ;;
    esac
    shift
  done
  [[ "$yes" -eq 1 ]] || die "reboot: refusing without --yes.
             Rebooting an unattended host kills every running agent and stream.
             Nothing in this tool reboots implicitly; if you are reading this
             because something else claimed it would, that claim is wrong."

  lock_acquire
  record_load
  if is_pending_phase "${RECORD[phase]}" && [[ "${RECORD[phase]}" != "restoring" ]]; then
    die "reboot: a transaction is ${RECORD[phase]} (${RECORD[txid]}). Confirm or abort it first."
  fi

  sayf "reboot: rebooting NOW at your explicit request. This is not automatic."
  log_event "explicit reboot requested by operator"
  # A real sync first: a deliberate reboot should not be the thing that loses
  # an agent's work in flight.
  sync || true
  # shellcheck disable=SC2086
  $NM_REBOOT_CMD
}

# ── roots ───────────────────────────────────────────────────────────────────
cmd_roots() {
  local roots
  roots="$(gc_roots_list)"
  if [[ -z "$roots" ]]; then
    say "no ns-maint GC roots are pinned."
  else
    printf '%s\n' "$roots"
  fi
}

# ── abort ───────────────────────────────────────────────────────────────────
#
# The operator's "put it back" button. Same restore path as the deadline, and
# equally reboot-free.
cmd_abort() {
  local txid_arg=""
  [[ $# -gt 0 ]] && txid_arg="$1"
  lock_acquire
  record_load
  if ! is_pending_phase "${RECORD[phase]}"; then
    die "abort: nothing to abort — the transaction is '${RECORD[phase]}'."
  fi
  [[ -z "$txid_arg" || "$txid_arg" == "${RECORD[txid]}" ]] ||
    die "abort: txid mismatch: pending is '${RECORD[txid]}', you passed '$txid_arg'."
  require_privileged
  local txid="${RECORD[txid]}"
  do_restore "$txid" "aborted-by-operator"
}

# ── gc ──────────────────────────────────────────────────────────────────────
#
# Explicit, and never `-d`: deleting generations is what removes recovery
# targets. GC roots are honoured by the collector, which is why pinned closures
# survive this.
cmd_gc() {
  require_privileged
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --keep | --keep=*)
      die "gc: --keep is not supported; this command never deletes generation links. All system generations and recovery roots are retained."
      ;;
    -h | --help)
      say "usage: ns-maint gc (all generations are retained)"
      return 0
      ;;
    *) die "gc: unknown argument '$1'" ;;
    esac
  done
  lock_acquire
  record_load
  if is_pending_phase "${RECORD[phase]}"; then
    die "gc: transaction ${RECORD[txid]} is pending (${RECORD[phase]}); refusing collection"
  fi
  local label closure
  for label in running booted profile; do
    case "$label" in
      running) closure="$(current_closure)" ;;
      booted) closure="$(booted_closure)" ;;
      profile) closure="$(profile_closure)" ;;
    esac
    valid_store_path "$closure" || die "gc: cannot protect the $label closure; refusing collection"
    gc_protect "$label" "$closure"
  done
  for label in candidate old_running old_profile_closure; do
    closure="${RECORD[$label]}"
    [[ -z "$closure" ]] || gc_protect "gc-$label" "$closure"
  done
  say "gc: collecting unreferenced store paths; all generation links and recovery roots are retained."
  "$NM_NIX_STORE" --gc
}

# ── verify-installation ─────────────────────────────────────────────────────
#
# Run at boot by maintenance.nix. Checks the properties the rest of this file
# assumes, so a misconfigured deployment fails visibly once instead of failing
# obscurely during an incident.
cmd_verify_installation() {
  local problems=0
  if [[ ! -d "$NM_DIR" ]]; then
    sayf "verify: $NM_DIR does not exist"
    problems=$((problems + 1))
  else
    local owner mode
    owner="$(stat -c %u "$NM_DIR")"
    mode="$(stat -c %a "$NM_DIR")"
    if [[ "$NM_TEST_MODE" != "1" && "$owner" != "0" ]]; then
      sayf "verify: $NM_DIR is owned by uid $owner, not root — a non-root caller could"
      sayf "         forge a transaction record."
      problems=$((problems + 1))
    fi
    if [[ "$mode" != "700" && "$mode" != "750" && "$mode" != "755" ]]; then
      sayf "verify: $NM_DIR has mode $mode; expected 0750 or 0700."
      problems=$((problems + 1))
    fi
  fi
  if [[ ! -d "$NM_GCROOTS" ]]; then
    sayf "verify: GC roots directory $NM_GCROOTS is missing; recovery closures would not be pinned."
    problems=$((problems + 1))
  fi
  if [[ -z "$NM_HOST" ]]; then
    sayf "verify: NM_HOST is unset, so a record from another host could not be rejected."
    problems=$((problems + 1))
  fi
  if [[ "$problems" -eq 0 ]]; then
    say "verify: maintenance state directory and GC roots look right."
    return 0
  fi
  sayf "verify: $problems problem(s) found."
  return 1
}

# ── dispatch ────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
usage: ns-maint <command> [options]

  prepare   [--flake DIR] [--host H] [--offline] [--build-timeout N]
            [--update-input NAME] [--output NAME] [--tag TEXT]
            Build the exact selected host closure. Arms NOTHING: no deadline
            exists, so a build longer than any timeout causes zero activation
            and zero rollback. --update-all is refused.

  activate  [--timeout DUR] [--allow-unknown-kernel]
            Arm the deadline immediately before mutation, record the old running
            closure, the profile and boot intent, and the booted closure, then
            hand activation to a system service that survives caller disconnect.

  confirm   <txid>
            After checking access from a new session, confirm this candidate.
            Checks transaction ID, deadline, running closure and system profile.
            Failed services are reported for review rather than blocking confirm.

  abort     [<txid>]
            Operator-initiated restore. Live, never a reboot.

  status    [--json]

  tick                      Deadline watchdog. Driven by a persistent systemd
                            timer, not a per-transaction transient one.

  reconcile                 Cold-boot classification of a pending record. Never
                            arms, never activates, never reboots.

  stage     [--candidate P] Write a bootloader entry for the candidate without
                            switching anything live.

  reboot    --yes           The only reboot in this tool. Never implicit.

  gc                       Collect unreferenced paths; keep every generation.
                           --keep is refused; no generation deletion.

  roots                      List pinned recovery closures.
  verify-installation        Check the invariants the rest of the tool assumes.
EOF
}

main() {
  local cmd="${1-}"
  [[ $# -gt 0 ]] && shift || true
  case "$cmd" in
  prepare) cmd_prepare "$@" ;;
  activate) cmd_activate "$@" ;;
  confirm) cmd_confirm "$@" ;;
  abort) cmd_abort "$@" ;;
  status) cmd_status "$@" ;;
  tick) cmd_tick "$@" ;;
  reconcile) cmd_reconcile "$@" ;;
  stage) cmd_stage "$@" ;;
  reboot) cmd_reboot "$@" ;;
  gc) cmd_gc "$@" ;;
  roots) cmd_roots "$@" ;;
  verify-installation) cmd_verify_installation "$@" ;;
  __run-activation) cmd_run_activation "$@" ;;
  __run-restore) cmd_run_restore "$@" ;;
  -h | --help | help | "") usage ;;
  *) usage >&2; die "unknown command '$cmd'" ;;
  esac
}

main "$@"