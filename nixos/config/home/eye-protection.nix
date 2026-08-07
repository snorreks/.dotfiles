# nixos/config/home/eye-protection.nix
{opts, ...}: {
  services.wlsunset = {
    enable = true;

    # Coordinates pulled dynamically from nixos/options.nix
    latitude = opts.latitude;
    longitude = opts.longitude;

    # Color temperatures in Kelvin
    temperature = {
      day = 6500;
      night = 3500;
    };

    # Transition duration in seconds around sunset/sunrise
    gamma = 1.0;
  };
}
