# nixos/config/system/maintenance/package.nix
#
# The ns-maint derivation, factored out of maintenance.nix for exactly one
# reason: so the NixOS VM test can install the SAME package the Legion installs.
#
# A test that builds its own copy of the tool under test is a test of the copy.
# Keeping this in one file means `nix build .#maintenance-vm` boots the
# derivation that will actually be on the machine, and there is no way for the
# two to drift.
{
  lib,
  writeShellApplication,
  coreutils,
  findutils,
  gawk,
  gnugrep,
  inetutils,
  nix,
  systemd,
  util-linux,
}:
writeShellApplication {
  name = "ns-maint";

  runtimeInputs = [
    coreutils
    findutils
    gawk
    gnugrep
    inetutils
    nix
    systemd
    util-linux # flock — the thing that serialises transactions
  ];

  # writeShellApplication runs shellcheck over this text at build time, so a
  # warning here is a build failure on every host. That is intended: this file
  # is the tool that owns the reboot-free maintenance contract.
  text = builtins.readFile ./ns-maint.sh;
}
