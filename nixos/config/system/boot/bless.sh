#!/usr/bin/env bash
# nixos/config/system/boot/bless.sh — run systemd-bless-boot without letting a
# routine no-op fail the unit.
#
# ── Why this file exists ─────────────────────────────────────────────────────
# `systemd-bless-boot good` exits 1 with
#
#     Not booted with boot counting in effect.
#
# whenever the booted entry carries no counter — which is the ordinary state on
# every boot AFTER a blessing. NixOS says as much itself (systemd.nix: "`systemd-bless-boot
# good` fails once the current boot has been blessed").
#
# The unit still has to be in the boot graph (see boot.nix: nothing else pulls
# it in), so without this wrapper a plain wantedBy would leave a FAILED unit on
# every routine boot. That is not cosmetic: a failed unit makes
# switch-to-configuration exit 4, which ns-maint reads as "activation failed"
# and rolls the whole activation back. That exact failure was observed live —
# the first version of this wrapper called the binary by name, it was not on
# PATH (it lives in $pkg/lib/systemd, not $pkg/bin), exited 127, and took an
# otherwise healthy activation down with it.
#
# So: exactly that one message is a no-op success. Every other failure passes
# through untouched — a real blessing failure must never look like a good boot.
#
# NM_BLESS_BOOT points at the real binary and is set by the unit (see
# boot.nix), which is where the path is declared, asserted and kept honest —
# substituting it into this file instead made the target invisible to
# `nix eval`, so nothing could check it. Required rather than defaulted: a
# silently empty value would make the invocation fail in a way that looks like
# a blessing failure rather than a missing setting.
set -o errexit -o nounset -o pipefail

: "${NM_BLESS_BOOT:?NM_BLESS_BOOT must be set by the unit (boot.nix)}"

status=0
output="$("$NM_BLESS_BOOT" good 2>&1)" || status=$?

if ((status == 0)); then
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi
  exit 0
fi

# Still surface the real message: when the exit code is a genuine failure, the
# journal needs the reason, not silence.
printf '%s\n' "$output" >&2

case "$output" in
  *"Not booted with boot counting in effect."*)
    exit 0
    ;;
esac

exit "$status"