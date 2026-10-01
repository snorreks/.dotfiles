# nixos/config/system/power-management.nix
{...}: {
  # --- Systemd Login Manager (logind) ---
  # Configure system behavior on events like closing the laptop lid.
  #
  # NOTE: a headless host overrides all of this (with mkForce) in
  # config/system/server.nix — there, nothing may ever suspend.
  services.logind = {
    settings = {
      Login = {
        # When external power is connected (i.e., docked), closing the lid does nothing.
        # This is ideal for using the laptop with external monitors.
        HandleLidSwitchExternalPower = "ignore";
        # When on battery, suspend the system when the lid is closed.
        # You can set this to "ignore" if you never want it to suspend on lid close.
        HandleLidSwitch = "suspend";
      };
    };
  };

  # --- Primary Power Management Tool: power-profiles-daemon ---
  # Modern, standards-based power profile management for laptops. Provides
  # polkit rules so the user can switch profiles without sudo, and
  # powerprofilesctl integrates with gamemode for automatic
  # performance/balanced switching during gameplay.
  #
  # PPD is the source of truth for CPU policy (intel_pstate / EPP). It is NOT
  # the source of truth for cooling: on the Legion its platform_profile driver
  # is blocked (hosts/legion/power.nix) because that driver and the Legion's
  # powermode attribute are two doors onto the same EC register. See that file
  # for the ownership split; the GS65 is unaffected.
  services.power-profiles-daemon.enable = true;

  # Disable conflicting power management daemons.
  services.system76-scheduler.enable = false;
  powerManagement.powertop.enable = false;

  # thermald is enabled by default here, but the Legion disables it
  # (hosts/legion/power.nix): its adaptive policy cannot create zones on that
  # model (missing PSVT sensors) and it falls back to a generic config that
  # matches nothing. The GS65 keeps it.
  services.thermald.enable = true;

  # Audio fix: prevent HDA power-save from breaking sound on suspend/resume.
  boot.extraModprobeConfig = ''
    options snd_hda_intel power_save=0
  '';

  # Suspend fix: systemd >=256 freezes user.slice via cgroups before handing
  # off to the kernel's own suspend freezer. That cgroup freeze is known to
  # hang/time out with the NVIDIA proprietary driver (NixOS/nixpkgs#371058),
  # burning ~60s on "Failed to freeze unit 'user.slice': Connection timed
  # out" before suspend even reaches the real freezer. Disabling it skips
  # straight to the kernel freezer, which is what actually matters.
  systemd.services.systemd-suspend.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS = "false";
}
