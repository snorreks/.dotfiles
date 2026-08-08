# nixos/config/system/cache-cleanup.nix
#
# `/home` is persistent and never wiped (see persistence.nix) — the home
# directory has too much varied, real tool state to safely maintain an
# allowlist for. The one thing that does grow unbounded there is ~/.cache,
# so age it out instead of wiping/allowlisting the whole home directory.
#
# Not everything under ~/.cache is a true cache: nix keeps structured state
# here (tarball-cache-v2 is a git repository that libgit2 must be able to
# open; the eval/fetcher caches are sqlite databases). Aging out loose git
# objects corrupts the repo, which made `nh` fail with "could not find
# repository at .../tarball-cache-v2". Exclude the whole subtree — `x`
# ignores the path and everything below it (uppercase `X` would only spare
# the directory itself and still clean its contents).
{opts, ...}: {
  systemd.tmpfiles.rules = [
    # nix cache is a git repo + sqlite databases; age-based deletion corrupts it
    "x /home/${opts.username}/.cache/nix"
    "e /home/${opts.username}/.cache - - - 60d"
  ];
}
