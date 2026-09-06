# nixos/config/system/battery.nix
#
# Caps how full the battery is allowed to charge (opts.batteryChargeLimit).
# A lithium pack held at 100% ages far faster than one parked around 60-80%,
# which matters for any laptop that lives on AC — a docked desktop replacement,
# and especially a headless host that will sit plugged in for months.
#
# Deliberately NOT services.tlp: TLP has the thresholds too, but it is a
# whole-system power manager and would fight power-profiles-daemon, which is
# what actually drives power profiles here (see power-management.nix).
#
# There is no single kernel interface for this, so the script walks a fallback
# chain and reports which rung it landed on. On hardware exposing none of them
# it says so and changes nothing.
{
  pkgs,
  lib,
  opts,
  ...
}: let
  limit = opts.batteryChargeLimit;
  enabled = limit != null;

  applyLimit = pkgs.writeShellApplication {
    name = "battery-charge-limit";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      # Optional argument overrides the configured limit, for one-off testing
      # (`sudo battery-charge-limit 100` to top up before a trip).
      limit="''${1:-${toString limit}}"
      applied=0

      # Rung 1 — the generic power_supply threshold. Exposed by thinkpad_acpi,
      # recent ideapad_laptop/legion-laptop, asus-wmi, huawei-wmi and others.
      for bat in /sys/class/power_supply/BAT*; do
        end="$bat/charge_control_end_threshold"
        start="$bat/charge_control_start_threshold"
        [ -w "$end" ] || continue

        # Some firmware rejects an end threshold at or below the start one, so
        # drop start out of the way first. Failure here is not fatal: plenty of
        # machines expose a writable end and a read-only start.
        if [ -w "$start" ]; then
          if [ "$limit" -gt 5 ]; then
            printf '%s\n' "$((limit - 5))" > "$start" || true
          else
            printf '0\n' > "$start" || true
          fi
        fi

        printf '%s\n' "$limit" > "$end"
        echo "battery: $(basename "$bat") charge limited to ''${limit}%"
        applied=1
      done

      # Rung 2 — older ideapad_laptop offers only "conservation mode", a
      # boolean that pins the pack at roughly 60%. Treat any limit of 80 or
      # below as a request for it; above that, off is the closer match.
      if [ "$applied" -eq 0 ]; then
        for cm in /sys/bus/platform/drivers/ideapad_acpi/*/conservation_mode; do
          [ -w "$cm" ] || continue
          if [ "$limit" -le 80 ]; then
            printf '1\n' > "$cm"
          else
            printf '0\n' > "$cm"
          fi
          echo "battery: ideapad conservation mode -> $(cat "$cm") (requested ''${limit}%)"
          applied=1
        done
      fi

      if [ "$applied" -eq 0 ]; then
        echo "battery: no writable charge threshold on this hardware; firmware left alone" >&2
      fi
    '';
  };
in {
  systemd.services.battery-charge-limit = lib.mkIf enabled {
    description = "Cap battery charge at ${toString limit}%";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe applyLimit;
    };
  };

  # Several firmwares forget the threshold across a suspend/resume cycle.
  powerManagement.resumeCommands = lib.mkIf enabled "${lib.getExe applyLimit}";

  # On PATH so the limit can be raised by hand before travelling with it.
  environment.systemPackages = lib.mkIf enabled [applyLimit];
}
