# nixos/config/home/agent-lifetime.nix
#
# The one place that answers "does an agent have to wait for a human to log in?".
#
# ── Why this is a separate file, and why it is pure ───────────────────────────
# The rule is a single boolean:
#
#     AGENT BOOT LIFETIME = opts.headless  OR  opts.mobileAgents.enable
#
# and it is split across two lanes on purpose. A (server foundation) owns the
# SYSTEM half — `linger`, sleep/lid policy, the second sshd listener — because
# that is host and network policy. B (this lane) owns the USER half: which
# target a user unit is WantedBy, whether it orders behind
# graphical-session.target, and whether its credentials are there when nobody
# has logged in. Neither half is the other. An A-only merge gives you a
# lingering user manager with nothing in it; a B-only merge gives you
# WantedBy=default.target on a host whose user manager is not started until
# first login. They are validated together on merged master, and until then each
# PR says so.
#
# It used to be `opts.mobileAgents.enable` alone, which made agent continuity a
# phone feature. That is wrong in both directions:
#
#   * headless=true, mobileAgents=false — a server nobody reaches from a phone.
#     The agents must still start at boot, or "unattended" means "attended, by
#     someone who walks over and logs in".
#   * headless=false, mobileAgents=true — today's Legion. A three-monitor
#     desktop that also answers a phone. Already worked; must keep working.
#
# ── Why pure ─────────────────────────────────────────────────────────────────
# This file imports nothing and takes no flake inputs, so the whole decision can
# be evaluated by `nix eval` over a matrix of (headless, mobile) with no flake,
# no nixpkgs instantiation and no store access — see
# nixos/tests/agent-operations/agent-lifetime.sh. Evaluating the real NixOS
# module for four combinations instead would cost minutes and would test the
# evaluator, not the rule.
let
  # ── the rule ───────────────────────────────────────────────────────────────
  # Does an agent unit have to survive having nobody logged in?
  bootLifetime = headless: mobileAgents:
    headless || mobileAgents;

  # WantedBy. default.target is the user manager's own target: with `linger` it
  # is reached at boot, without a session and without a display.
  wantedByTarget = headless: mobileAgents:
    if headless || mobileAgents
    then "default.target"
    else "graphical-session.target";

  wantedBy = headless: mobileAgents: [(wantedByTarget headless mobileAgents)];

  # After=. `graphical-session.target` is REMOVED rather than merely not
  # required: with lingering there may never be a graphical session, and a unit
  # ordered after a target that is never pulled in simply never starts.
  # Everything else (credential decryption) is kept in both cases.
  afterUnits = headless: mobileAgents:
    (
      if headless || mobileAgents
      then []
      else ["graphical-session.target"]
    )
    ++ [
      "sops-nix.service"
    ];

  # A unit that starts at boot has no WAYLAND_DISPLAY, no DBUS_SESSION_BUS_ADDRESS
  # and no session-provided display, because none of those exist until mango's
  # autostart runs dbus-update-activation-environment. Stated rather than hidden:
  # agents started before login cannot wl-copy or xdg-open, and that is inherent
  # to being reachable with nobody at the desk.
  needsGraphicalSession = headless: mobileAgents:
    !(headless || mobileAgents);

  # ── ownership conflict ─────────────────────────────────────────────────────
  #
  # A daemon started from a terminal (the `nohup herdr server` shape the herdr
  # unit header describes) is NOT owned by systemd. When the unit is WantedBy a
  # login target, the next login is exactly when the second copy appears. When
  # the unit starts at boot it usually wins the race instead — so the conflict
  # is a REPORT, never a kill: the running server holds live agent panes and
  # killing it to satisfy a unit file destroys work.
  #
  # Returns the conflicts worth reporting. Deliberately a list, not a boolean:
  # "started outside systemd" and "CLI newer than the server" are different
  # problems with different fixes and must not be collapsed into one flag.
  conflicts = {
    # Is the running server owned by the systemd unit, or by something else?
    daemonOwnership,
    # "compatible", "cli-newer", "cli-older", "protocol-mismatch", "unknown".
    compatibility,
    # Does the unit itself look healthy? "ok", "failed", "never-started".
    unitState,
  }:
    (
      if daemonOwnership == "systemd"
      then []
      else ["daemon-owned-by-${daemonOwnership}"]
    )
    ++ (
      if compatibility == "compatible"
      then []
      else ["client-server-${compatibility}"]
    )
    ++ (
      if unitState == "ok"
      then []
      else ["unit-${unitState}"]
    );
  # True only when nothing at all is wrong — the condition for the resume unit
  # to be allowed to touch anything. Written with its formals on one line:
  # a multi-line `{ … }:` directly after an attrset key is read as a longer
  # attrpath, not as a function pattern.
  ready = {
    daemonOwnership,
    compatibility,
    unitState,
  }:
    (conflicts {inherit daemonOwnership compatibility unitState;}) == [];
in {
  inherit
    bootLifetime
    wantedByTarget
    wantedBy
    afterUnits
    needsGraphicalSession
    conflicts
    ready
    ;
}
