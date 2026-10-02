# protonup-ng 0.2.1 is still the newest release on PyPI and is what nixpkgs
# ships, but it broke when GE-Proton started publishing one tarball per
# architecture (GE-Proton11-6 onwards):
#
#   * api.py derives the install directory from the release *tag*
#     (GE-Proton11-7), while the tarball it downloads extracts to
#     GE-Proton11-7-x86_64. The following write of the sha512sum marker then
#     dies with FileNotFoundError, after the ~500 MiB download has completed —
#     so `protonup` never installs anything and never records the version.
#   * remove_proton() only looks for the unsuffixed directory, so
#     `protonup -r GE-Proton11-7` can no longer remove anything either.
#
# The patch fixes both by taking the directory name from the downloaded asset.
# It is applied via overrideAttrs (rather than re-implementing the derivation)
# so upstream package changes keep flowing in; drop this file once nixpkgs (or
# protonup-ng itself) ships the fix.
final: prev: {
  protonup-ng = prev.protonup-ng.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./protonup-ng-ge-per-arch.patch ];
  });
}