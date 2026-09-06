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
  # Modern, standards-based power profile management for laptops.
  # Natively drives platform_profile (performance/balanced/power-saver) and provides polkit
  # rules so your user can switch profiles without sudo. powerprofilesctl integrates seamlessly
  # with gamemode for automatic performance/balanced switching during gameplay.
  services.power-profiles-daemon.enable = true;

  # Disable conflicting power management daemons.
  services.system76-scheduler.enable = false;
  powerManagement.powertop.enable = false;

  # Enable the thermal daemon for Intel CPUs to prevent overheating.
  # It works alongside power-profiles-daemon and does not conflict.
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
