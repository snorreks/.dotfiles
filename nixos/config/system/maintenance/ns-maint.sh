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
NM_JOURNALCTL="${NM_JOURNALCTL:-journalctl}"
NM_SUDO="${NM_SUDO:-sudo}"
NM_SWITCH_TO_CONFIGURATION="${NM_SWITCH_TO_CONFIGURATION:-}"
NM_REBOOT_CMD="${NM_REBOOT_CMD:-systemctl reboot}"
NM_SSH_UNIT="${NM_SSH_UNIT:-sshd.service}"
# Deadline watchdog period, and the default confirmation window. Both are
# overridable so tests do not have to wait minutes.
NM_TICK_SECONDS="${NM_TICK_SECONDS:-30}"
NM_DEFAULT_TIMEOUT="${NM_DEFAULT_TIMEOUT:-20min}"
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
PHASES=(idle prepared armed activating awaiting-confirm restoring restored
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

# Is this an address inside the Tailscale CGNAT range, 100.64.0.0/10?
#
# Used for one thing: to tell the operator, when the new-connection check finds
# no evidence, that they are almost certainly on Tailscale SSH rather than on
# OpenSSH. That distinction is not a detail — see the message it produces.
#
# Deliberately IPv4-only and deliberately conservative: a CGNAT address can be
# something else entirely, so this says "this LOOKS like a tailnet address", and
# a false positive only adds an explanatory paragraph to an error the operator
# was already getting. It must never gate a decision.
tailnet_address() {
  local ip="$1"
  [[ "$ip" =~ ^100\.([0-9]{1,3})\. ]] || return 1
  local second="${BASH_REMATCH[1]}"
  # 100.64.0.0/10 — the second octet is 64..127. Leading zeros and anything
  # above 255 are rejected rather than arithmetically normalised.
  [[ "$second" =~ ^0*(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])$ ]] || return 1
  return 0
}

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
  "$NM_DF" -P -k "$NM_ESP_PATH" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1024 }'
}

