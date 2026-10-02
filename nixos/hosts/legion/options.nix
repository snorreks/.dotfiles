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

  # ── Phone → herdr over Tailscale ───────────────────────────────────────────
  # The Legion is the host this is for: it stays on and runs the agents worth
  # reaching from a phone. Collie is the PRIMARY Android interface; the SSH /
  # Mosh path stays as a client-independent fallback.
  #
  # Opting in here adds, and only adds:
  #
  #   SHARED (mobileAgents.enable):
  #     * a second sshd listener on 2222, key-only, reachable via tailscale0 —
  #       port 22 and Tailscale SSH are left exactly as they were, as the
  #       recovery path;
  #     * mosh-server bounded to UDP 60000-60010, opened on no other interface;
  #     * `linger`, so the herdr server starts at boot and survives logout.
  #
  #   COLLIE (mobileAgents.collie.enable):
  #     * the collie bridge, a systemd user service reading the SAME herdr
  #       socket as the desktop;
  #     * a private Tailscale Serve mapping, https://<serveHosts> →
  #       http://127.0.0.1:8787 — tailnet-only, HTTPS with a real certificate.
  #
  #   MOSHI (mobileAgents.moshi.enable) — off here, see below.
  #
  # Deliberately INDEPENDENT of headless: this stays a normal three-monitor
  # desktop that autologins into mango and sleeps when closed. Daily-driver use
  # is unchanged.
  #
  # 🔴 phoneAuthorizedKey is still null (the base default). Fill in the key
  # generated ON THE PHONE before the 2222/Mosh fallback is useful — see
  # docs/mobile-agents.md. Until then the build warns and port 2222 has no key
  # authorized. Deliberately not invented here: a key generated on the host and
  # copied down would defeat the point of the phone holding the only copy of
  # its own key. Collie needs none of that — it is a browser on the tailnet and
  # reaches nothing but port 443 on this machine.
  mobileAgents = {
    enable = true;

    collie = {
      enable = true;

      # The tailnet login allowed to drive the agents, i.e. exactly the value
      # of the Tailscale-User-Login header. This gate FAILS CLOSED: with it
      # unset or wrong, Collie refuses every request rather than every request
      # from someone else. config/home/collie.nix asserts it is non-null and
      # non-empty, so a generation with no gate at all will not build.
      #
      # Verify with: tailscale status --json | jq -r '.Self.UserID.email'
      trustedUser = "snorrekstrand@hotmail.com";

      # This machine's MagicDNS name. Check it any time with:
      #   tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")'
      # It is both the Serve hostname and Collie's Host-header allowlist, and a
      # stale value here is the single most likely cause of a phone that loads
      # a blank page with no error.
      serveHosts = ["legion.tailf24d02.ts.net"];
    };

    # Moshi is the SECONDARY client, and it is switched OFF on this host.
    #
    # Nothing about it is broken; turning it back on is one boolean and a
    # rebuild. It is off because the two clients notify INDEPENDENTLY:
    # moshi-hook posts agent events to Moshi's servers, while Collie derives
    # its own notifications by polling the multiplexer and pushes them through
    # this host's own VAPID keys. With both subscribed, one agent waiting for
    # input produces two phone notifications, and there is no upstream way to
    # merge them.
    #
    # Stated HERE rather than left at the base default so the choice shows up
    # in this file's diff instead of having to be looked up.
    moshi = {
      enable = false;
    };
  };
}
