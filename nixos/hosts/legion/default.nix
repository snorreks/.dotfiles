# nixos/hosts/sonny-laptop/default.nix
# Host module for the Lenovo Legion Pro 7 (primary machine).
{...}: {
  imports = [
    ./hardware.nix
    ./fan-control.nix
  ];

  # WLR_DRM_DEVICES with the NVIDIA node listed first (to make it the primary
  # renderer and cut the Intel-composite copy on the two external outputs) was
  # tried here and crashed the mango session at login — instantly, with zero
  # stderr captured anywhere in the journal, so there's nothing to diagnose
  # post-hoc. Reverted rather than retried blind. If this is revisited, prove
  # it from a TTY first (`WLR_DRM_DEVICES=... mango > /tmp/mango.log 2>&1`,
  # inspect the log) before it becomes the login-time default — mango's output
  # doesn't reach the journal, so that's the only way to see why it failed.
}