esp_preflight() {
  local free
  free="$(esp_free_mib)"
  if [[ -z "$free" ]]; then
    # Not a reason to refuse: the path may simply not be a mountpoint in the
    # fixture or on a host with a different layout. Say it and continue.
    sayf "stage: could not read free space on $NM_ESP_PATH (is it mounted?). Continuing."
    return 0
  fi
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
PENDING_PHASES=(armed activating awaiting-confirm restoring)

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
# armed_at      — epoch seconds the mutation window opened. The NEW-connection
#                 check compares against this.
# restore_*     — outcome of the last restore attempt, reported verbatim.
RECORD_KEYS=(schema_version phase txid host operation candidate old_running
  old_profile old_gen booted deadline armed_at activated_at restore_result
  restore_detail staged_candidate confirmed_at confirm_peer confirm_connection
  health_failed_units health_checked_at reconciled_at note)

declare -A RECORD=()

record_defaults() {
  local k
  for k in "${RECORD_KEYS[@]}"; do RECORD["$k"]=""; done
  RECORD["schema_version"]="1"
  RECORD["phase"]="idle"
}

record_file_exists() { [[ -f "$RECORD_FILE" ]]; }

record_load() {
  record_defaults
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
  for p in candidate old_running booted staged_candidate; do
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
LOCK_FD=
LOCK_DEPTH=0
lock_acquire() {
  if [[ "$LOCK_DEPTH" -gt 0 ]]; then
    LOCK_DEPTH=$((LOCK_DEPTH + 1))
    return 0
  fi
  mkdir -p "$NM_DIR"
  exec {LOCK_FD}>"$LOCK_FILE"
  if ! flock -n "$LOCK_FD"; then
    say "another ns-maint operation holds the lock; retry once it finishes."
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
  gen="${link#system-}"
  gen="${gen%-link}"
  if [[ "$gen" =~ ^[0-9]+$ ]]; then
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
  local attr="nixosConfigurations.${output:-$host}.system"
  local -a nix_args=(build --no-link --print-out-paths)
  [[ "$offline" -eq 1 ]] && nix_args+=(--offline)

  if [[ -n "$update_input" ]]; then
    say "prepare: updating exactly ONE flake input ($update_input) — this rewrites $flake/flake.lock"
    say "prepare: review the lock diff before activating anything."
    "$NM_NIX" --extra-experimental-features 'nix-command flakes' \
      flake update "$flake" "$update_input"
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

  deadline=$(( $(now_epoch) + $(parse_duration "$timeout_s") ))

  RECORD["phase"]="armed"
  RECORD["txid"]="$txid"
  RECORD["operation"]="activate"
  RECORD["host"]="${NM_HOST}"
  RECORD["candidate"]="$candidate"
  RECORD["old_running"]="$running"
  RECORD["old_profile"]="$old_profile"
  RECORD["old_gen"]="$old_gen"
  RECORD["booted"]="$booted"
  RECORD["deadline"]="$deadline"
  RECORD["armed_at"]="$(now_epoch)"
  RECORD["note"]="armed ${timeout_s} window"
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
  "$NM_SYSTEMD_RUN" --unit="$unit" --collect --no-block \
    --description="ns-maint activation $txid" \
    --property=Type=oneshot \
    "$(self_path)" __run-activation "$txid" "$candidate"

  say ""
  say "activate: activation is running as $unit"
  say "activate: watch it with  systemctl status $unit   /   journalctl -u $unit -f"
  say "activate: then, FROM A NEW SESSION:  ns-maint confirm $txid"
}

parse_duration() {
  # Deliberately tiny: a number, optionally suffixed with s/m/h. A duration we
  # cannot parse must not silently become 0, which would mean "restore now".
  local v="$1" n u
  if [[ "$v" =~ ^([0-9]+)$ ]]; then
    printf '%s' "$((BASH_REMATCH[1]))"
    return 0
  fi
  if [[ "$v" =~ ^([0-9]+)([smh])$ ]]; then
    n="${BASH_REMATCH[1]}"
    u="${BASH_REMATCH[2]}"
    case "$u" in
    s) printf '%s' "$n" ;;
    m) printf '%s' "$((n * 60))" ;;
    h) printf '%s' "$((n * 3600))" ;;
    esac
    return 0
  fi
  die "'$v' is not a duration this tool understands (use e.g. 90, 90s, 20m, 1h)"
}

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
  RECORD["activated_at"]="$(now_epoch)"
  record_save
  log_event "activating txid=$txid candidate=$candidate"

  local rc=0 remaining
  remaining=$(( RECORD[deadline] - $(now_epoch) ))
  if [[ "$remaining" -le 0 ]]; then
    do_restore "$txid" "deadline-expired"
    return $?
  fi

  "$NM_ENV" --profile "$NM_PROFILE" --set "$candidate" || rc=$?
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
    record_save
    log_event "activation $txid applied, awaiting confirmation"
    sayf "activation $txid applied. Confirm it from a NEW session:"
    sayf "  ns-maint confirm $txid"
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
# Order matters. First try the old closure's `switch`, which restores runtime,
# profile and bootloader entry together. If THAT fails — which is the realistic
# case, since the old generation is what we are recovering to precisely because
# something is wrong — fall back to its `boot`, which writes the bootloader
# entry and touches nothing live. That way the next ordinary boot lands on the
# known-good closure, and the operator is told plainly that live restoration did
# not fully succeed rather than being handed a green checkmark.
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

  sayf "restoring $txid to $old (live, no reboot) because: $reason"
  switch_to_configuration "$old" switch || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    # Belt and braces: make the profile intent agree even if the old closure's
    # switch took a shortcut.
    restore_profile_intent || true
    RECORD["phase"]="restored"
    RECORD["restore_result"]="restored-live"
    RECORD["restore_detail"]="switch-to-configuration switch returned 0"
    record_save
    gc_protect "running" "$old"
    log_event "restore $txid ok (live)"
    sayf "restore $txid complete: runtime, profile and boot entry are back on $old."
    sayf "  NO REBOOT WAS PERFORMED. If the kernel changed, the running kernel is"
    sayf "  still the old one, which is the desired outcome for an unattended host."
    return 0
  fi

  detail="switch-to-configuration switch failed with exit $rc"
  sayf "live restoration FAILED (exit $rc). Falling back to boot intent only:"
  switch_to_configuration "$old" boot || boot_rc=$?
  if [[ "$boot_rc" -ne 0 ]]; then
    detail="$detail; switch-to-configuration boot also failed with exit $boot_rc"
  fi
  restore_profile_intent || true

  RECORD["phase"]="restore-failed"
  RECORD["restore_result"]="restore-failed"
  RECORD["restore_detail"]="$detail"
  record_save
  log_event "restore $txid FAILED: $detail"

  sayf ""
  sayf "RESTORATION DID NOT COMPLETE for $txid."
  sayf "  reason: $detail"
  sayf "  runtime may still be running SOME of the failed candidate's units."
  if [[ "$boot_rc" -eq 0 ]]; then
    sayf "  the next ordinary boot will land on $old, because its bootloader entry was written."
  else
    sayf "  boot intent was NOT written either. The next boot will use whatever entry"
    sayf "  the bootloader already has — check it with: bootctl list"
  fi
  sayf "  The machine was NOT rebooted. Read 'ns-maint status' for the full record."
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
  local target="${RECORD[old_profile]-}" gen="${RECORD[old_gen]-}" closure="${RECORD[old_running]-}"
  if [[ -z "$target" ]]; then
    rm -f -- "$NM_PROFILE"
    return $?
  fi
  if [[ -n "$gen" ]]; then
    # Verify before switching: the recorded generation must still exist AND it
    # must still resolve to the recorded recovery closure. If either is false the
    # generation number is not the thing we recorded, and switching to it would
    # move the profile somewhere we never intended.
    local gen_path
    gen_path="$(readlink -e "${NM_PROFILE}-${gen}-link" 2>/dev/null || true)"
    if [[ -n "$gen_path" ]] && valid_store_path "$gen_path" && [[ "$gen_path" == "$closure" ]]; then
      if "$NM_ENV" --profile "$NM_PROFILE" --switch-generation "$gen"; then
        log_event "profile restored to generation $gen"
        return 0
      fi
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
# cannot bless a newer one. Requires local health evidence. And requires proof
# that a NEW connection was established after the switch was armed, because an
# SSH socket that was already open when the network unit was rewritten tells you
# nothing about whether a fresh client could get in.
cmd_confirm() {
  local txid_arg="" assume=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --txid) txid_arg="$2" ;;
    --assume-new-connection) assume=1 ;;
    -h | --help)
      say "usage: ns-maint confirm <txid> [--assume-new-connection]"
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

  require_privileged
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
    sayf "health: ${RECORD[health_failed_units]} failed systemd unit(s):"
    "$NM_SYSTEMCTL" --failed --no-legend --plain 2>/dev/null | sed 's/^/      /' >&2 || true
    problems=$((problems + 1))
  fi

  # ── The NEW-connection check ──────────────────────────────────────────────
  local peer_ip="" peer_port="" evidence="unverified"
  local ssh_conn="${SSH_CONNECTION:-}"
  if [[ -n "$ssh_conn" ]]; then
    # sshd exports "peer_ip peer_port local_ip local_port" for the session this
    # command is running in, so the peer can be identified without trusting a
    # flag the operator typed.
    read -r peer_ip peer_port _ _ <<<"$ssh_conn"
  fi

  if [[ -n "$peer_ip" ]]; then
    # Ask sshd itself whether it accepted a session from that peer AFTER the
    # switch was armed. A pre-existing socket cannot produce such a line,
    # because the session it belongs to was accepted before armed_at.
    #
    # NM_SSH_UNIT (sshd.service) covers BOTH OpenSSH listeners this host has —
    # 22 and 2222 — because they are one unit: systemd runs both from the same
    # sshd.service and journald records their sessions under it
    # (`sshd-session[NNN]: Accepted publickey for … from … port …`). Verified on
    # this host, where both ports were listening at once. So a confirmation made
    # over the phone's 2222 session is evidence in exactly the same way a
    # confirmation over 22 is, and neither needs a second unit.
    local since="${RECORD[armed_at]}"
    if "$NM_JOURNALCTL" -u "$NM_SSH_UNIT" --since "@$since" --no-pager 2>/dev/null |
      grep -q "Accepted .* from ${peer_ip} port ${peer_port}"; then
      evidence="sshd accepted a session from ${peer_ip}:${peer_port} after the switch was armed"
    else
      sayf "confirm: no NEW sshd session from ${peer_ip}:${peer_port} was accepted after the"
      sayf "         switch was armed (armed_at $since)."
      sayf "         The connection you are using may have been established BEFORE the"
      sayf "         switch, which proves nothing about whether a fresh client can get in."
      sayf "         Open a second connection and run this from it, or pass"
      sayf "         --assume-new-connection if you verified it another way."
      #
      # A tailnet peer gets the extra sentence it needs, because the ordinary
      # advice above cannot work there and following it anyway wastes an
      # afternoon. Tailscale SSH answers on tailnet port 22 BEFORE the OS sshd
      # sees the connection, and its acceptance is recorded by tailscaled, not
      # by the sshd unit this check reads. So a confirmation run over Tailscale
      # SSH is looking for a record that will never be in that journal.
      #
      # No second journal source was added for it on purpose. Reading
      # tailscaled's log instead would mean trusting a line format that is not
      # part of any interface, is not guaranteed to be emitted at the default
      # verbosity, and changes between releases — a check that silently finds
      # nothing would be worse than one that refuses. The supported answer is to
      # confirm from an OpenSSH session (port 22 or the phone's 2222), which is
      # where the evidence is.
      if tailnet_address "$peer_ip"; then
        sayf ""
        sayf "         ${peer_ip} is a tailnet address, which is the case to read this:"
        sayf "         if you got here over Tailscale SSH, its acceptance is recorded by"
        sayf "         tailscaled, not by ${NM_SSH_UNIT}, so this check will never find it —"
        sayf "         that is a property of the listener, not a failed update. Confirm"
        sayf "         from OpenSSH instead (ssh -p 22, or -p 2222 from the phone); those"
        sayf "         sessions are both recorded in ${NM_SSH_UNIT}."
      fi
      exit 1
    fi
  elif [[ "$assume" -eq 1 ]]; then
    evidence="operator asserted a new connection (--assume-new-connection); not verified by sshd"
    sayf "confirm: WARNING — new-connection check was ASSERTED, not verified."
  else
    sayf "confirm: SSH_CONNECTION is unset, so this is not an SSH session and there is"
    sayf "         nothing for the new-connection check to verify. From a console,"
    sayf "         pass --assume-new-connection once you have checked reachability"
    sayf "         from a different device."
    exit 1
  fi

  [[ "$problems" -eq 0 ]] || {
    RECORD["confirm_peer"]="$peer_ip:$peer_port"
    RECORD["confirm_connection"]="$evidence"
    record_save
    die "confirm: refusing — local health evidence is not clean ($problems problem(s)). See above."
  }

  RECORD["phase"]="confirmed"
  RECORD["confirmed_at"]="$(now_epoch)"
  RECORD["confirm_peer"]="${peer_ip:-}"
  RECORD["confirm_connection"]="$evidence"
  RECORD["note"]="confirmed"
  record_save

  # The candidate is now simply the running system; the recovery roots are
  # released explicitly rather than left to accumulate. The booted closure is
  # still pinned until the operator actually reboots into something.
  gc_unprotect running
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
  lock_acquire
  record_load

  if ! is_pending_phase "${RECORD[phase]}"; then
    return 0
  fi
  local deadline="${RECORD[deadline]}"
  valid_integer "$deadline" || return 0
  local now
  now="$(now_epoch)"
  [[ "$now" -ge "$deadline" ]] || return 0

  # Confirm and tick race for this same lock. If confirm got here first the
  # phase is no longer pending and we returned above; if we got here first,
  # confirm will find a restored/aborted transaction and refuse. Either way
  # exactly one of them wins, and the record says which.
  local txid="${RECORD[txid]}"
  sayf "deadline passed for $txid (deadline $deadline, now $now)"
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
  lock_acquire
  record_load

  if ! is_pending_phase "${RECORD[phase]}"; then
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
    sayf "    ns-maint confirm $txid"
    return 0
  fi

  if [[ "${RECORD[phase]}" == "restoring" ]]; then
    # We were mid-restore when the machine went down. If it came back on the
    # old closure, the reboot completed the restore in the only way it possibly
    # could. If not, say so instead of claiming success.
    if [[ "$booted" == "${RECORD[old_running]}" ]]; then
      RECORD["phase"]="restored"
      RECORD["restore_result"]="restored-by-reboot"
      RECORD["restore_detail"]="the machine rebooted onto the recovery closure while a restore was in flight"
    else
      RECORD["phase"]="restore-failed"
      RECORD["restore_result"]="restore-interrupted-by-reboot"
      RECORD["restore_detail"]="rebooted onto $booted, which is neither the candidate nor the recorded recovery closure ${RECORD[old_running]}"
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
# `stage` writes the bootloader entry for the candidate WITHOUT switching the
# profile or touching anything live, so the machine is ready to boot into it
# the next time somebody chooses to reboot.
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
  valid_store_path "$running" && gc_protect running "$running"
  valid_store_path "$booted" && gc_protect booted "$booted"

  # Before anything is written to the ESP. See esp_preflight for why this is
  # here rather than left to the bootloader.
  esp_preflight || die "stage: refusing to write a boot entry with this little EFI space."

  # `boot` and NOT `switch`: this writes the bootloader entry for the candidate
  # and touches nothing that is currently running. That is the entire difference
  # between staging a reboot and taking one.
  switch_to_configuration "$candidate" boot

  RECORD["phase"]="prepared"
  RECORD["operation"]="stage"
  RECORD["candidate"]="$candidate"
  RECORD["staged_candidate"]="$candidate"
  RECORD["host"]="${NM_HOST}"
  RECORD["note"]="staged for boot; nothing was switched live"
  record_save

  sayf "stage: bootloader entry written for $candidate"
  sayf "stage: NOTHING was switched live. profile is still $NM_PROFILE -> $(profile_closure)"
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
  local keep=3
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --keep)
      keep="$2"
      shift 2
      ;;
    -h | --help)
      say "usage: ns-maint gc [--keep N]"
      return 0
      ;;
    *) die "gc: unknown argument '$1'" ;;
    esac
  done
  say "gc: running nix-collect-garbage --keep $keep (generations are NOT deleted;"
  say "gc: ns-maint recovery roots in $NM_GCROOTS are honoured):"
  "$NM_NIX_STORE" --gc --keep "$keep"
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

  confirm   <txid> [--assume-new-connection]
            Bind the operator's yes to one transaction id, after checking local
            health AND that a NEW sshd session was accepted since the switch was
            armed. An old, still-open SSH socket proves nothing.

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

  gc        [--keep N]      Collection with generation retention. Never -d.

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
  -h | --help | help | "") usage ;;
  *) usage >&2; die "unknown command '$cmd'" ;;
  esac
}

main "$@"