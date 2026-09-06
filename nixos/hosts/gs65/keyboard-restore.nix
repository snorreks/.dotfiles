# nixos/hosts/gs65/keyboard-restore.nix
#
# Home-side half of keyboard-rgb.nix: msi-perkeyrgb is write-only — the
# keyboard will tell you nothing about its current colour — so the dashboard
# records what it last set in ~/.cache/dashboard/kbd.json, and this replays it
# once per session. Without it the lighting reverts to whatever the firmware
# defaults to after every power cycle, and the panel would show a colour the
# keyboard isn't actually displaying.
#
# This slot used to hold power-hook.nix, a 5-second poll that pushed the PPD
# profile into nbfc-linux. It is gone with nbfc (see fan-control.nix for why
# nbfc could never have worked on this machine); fan mode is now an explicit
# control in the dashboard's Cooling card rather than something inferred from
# the power profile.
{config, ...}: {
  systemd.user.services.keyboard-rgb-restore = {
    Unit = {
      Description = "Restore the last keyboard RGB colour set from the dashboard";
      After = ["graphical-session-pre.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      # No-ops (exit 0) when there is no saved state or no keyboard, so this
      # stays inert on a fresh install.
      ExecStart = "${config.home.profileDirectory}/bin/dashboard-kbd restore";
    };
    Install.WantedBy = ["graphical-session.target"];
  };
}
