# nixos/hosts/legion/options.nix
#
# Per-host overrides for the Legion — only values that differ from the base
# (nixos/options.nix) belong here; everything else is shared.
{
  # Desktop setup: laptop + Acer VG272U V (HDMI-A-1) + ASUS MB16AC
  # (DP-1, rotated 90° via rr:1). Positions: eDP-1 @ 0, HDMI @ 2560,
  # DP-1 @ 5120 (2560 + 2560).
  monitorrule = [
    "name:^eDP-1$,width:2560,height:1600,refresh:240,x:0,y:0,scale:1,rr:0,vrr:1"

    # Acer VG272U V — 1440p @ 144Hz (right of laptop)
    "name:^HDMI-A-1$,width:2560,height:1440,refresh:144,x:2560,y:0,scale:1,rr:0,vrr:1"

    # ASUS MB16AC — 1080p @ 60Hz Portrait (far right, rotated 270° via rr:3,
    # i.e. upside-down portrait)
    "name:^DP-1$,width:1920,height:1080,refresh:60,x:5120,y:0,scale:1,rr:3,vrr:0"
  ];

  # The mouse pairs through the Bolt receiver here, not Bluetooth as on the
  # gs65, and the two report the thumb wheel's horizontal axis with opposite
  # signs. Flip it back so a flick to the right raises the volume on both.
  mouse.thumbWheelInvert = true;

  # Impermanence is OFF (base default).
  enablePersistence = false;

  # ── Basement server ────────────────────────────────────────────────────────
  # This machine is destined to stay behind as an always-on box reached over
  # the tailnet. Until then it is a normal three-monitor desktop.
  #
  # BEFORE TRAVEL: flip both of these, rebuild, and work through the checklist
  # in docs/headless-server.md (BIOS auto-power-on, tailnet IP, ethernet).
  #
  #   headless           = true;
  #   batteryChargeLimit = 60;
  #
  headless = false;

  # 80 while it is a daily driver; 60 once it is parked and permanently on AC.
  batteryChargeLimit = 80;
}
