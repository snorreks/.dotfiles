#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# calendar-open.sh — Jump to Thunderbird's calendar tab
# ═══════════════════════════════════════════════════════════════════════════════
#
# Bound to a left click on waybar's clock / agenda modules (see waybar/settings.nix).
#
# Thunderbird is started silently on tag 9 (mango tagrule, config/home/mango.nix),
# so a plain `thunderbird -calendar` would switch the running instance to the
# Calendar tab without ever showing it. We therefore raise the window too —
# wlrctl first (same idiom as the SUPER+c editor binding), falling back to
# mango's `view` dispatch for tag 9 if there is no toplevel to focus yet.
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# -calendar is handled by the already-running instance via remoting; if none is
# running it starts Thunderbird straight into the calendar tab.
thunderbird -calendar >/dev/null 2>&1 &

for _ in 1 2 3 4 5 6 7 8 9 10; do
    if wlrctl toplevel focus app_id:thunderbird >/dev/null 2>&1; then
        exit 0
    fi
    sleep 0.3
done

# No toplevel yet (cold start): switch to the tag Thunderbird opens on.
mmsg dispatch view,9,0 >/dev/null 2>&1 || true
