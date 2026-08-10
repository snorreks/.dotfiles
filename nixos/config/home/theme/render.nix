# nixos/config/home/theme/render.nix
#
# Target-format renderers, extracted from the old monolithic lib.nix.
#
# These serialize a settings/colors attrset into the file format each
# consumer expects. They are format plumbing only — no palette logic.
{lib}: {
  # swaylock: `key=value`, booleans as bare keys, false omitted
  renderSwaylock = settings:
    lib.concatStringsSep "\n" (
      lib.filter (s: s != null) (
        lib.mapAttrsToList (k: v:
          if v == true
          then k
          else if v == false
          then null
          else "${k}=${toString v}")
        settings
      )
    );

  # fuzzel: ini `key=value` inside a [colors] section
  renderFuzzelColors = colors:
    "[colors]\n"
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k}=${v}") colors
    );

  # mango: `key = value` lines (mango's own format, spaces around =)
  renderMangoColors = colors:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k} = ${v}") colors
    );
}
