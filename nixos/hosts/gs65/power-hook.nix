# nixos/hosts/gs65/power-hook.nix
#
# GS65-specific power profile hook: syncs nbfc-linux fan profile to match
# the active PPD power profile.
#
#   performance → aggressive cooling
#   balanced    → standard cooling
#   power-saver → quiet cooling
#
# Polls every 5s (trivial — nbfc reads sysfs, no subprocess chain).
# On legion this module is never imported (hostname guard in the flake).
{pkgs, ...}: let
  powerHookScript = pkgs.writeShellScriptBin "power-mode-hook-daemon" ''
    set -euo pipefail

    # Cache the last-known profile so we only call nbfc on change.
    last=""

    while true; do
        current="$(${pkgs.power-profiles-daemon}/bin/powerprofilesctl get 2>/dev/null || echo "unknown")"
        if [ "$current" != "$last" ]; then
            last="$current"
            case "$current" in
                performance)
                    ${pkgs.nbfc-linux}/bin/nbfc set -a -s performance 2>/dev/null \
                        || ${pkgs.nbfc-linux}/bin/nbfc set -a -s aggressive 2>/dev/null \
                        || true
                    ;;
                power-saver)
                    ${pkgs.nbfc-linux}/bin/nbfc set -a -s silent 2>/dev/null \
                        || ${pkgs.nbfc-linux}/bin/nbfc set -a -s quiet 2>/dev/null \
                        || true
                    ;;
                balanced)
                    ${pkgs.nbfc-linux}/bin/nbfc set -a -s balanced 2>/dev/null || true
                    ;;
            esac
        fi
        sleep 5
    done
  '';
in {
  home.packages = [powerHookScript];

  systemd.user.services.power-mode-hook = {
    Unit = {
      Description = "Sync nbfc-linux fan profile to PPD power profile";
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = "${powerHookScript}/bin/power-mode-hook-daemon";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };
}
