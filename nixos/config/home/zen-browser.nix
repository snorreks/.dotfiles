# nixos/config/home/zen-browser.nix
# Zen Browser — declarative setup with uBlock, transparency, and Nix search engines
{
  inputs,
  pkgs,
  lib,
  config,
  ...
}: let
  # Accent follows the static palette baseline (build-time). Set as a
  # defaultPref (NOT lockPref) so it stays user-overridable / changeable.
  accent = "#${config.lib.stylix.colors.base0D}";

  # We let firefox account sync extensions
  prefs = {
    # --- Transparency / Glass ---
    "widget.transparent-windows" = true;
    "zen.theme.gradient.show-custom-colors" = true;
    "zen.view.use-single-toolbar" = true;
    "zen.view.compact-mode.hide-toolbar" = true;
    "zen.view.sidebar-expanded" = false;

    # --- Performance ---
    "gfx.webrender.all" = true;
    "media.ffmpeg.vaapi.enabled" = true;
    "widget.wayland.fractional-scale.enabled" = true;

    # --- Screen Sharing (PipeWire / xdg-desktop-portal-wlr) ---
    "media.webrtc.capture.allowpipewire" = true;
    "media.webrtc.capture.remotecapture.enabled" = true;

    # --- Privacy ---
    "extensions.autoDisableScopes" = 0;
    "extensions.pocket.enabled" = false;
  };
in {
  home.packages = [
    (
      pkgs.wrapFirefox
      inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.zen-browser-unwrapped
      {
        extraPrefs = lib.concatLines (
          [
            # Accent is a defaultPref (overridable at runtime/user.js)
            ''defaultPref(${lib.strings.toJSON "zen.theme.accent-color"}, ${lib.strings.toJSON accent});''
          ]
          ++ lib.mapAttrsToList (
            name: value: ''lockPref(${lib.strings.toJSON name}, ${lib.strings.toJSON value});''
          )
          (prefs
            // {
              "media.getusermedia.screensharing.enabled" = true;
              "media.webrtc.capture.allowpipewire" = true;
            })
        );

        extraPolicies = {
          DisableTelemetry = true;

          SearchEngines = {
            Default = "ddg";
            Add = [
              {
                Name = "nixpkgs packages";
                URLTemplate = "https://search.nixos.org/packages?query={searchTerms}";
                IconURL = "https://wiki.nixos.org/favicon.ico";
                Alias = "@np";
              }
            ];
          };
        };
      }
    )
  ];
}
