# nixos/config/system/battery.nix
#
# Caps how full the battery is allowed to charge (opts.batteryChargeLimit).
# A lithium pack held at 100% ages far faster than one parked around 60-80%,
# which matters for any laptop that lives on AC — a docked desktop replacement,
# and especially a server that will sit plugged in for months.
#
# Deliberately NOT services.tlp: TLP has the thresholds too, but it is a
# whole-system power manager and would fight power-profiles-daemon, which is
# what actually drives power profiles here (see power-management.nix).
#
# There is no single kernel interface for this, so config/system/battery/
# charge-limit.sh walks a fallback chain and REPORTS which rung it landed on
# and what limit it actually achieved. It is a separate file, not a heredoc,
# because that reporting is the part worth testing and a battery is not
# something a test machine has.
{
  pkgs,
  lib,
  opts,
  ...
}: let
  limit = opts.batteryChargeLimit;
  enabled = limit != null;

  chargeLimit = "${pkgs.runtimeShell} ${./battery/charge-limit.sh}";
in {
  systemd.services.battery-charge-limit = lib.mkIf enabled {
    description = "Cap battery charge at ${toString limit}%";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${chargeLimit} ${toString limit}";
    };
    # Failing is correct and visible. The script exits non-zero when it achieved
    # nothing, and with RemainAfterExit that leaves the unit in `failed` where
    # `systemctl status battery-charge-limit` says so — rather than a green
    # oneshot next to a pack that has been at 100% since it was installed.
  };

  # Several firmwares forget the threshold across a suspend/resume cycle.
  powerManagement.resumeCommands = lib.mkIf enabled "${chargeLimit} ${toString limit}";

  # On PATH so the limit can be raised by hand before travelling with it, and
  # the state can be checked without reading sysfs:
  #   battery-charge-limit            # apply the configured limit, report it
  #   battery-charge-limit 100        # one-off override (e.g. before a flight)
  environment.systemPackages = lib.mkIf enabled [
    (pkgs.writeShellApplication {
      name = "battery-charge-limit";
      runtimeInputs = [pkgs.coreutils];
      text = "exec ${chargeLimit} \"$@\"";
    })
  ];
}
