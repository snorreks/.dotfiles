# nixos/config/home/clipboard.nix
{pkgs, ...}: let
  # Shared hardening for every clipboard watcher.
  #
  # Ordering: mango runs ~/.config/mango/autostart.sh (which starts
  # mango-session.target -> graphical-session.target) BEFORE its Wayland socket
  # is accepting connections. Every watcher therefore reliably loses its first
  # few connect attempts with "Connection refused". With the systemd default
  # rate limit (5 starts / 10s) that burns the budget and the unit is left
  # dead for the whole session — journal from 2026-08-11 shows exactly this:
  #   wl-clip-persist.service: Start request repeated too quickly.
  #   wl-clip-persist.service: Failed with result 'start-limit-hit'.
  # StartLimitIntervalSec=0 disables the rate limit so the retry loop always
  # wins the race, and Restart=always covers clean exits (compositor restart)
  # in addition to failures.
  watcher = description: exec: {
    Unit = {
      inherit description;
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
      StartLimitIntervalSec = 0;
    };
    Service = {
      ExecStart = exec;
      Restart = "always";
      RestartSec = 1;
    };
    Install.WantedBy = ["graphical-session.target"];
  };
in {
  home.packages = with pkgs; [
    cliphist # Clipboard history manager
    wl-clipboard # Provides `wl-copy` and `wl-paste`
  ];

  systemd.user.services = {
    cliphist-clipboard =
      watcher "cliphist watcher (clipboard selection)"
      "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store";

    # Images are a separate wl-paste invocation — `--type text` ignores them,
    # so screenshots/copied images never reached the history before.
    cliphist-image =
      watcher "cliphist watcher (images)"
      "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store";

    cliphist-primary =
      watcher "cliphist watcher (primary selection)"
      "${pkgs.wl-clipboard}/bin/wl-paste --primary --type text --watch ${pkgs.cliphist}/bin/cliphist store";
  };

  # ── Why wl-clip-persist is NOT here ─────────────────────────────────────
  # It was the cause of the intermittent "copy did nothing" bug.
  #
  # wl-clip-persist keeps the clipboard alive across app exit by *taking
  # ownership* of every new selection: it reads the source app's data, destroys
  # the app's wl_data_source, and installs its own. That handover leaves a
  # 10-25ms window in which the clipboard is genuinely empty. Measured on this
  # machine (160 copy/paste round-trips per configuration):
  #
  #   wl-clip-persist running       ->  8/160 pastes returned empty
  #   wl-clip-persist stopped       ->  0/120 pastes returned empty
  #   --clipboard regular only      ->  9/80  (no better; not a primary-sel issue)
  #   + -e --all-mime-type-regex    ->  7/80  (no better; not a MIME issue)
  #
  # It gets worse across monitors because mango runs sloppyfocus=1: crossing a
  # monitor boundary changes keyboard focus, the compositor re-delivers
  # wl_data_device.selection to the newly focused window, and if that lands in
  # the handover gap the window caches "no selection" until the *next* copy —
  # which is why the failure feels sticky and needs a re-copy.
  #
  # cliphist already covers the actual need: history survives app exit and
  # reboot, and SUPER+V (fuzzel-clipboard) restores any entry. Losing "clipboard
  # survives app close" costs one keypress; keeping it cost ~5% of all copies.
}
