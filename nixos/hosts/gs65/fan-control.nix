# nixos/hosts/gs65/fan-control.nix
#
# MSI GS65 Stealth fan control via the msi-ec kernel module.
#
# This used to be nbfc-linux + `ec_sys.write_support=1`, which could never
# have worked: nbfc drives the EC from a per-model JSON profile, and there is
# no GS65 profile — not in the 311 configs nbfc-linux ships, and not in
# upstream NBFC either (its Configs/ directory contains no MSI models at all).
# `nbfc config -r` on this machine answers "No recommended configuration files
# found", and the service was never enabled, so nothing was controlling fans.
#
# msi-ec knows this machine. The GS65 Stealth 8S/9S family is board MS-16Q4,
# EC firmware 16Q4EMS1.*, which the driver matches to CONF_G1_3:
#
#   fan_mode      0xf4  auto 0x0d / silent 0x1d / advanced 0x8d
#   cooler_boost  0x98  bit 7
#   shift_mode    0xf2  eco / comfort / sport / turbo
#
# The driver refuses to bind unless the EC firmware version is on its
# allow-list, which is the safety property that matters here — a wrong match
# would be writing arbitrary bytes into the embedded controller. If it does
# not bind, /sys/devices/platform/msi-ec never appears and the dashboard's
# Cooling card stays hidden (see dashboard/qml/SystemView.qml); nothing else
# breaks.
#
# This machine reports 16Q4EMS1.109, and nixpkgs' msi-ec would not bind to it:
# its src is pinned to 2025-09-14, one day before upstream added .109. Hence
# the src override below.
#
# Do NOT "fix" this instead with the driver's firmware= parameter. Forcing
# nixpkgs' build to 16Q4EMS1.110 looks equivalent and is not: in that revision
# every 16Q4EMS1 lived in CONF_G1_9, and on 2025-09-25 upstream moved them to
# CONF_G1_3 because the fn-win swap reading is inverted between the two. The
# fan tables differ too — G1_9's middle mode is `basic` = 0x4d, G1_3's is
# `silent` = 0x1d — so forcing the old config would write the wrong byte for
# the mode the dashboard calls Silent. The version has to be matched by a
# build that knows about it, not asserted at one that doesn't.
#
# Revisit when nixpkgs' msi-ec advances past 2025-09-15: the override can then
# be deleted outright and the stock package will bind on its own. Check with
#   nix eval nixpkgs#linuxPackages.msi-ec.src.rev
{
  config,
  pkgs,
  ...
}: let
  # msi-ec's controls are sysfs attributes on a platform device, and udev's
  # GROUP=/MODE= only apply to device nodes in /dev — so the permissions have
  # to be set by hand from a RUN rule. Without this every fan-mode change
  # would need a root helper, which is a lot of machinery for three bytes.
  #
  # shift_mode is in the list even though no dashboard card drives it: it is
  # the CPU-side half of the same EC, and exposing it would duplicate the
  # Power mode card that already talks to power-profiles-daemon. Writable so
  # it can be poked from a shell, not wired to a widget.
  msi-ec-perms = pkgs.writeShellScript "msi-ec-perms" ''
    dev=/sys/devices/platform/msi-ec
    for attr in fan_mode cooler_boost shift_mode; do
        [ -e "$dev/$attr" ] || continue
        ${pkgs.coreutils}/bin/chgrp users "$dev/$attr"
        ${pkgs.coreutils}/bin/chmod g+w "$dev/$attr"
    done
  '';

  # Pinned to an exact upstream revision rather than a branch: this is a module
  # that writes to the embedded controller from a per-firmware register map, so
  # "whatever main says today" is not an acceptable input.
  msi-ec = config.boot.kernelPackages.msi-ec.overrideAttrs (_: {
    version = "0-unstable-2026-08-09";
    src = pkgs.fetchFromGitHub {
      owner = "BeardOverflow";
      repo = "msi-ec";
      rev = "d7fbbd88e6831e56801b860e46475cbf8ddbc7c1";
      hash = "sha256-+XNrhKeltD5eaasqDOdQ/9/dcPf1H6z2N8hGB344POQ=";
    };

    # Both nixpkgs patches have to go, for unrelated reasons:
    #
    #   makefile.patch          — upstream split VERSION out into Makefile.vars
    #                             after the pinned revision, so its first hunk
    #                             no longer applies. Reimplemented below.
    #   kernel-string-choices   — a str_on_off/str_yes_no shim for kernels
    #                             older than 6.6. This machine is on 7.1.4.
    patches = [];

    # What makefile.patch was for: the build has no /lib/modules tree, so the
    # modules target has to take the kernel dir from KERNELDIR (already passed
    # in makeFlags), and upstream still ships no modules_install target for
    # `installTargets` to call.
    postPatch = ''
      substituteInPlace Makefile \
        --replace-fail '-C /lib/modules/$(KERNELRELEASE)/build M=$(CURDIR) modules' \
                       '-C $(KERNELDIR) M=$(CURDIR) modules'
      printf 'modules_install:\n\t@$(MAKE) -C $(KERNELDIR) M=$(CURDIR) modules_install\n' >>Makefile
    '';
  });
in {
  boot.extraModulePackages = [msi-ec];
  boot.kernelModules = ["msi-ec"];

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="platform", KERNEL=="msi-ec", RUN+="${msi-ec-perms}"
  '';
}
