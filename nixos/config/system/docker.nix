# nixos/config/system/docker.nix
{pkgs, ...}: {
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  # Fix for "Value too large for defined data type" (EOVERFLOW) error.
  # We switch from the default 'crun' to 'runc'.
  virtualisation.containers.containersConf.settings = {
    engine = {
      runtime = "runc";
      # ERROR FIX: 'runc' must be a list of paths to check, not a table.
      runtimes = {
        runc = ["${pkgs.runc}/bin/runc"];
      };
    };
  };

  # AUTOMATION: This generates the CDI config so Podman sees the RTX 4090
  hardware.nvidia-container-toolkit.enable = true;

  environment.systemPackages = with pkgs; [
    docker-compose
    podman-compose
    runc
  ];
}
