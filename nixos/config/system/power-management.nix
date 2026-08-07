# nixos/config/system/power-management.nix
{...}: {
  # --- Systemd Login Manager (logind) ---
  # Configure system behavior on events like closing the laptop lid.
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
  # --- Primary Power Management Tool: TLP ---
  # TLP is a comprehensive tool for managing power settings based on AC vs. Battery state.
  # We are disabling other conflicting power managers.

  # CONFLICT: Disable other power management daemons to let TLP take full control.
  services.system76-scheduler.enable = false;
  powerManagement.powertop.enable = false; # Disables powertop's auto-tuning on boot.

  # REPLACEMENT: Use the modern, standard power-profiles-daemon.
  # It integrates well with the kernel and other services without conflicting.
  # CONFLICT: Disabled — TLP manages CPU governors directly; power-profiles-daemon conflicts.
  services.power-profiles-daemon.enable = false;

  # Enable the thermal daemon for Intel CPUs to prevent overheating.
  # It works alongside TLP and does not conflict.
  services.thermald.enable = true;

  # --- TLP Detailed Settings ---
  services.tlp.settings = {
    # --- General Behavior ---
    # Defines the default power saving state. 1 is enabled.
    TLP_ENABLE = 1;
    # TLP's default mode. Can be changed on the fly with `tlp ac` or `tlp bat`.
    TLP_DEFAULT_MODE = "AC";

    # --- AC Power Settings (Plugged In) ---
    # OPTIMIZED: Use the kernel's modern 'schedutil' or 'ondemand' governor instead of 'performance'.
    # The 'performance' governor pegs the CPU at max frequency, generating excess heat and
    # paradoxically reducing turbo-boost headroom. 'schedutil' is much smarter.
    CPU_SCALING_GOVERNOR_ON_AC = "schedutil";

    # This is the correct way to hint for performance. It tells the kernel to prioritize
    # high clock speeds when making scaling decisions.
    CPU_ENERGY_PERF_POLICY_ON_AC = "performance";

    # Allow the CPU to use its full frequency range, from idle to max boost.
    CPU_MIN_PERF_ON_AC = 0;
    CPU_MAX_PERF_ON_AC = 100;
    CPU_BOOST_ON_AC = 1; # Allow turbo boost.

    # --- Battery Power Settings ---
    CPU_SCALING_GOVERNOR_ON_BAT = "powersave";

    # Hint to the kernel to prioritize saving power.
    CPU_ENERGY_PERF_POLICY_ON_BAT = "power";

    # OPTIMIZED: 25% is extremely low and will make the laptop feel sluggish.
    # A value around 70-80% provides a good balance of battery life and responsiveness.
    # The 'powersave' governor is already very effective.
    CPU_MIN_PERF_ON_BAT = 0;
    CPU_MAX_PERF_ON_BAT = 75;
    CPU_BOOST_ON_BAT = 0; # Disabling boost on battery is a major power saver.

    # CRITICAL FIX: Setting this to 1 RE-ENABLES the audio power saving that causes
    # your audio to die. It must be set to 0 to respect our kernel-level fix.
    # BOTH variants are required: TLP applies the AC value when plugged in and
    # was silently re-enabling power-save (kernel default 10 s) on AC.
    SOUND_POWER_SAVE_ON_AC = 0;
    SOUND_POWER_SAVE_ON_BAT = 0;
    # Keep the HDA controller awake as well; "Y" lets it suspend and take the
    # speaker amps down with it.
    SOUND_POWER_SAVE_CONTROLLER = "N";

    # Controls power management for PCIe devices. 'auto' is the recommended setting.
    RUNTIME_PM_ON_BAT = "auto";

    # --- Battery Care (Lenovo Specific) ---
    # These settings require `acpi_call` to be loaded, which you already have in your boot config.
    # Start charging the battery only when it drops below 75%.
    # START_CHARGE_THRESH_BAT0 = 75;

    # CRITICAL FIX: Your value of '1' would prevent the battery from charging past 1%.
    # This sets the threshold to stop charging at 80% to preserve long-term battery health.
    # STOP_CHARGE_THRESH_BAT0 = 80;
  };
}
