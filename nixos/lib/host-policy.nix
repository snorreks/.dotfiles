# nixos/lib/host-policy.nix
#
# The pure half of the server/travel policy: which ROLE a host is in, whether
# that contradicts anything else it declared, how a private, gitignored
# override file is scoped to one host, and what the DNS owner/rescue list is
# allowed to be.
#
# ── Why this file is pure, and why it lives outside `nixos/` ────────────────
# Every function here is a plain function over plain attrsets, using nothing
# but `builtins`. That is a deliberate constraint with two payoffs:
#
#   * It can be evaluated with `nix eval --file` — no nixpkgs, no flake, no
#     network, no store access — which is what lets the regression tests in
#     `nixos/tests/server-foundation/role-policy.sh` assert the actual policy
#     in seconds, in the fast lane, without building or evaluating a host.
#   * The ROLE decision cannot then acquire an accidental dependency on a
#     module, an option or an input. It is decided in exactly one place and
#     every consumer — every module, every test — reads the same answer.
#
# flake.nix is the only caller. It resolves the role, folds the result back
# into `opts` so that `opts.headless` stays the effective boolean every other
# module (and the parallel agent-operations work) reads, and refuses a
# contradictory configuration at EVAL time, where the message can name every
# problem at once rather than one per `nixos-rebuild`.
#
# Deliberately NOT a NixOS module: `assertions` fire at build time, and a
# contradictory role is a mistake in the inputs, not a build failure. Refusing
# it during evaluation is the stronger and simpler guarantee.
rec {
  # The roles that exist. There are two, and the second is the whole point:
  #
  #   desktop  a machine somebody sits at. Suspends when closed, lid closes
  #            the lid, autologin desktop, LAN service ports open, no exit
  #            node. This is the travel laptop (gs65) and it is the DEFAULT.
  #
  #   server   a machine that stays behind and is only ever reached remotely.
  #            Suspend removed as a possibility, lid and power keys ignored,
  #            user lingering on (so the user manager, and with it herdr and
  #            Collie, exist with nobody logged in), LAN service ports closed
  #            in favour of the tailnet, exit node advertised, Proton VPN
  #            kill-switch structurally excluded. The desktop is still
  #            installed — walk up and log in at tuigreet and you get it — so
  #            "server" never means "unusable by hand".
  #
  # `travel` is deliberately NOT a third value. The GS65 travels and suspends;
  # that is exactly `desktop`, and inventing an enum member with no behaviour
  # of its own is how a policy stops being readable. What actually makes a
  # host a travel host is the role being `desktop` plus the per-host hardware
  # policy in hosts/gs65 (charge limit, sleep on lid), all of which is
  # already host-scoped.
  validRoles = ["desktop" "server"];

  # Host keys that a private override file may name. Kept explicit rather than
  # derived from the directory listing so that a typo is a visible mismatch
  # instead of a silently ignored key, and so that `builtins.attrNames hosts`
  # staying empty-by-accident cannot quietly drop every override.
  knownHostKeys = ["legion" "gs65"];

  # The resolved role for a host.
  #
  # Precedence, in one place, because two answers are the bug:
  #
  #   1. `role` when set — the modern switch, what hosts/*/options.nix uses.
  #   2. `headless` when set — the compatibility path. A host that predates
  #      roles keeps working by flipping the boolean it already had, and still
  #      gets the whole server behaviour rather than half of it.
  #   3. `desktop`.
  #
  # Note what is NOT an error: `role = "server"` with `headless = false`
  # (the untouched base default) is the normal shape of a host that has been
  # promoted to a server by editing one line. It resolves to `server` and the
  # resolved boolean is written back, so every module sees `headless = true`.
  resolveRole =
    {
      role,
      headless
    }:
    if role == null then
      (if headless then "server" else "desktop")
    else role;

  # The EFFECTIVE `opts.headless`, which is the compatibility contract other
  # groups (and any existing host override) read. Always a boolean.
  resolveHeadless =
    {
      role,
      headless
    }:
    (resolveRole {inherit role headless;}) == "server" || headless;

  # Everything that has to be checked about a host's declared policy, in one
  # call, because a host that is wrong in two ways should be told so in one
  # build rather than one build per mistake.
  #
  # Returns { role, headless, problems, warnings }:
  #   problems  — contradictions. flake.nix refuses to evaluate the host.
  #   warnings  — survivable but almost certainly not what was meant. They are
  #               printed once, at evaluation, and the host still builds.
  #
  # The distinction is not cosmetic. A server role with no charge limit is a
  # choice somebody can still make (a desktop-provisioned server box that has
  # no battery at all), while `role = "desktop"` next to `headless = true` is
  # a statement that cannot be true.
  policyDiagnostics =
    {
      role,
      headless,
      batteryChargeLimit,
      mobileAgents
    }:
    let
      resolvedRole = resolveRole {inherit role headless;};
      effectiveHeadless = resolvedRole == "server" || headless;

      # `role` may be any value at all — options.nix is an untyped attrset and
      # a host is free to misspell it. Comparing against the valid list is the
      # check; `resolvedRole == "server"` above is already false for a typo,
      # which is the safe direction: a misspelt role must never quietly grant
      # or quietly deny server behaviour.
      badRole =
        role != null && !(builtins.elem role validRoles);

      problems =
        (if badRole then [
          ''
            role: '${builtins.toString role}' is not one of ${builtins.concatStringsSep ", " validRoles}.
                    role is per host (hosts/<host>/options.nix) and is the
                    server/travel switch; leave it null to inherit `headless`.
          ''
        ] else [])
        ++ (
          if !badRole && resolvedRole == "desktop" && headless then
            [
              ''
                role/headless: this host resolves to role = "desktop" while
                opts.headless = true. Those are different questions — role says
                what KIND of machine this is, headless says it is reached only
                remotely — and with both set the modules that read `headless`
                (suspend removal, lingering, LAN ports, exit node) would behave
                as a server while the role says laptop.

                Pick one:
                  * keep headless = true   -> set role = "server" (or null)
                  * keep role = "desktop"  -> set headless = false
              ''
            ]
          else []
        )
        ++ (
          if mobileAgents.enable && mobileAgents.sshPort == 22 then
            [
              ''
                mobileAgents: sshPort = 22 is refused. Tailscale SSH answers on
                tailnet port 22 before the OS sshd does, so a key-authenticated
                client (Moshi, Termux) stalls against it and then fails with an
                auth error that says nothing about the key actually being wrong.
                Pick any port other than 22; 2222 is the value every host in
                this repository uses.
              ''
            ]
          else []
        )
        ++ (
          if mobileAgents.collie.enable && !mobileAgents.enable then
            [
              ''
                mobileAgents: collie.enable is true while mobileAgents.enable
                is false. Collie is a client BEHIND the shared infrastructure
                (the second sshd listener, linger, the Serve mapping) — it has
                no meaning without it, and this combination builds a bridge
                with no way in and no warning.

                Set mobileAgents.enable = true, or collie.enable = false.
              ''
            ]
          else []
        );

      warnings =
        (if resolvedRole == "server" && batteryChargeLimit == null then
          [
            ''
              role = "server" with batteryChargeLimit = null. An unattended
              laptop that is left on AC for months will hold its pack at 100%,
              which is what actually ages it. Consider 60 (the documented
              server value) or, if the hardware has no writable threshold at
              all, ignore this — config/system/battery.nix reports which rung
              it landed on and the limit actually achieved.
            ''
          ]
          else [])
        ++ (
          if resolvedRole == "server" && !mobileAgents.enable && !mobileAgents.collie.enable then
            [
              ''
                role = "server" with the phone clients off. That is a valid
                combination — system lingering is what keeps the user manager
                alive on a server, and it is independent of the phone — but it
                means nothing starts herdr or Collie at boot yet. The
                agent-operations group owns that WantedBy work.
              ''
            ]
          else []);
    in
    {
      role = resolvedRole;
      inherit effectiveHeadless headless;
      problems = map (s: ''
        ${s}
      '') problems;
      warnings = map (s: ''
        ${s}
      '') warnings;
    };

  # Which slice of a private override file applies to one host.
  #
  # `local.nix` is gitignored, machine-local and therefore invisible to the
  # build-source contract in a way that is easy to get wrong — see
  # docs/headless-server.md § "Private overrides and the build source". The
  # SHAPE here is what makes that safe: overrides are scoped to a named host
  # instead of being merged into every host in the flake.
  #
  # Accepted shapes, in this order:
  #
  #   { legion = { … }; gs65 = { … }; }   host-scoped — RECOMMENDED, explicit
  #   { _default = { … }; legion = { … }; }
  #                                        _default plus per-host overrides;
  #                                        the per-host key wins
  #   { hostname = "legion"; … }          the legacy flat shape, still accepted
  #                                        so an existing local.nix keeps
  #                                        working — and reported, because it
  #                                        silently applied to BOTH machines
  #
  # Returns { overrides, shape, warning }.
  selectHostOverrides =
    {
      local,
      hostKey
    }:
    let
      keys = if local == null then [] else builtins.attrNames local;
      hostKeyed = builtins.elem true (map (k: builtins.elem k knownHostKeys || k == "_default") keys);
    in
    if local == null || keys == [] then
      {
        overrides = {};
        shape = "empty";
        warning = null;
      }
    else if hostKeyed then
      {
        # The per-host key wins over _default, and there is no merge between
        # the two: _default is a default, not a base to extend.
        overrides =
          if builtins.hasAttr hostKey local then
            local.${hostKey}
          else if builtins.hasAttr "_default" local then
            local."_default"
          else
            {};
        shape = "host-scoped";
        warning =
          if !(builtins.hasAttr hostKey local || builtins.hasAttr "_default" local) then
            ''
              local.nix is host-scoped and defines ${builtins.concatStringsSep ", " keys},
              but this host is '${hostKey}' and matches none of them, so NO
              private override applies to it. Add

                  ${hostKey} = { … };

              or a `_default` entry, if the override was meant for every host.
            ''
          else null;
      }
    else
      {
        overrides = local;
        shape = "flat-legacy";
        warning = ''
          local.nix uses the legacy FLAT shape, so these overrides apply to
          EVERY host in the flake, not just one. That is rarely intended: it
          made `hostName`, a battery limit or a monitor rule on the Legion also
          apply to the travel laptop. Scope it by host:

            {
              ${hostKey} = {
                # …overrides for this host only…
              };
            }

          Until it is scoped, treat every host in this configuration as
          carrying these values.
        '';
      };

  # The DNS owner and its rescue targets, as one value.
  #
  # ── The bug this exists to prevent ─────────────────────────────────────────
  # There used to be five nameservers here (two loopback, three public) and
  # no `maxnames`. resolv.conf(5) caps how many a resolver will actually
  # consult — glibc's MAXNS, and openresolv, which is what NixOS installs
  # here, applies its own default — and everything past the cap is silently
  # DISCARDED. The headless rescue list was therefore doing nothing: on the
  # host where dnscrypt-proxy failing to start leaves the machine with no name
  # resolution at all, the fallback that was supposed to save it had been
  # truncated away by the very mechanism meant to apply it.
  #
  # glibc's MAXNS is compiled as THREE. An `options maxnames 4` line
  # cannot increase it. Servers therefore use one loopback and two numeric
  # rescue resolvers; desktops keep the two local listeners.
  #
  #   owner     exactly one component listening on :53. dnscrypt-proxy is it.
  #             NetworkManager must keep `dns = "none"` or it races the owner
  #             for /etc/resolv.conf on every link event.
  #   nameservers  ordered list: the owner first, numeric rescues after it.
  #             Numeric on purpose — a resolver address cannot itself depend on
  #             DNS working, which is the entire point of the rescue.
  #   maxnames  length of the list. Never less: see above.
  #
  # Desktop keeps just the two loopback addresses: there is no unattended boot
  # to survive, and a laptop on hotel wifi is better off not silently sending
  # every lookup to a public resolver the moment its local cache misses.
  dnsPolicy =
    {
      headless
    }:
    let
      loopback = ["127.0.0.1" "::1"];
      # Quad9 first, then Cloudflare. Both are numeric, both answer on 53
      # without any name of their own, and neither is a resolver we run.
      rescue = ["9.9.9.9" "1.1.1.1"];
      nameservers = if headless then ["127.0.0.1"] ++ rescue else loopback;
    in
    {
      owner = "dnscrypt-proxy";
      nameservers = nameservers;
      maxnames = builtins.length nameservers;
    };

  # Accept raw base64 or an OpenSSH public-key line, not a known_hosts record.
  travelHostKey = { key, type ? "ssh-ed25519" }:
    let
      words = builtins.filter (v: builtins.isString v && v != "") (builtins.split "[[:space:]]+" key);
      hasType = words != [] && builtins.match "(ssh-.*|ecdsa-.*)" (builtins.head words) != null;
      value = if hasType then builtins.elemAt words 1 else builtins.head words;
    in
      if key == "" then ""
      else if builtins.match ".*[\n\r].*" key != null
        || (hasType && (builtins.length words < 2 || builtins.head words != type))
        || (!hasType && builtins.length words != 1)
        || builtins.match "[A-Za-z0-9+/]+={0,2}" value == null
      then throw "travel.serverHostKey must be a single public key matching serverHostKeyType"
      else "${type} ${value}";
}
