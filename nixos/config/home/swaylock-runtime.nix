# nixos/config/home/swaylock-runtime.nix
#
# Shared derivation for the `swaylock-runtime` wrapper (prefers the
# matugen-rendered config, falls back to the HM-managed one). Callers:
# swaylock.nix (installs it + mango/wlogout keybinds reference it by bare
# name), idle.nix (invoked by swayidle, which runs under a minimal PATH —
# needs the full store path). The wrapped `swaylock` binary is referenced by
# full store path for the same reason: it must work regardless of caller PATH.
{pkgs, ...}:
pkgs.writeShellScriptBin "swaylock-runtime" ''
  cfg="$HOME/.cache/theme/swaylock.conf"
  if [ -f "$cfg" ]; then
    exec ${pkgs.swaylock-effects}/bin/swaylock --config "$cfg" "$@"
  fi
  exec ${pkgs.swaylock-effects}/bin/swaylock "$@"
''
