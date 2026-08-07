# nixos/hosts/gs65/fan-control.nix
#
# MSI GS65 Stealth fan control via nbfc-linux. ec_sys write support lets
# nbfc poke the embedded controller directly — only ever load this on the
# GS65, never on other hardware.
{pkgs, ...}: {
  environment.systemPackages = [pkgs.nbfc-linux];

  boot.kernelModules = ["ec_sys"];
  boot.kernelParams = ["ec_sys.write_support=1"];
}
