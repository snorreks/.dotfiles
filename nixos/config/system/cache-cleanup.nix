# nixos/config/system/cache-cleanup.nix
#
# `/home` is persistent and never wiped (see persistence.nix) — the home
# directory has too much varied, real tool state to safely maintain an
# allowlist for. The one thing that does grow unbounded there is ~/.cache,
# so age it out instead of wiping/allowlisting the whole home directory.
{opts, ...}: {
  systemd.tmpfiles.rules = [
    "e /home/${opts.username}/.cache - - - 60d"
  ];
}
