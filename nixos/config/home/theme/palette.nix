# nixos/config/home/theme/palette.nix
#
# Palette plumbing, extracted from the old monolithic lib.nix.
#
# Everything downstream is a pure function of an attrset shaped like
# `config.lib.stylix.colors`:
#
#   { base00 = "1a1b26"; …; base0F = "f7768e";
#     withHashtag = { base00 = "#1a1b26"; … } }
#
# `matugenPalette` has the same shape but its values are matugen *template
# expressions*, so feeding it to any mkXxx yields a template file.
#
# ── Why MD3 roles instead of base16 ───────────────────────────────────────
# matugen's `base16.*` namespace goes through the `wal` backend, which
# re-derives the slots from raw image colors — no contrast contract. Some
# wallpapers yield base08-base0F at ~1.2:1 (invisible), and matugen's
# --contrast/--lightness-dark flags don't touch it (they mutate the MD3
# DynamicScheme, which wal never reads).
#
# The `colors.*` namespace is the real output: every MD3 role is pinned to a
# fixed HCT tone for dark mode (on_surface T90, primary/secondary/tertiary/
# error T80, outline T60), so contrast is guaranteed *by construction* for
# any wallpaper — verified on a dark image: on_surface ≈14:1, primary ≈11:1,
# outline ≈5.9:1 on the surface role.
#
# Accent slots that have no MD3 role (base09-0B/0F) inherit primary's
# tone+chroma and pin the semantic hue with `set_hue` — set_hue preserves
# lightness, so the tone guarantee holds and green stays green even on a
# monochrome wallpaper.
{lib}: rec {
  base16Names = [
    "base00"
    "base01"
    "base02"
    "base03"
    "base04"
    "base05"
    "base06"
    "base07"
    "base08"
    "base09"
    "base0A"
    "base0B"
    "base0C"
    "base0D"
    "base0E"
    "base0F"
  ];

  # MD3 role → matugen template expression. `hex_stripped` = bare hex,
  # `hex` = #rrggbb (for styles that want the leading '#').
  role = r: "{{ colors.${r}.dark.hex_stripped }}";
  roleHash = r: "{{ colors.${r}.dark.hex }}";

  # Semantic hue on primary's tone/chroma (set_hue preserves lightness).
  accent = h: "{{ colors.primary.dark.hex_stripped | set_hue: ${toString h} }}";
  accentHash = h: "{{ colors.primary.dark.hex | set_hue: ${toString h} }}";

  # base16 slot → role map. base0C/0D/0E keep the wallpaper's identity
  # (secondary/primary/tertiary — the most-used slots); base09-0B/0F pin
  # semantic hues so the palette reads the same on any wallpaper.
  slotExpr = {
    base00 = role "surface";
    base01 = role "surface_container_low";
    base02 = role "surface_container_high";
    base03 = role "outline";
    base04 = role "on_surface_variant";
    base05 = role "on_surface";
    # base07 as on_primary_container inverts to black at --contrast ≥ 0.5
    # (the container roles are guaranteed against their container, not against
    # surface — and fuzzel prompt / zed embedded / vesktop hovers all use it
    # on surface). on_surface is the guaranteed-bright text role.
    base06 = role "inverse_surface";
    base07 = role "on_surface";
    base08 = role "error";
    base09 = accent 50; # orange
    base0A = accent 90; # yellow
    base0B = accent 140; # green
    base0C = role "secondary";
    base0D = role "primary";
    base0E = role "tertiary";
    base0F = accent 20; # brown
  };
  slotExprHash = {
    base00 = roleHash "surface";
    base01 = roleHash "surface_container_low";
    base02 = roleHash "surface_container_high";
    base03 = roleHash "outline";
    base04 = roleHash "on_surface_variant";
    base05 = roleHash "on_surface";
    base06 = roleHash "inverse_surface";
    base07 = roleHash "on_surface";
    base08 = roleHash "error";
    base09 = accentHash 50;
    base0A = accentHash 90;
    base0B = accentHash 140;
    base0C = roleHash "secondary";
    base0D = roleHash "primary";
    base0E = roleHash "tertiary";
    base0F = accentHash 20;
  };

  matugenPalette =
    slotExpr
    // {
      withHashtag = slotExprHash;
    };

  # ── Template substitution ────────────────────────────────────────────
  # Lets a config live in a real .css / .conf file (with editor tooling)
  # instead of a Nix string, while still being instantiated twice.
  #
  #   substPalette c (builtins.readFile ./css/waybar.css)
  #
  # replaces `@base00@ … @base0F@` with the *bare* hex of that palette.
  substPalette = c: text:
    builtins.replaceStrings
    (map (n: "@${n}@") base16Names)
    (map (n: c.${n}) base16Names)
    text;

  # Same, for formats that want the leading '#'.
  substPaletteHash = c: text:
    builtins.replaceStrings
    (map (n: "@${n}@") base16Names)
    (map (n: c.withHashtag.${n}) base16Names)
    text;
}
