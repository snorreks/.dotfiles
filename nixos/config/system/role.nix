# nixos/config/system/role.nix
#
# The resolved server/travel policy, readable from the built configuration.
#
# ── Why this module exists ───────────────────────────────────────────────────
# The role is decided in ONE place — nixos/flake.nix, from the pure
# nixos/lib/host-policy.nix — and then folded back into `opts.headless`, so
# every other module reads a single boolean and none of them has to know which
# switch produced it. That is the right design and it has one cost: the
# DECISION is invisible from the outside. `nixos-rebuild` shows you what it
# changed, not what it decided this machine is.
#
# These options report the answers. Nothing here sets any behaviour; it exists so
# that a question like "is this host actually configured as a server, with
# lingering, and with a DNS rescue list that fits inside MAXNS?" can be answered
# from an evaluated configuration — in a test, in a script, or with one `nix
# eval` while you are trying to work something out.
#
# The alternative — reconstructing all of that in a test by re-merging the same
# inputs by hand — is how a test ends up asserting on its own idea of the policy
# instead of on the policy.
{
  config,
  lib,
  opts,
  ...
}: let
  dnsPolicy = (import ../../lib/host-policy.nix).dnsPolicy;
in {
  options.hostPolicy = {
    role = lib.mkOption {
      type = lib.types.enum ["desktop" "server"];
      description = ''
        The resolved role for this host: `server` for a machine that stays behind
        and is only reached remotely, `desktop` for one that is carried around
        and suspends. Read-only — set `opts.role` in hosts/<host>/options.nix.
      '';
    };

    headless = lib.mkOption {
      type = lib.types.bool;
      description = ''
        The effective `opts.headless`: true whenever the role is `server`, and
        otherwise whatever the compatibility boolean says. Read-only.

        This is the boolean every other module gates on, and it is what the
        parallel agent-operations work consumes, so it is deliberately the same
        value rather than a second answer.
      '';
    };

    lingering = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Whether the user manager is kept alive with nobody logged in —
        `headless OR mobileAgents.enable`. Read-only.

        Deliberately only the CONDITION. That the user manager exists is what
        this says. Which units it starts at boot, and whether their credentials
        are ready, belongs to the agent-operations layer; do not read this as a
        claim that agent continuity is complete.
      '';
    };

    dns = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [lib.types.str (lib.types.listOf lib.types.str) lib.types.int]);
      description = ''
        The DNS owner, the nameserver list, and the MAXNS cap that goes with it —
        all three from one function, because they have to agree: resolv.conf(5)
        caps how many nameservers are consulted and silently discards the rest.
        Read-only.
      '';
    };
  };

  config = {
    hostPolicy = {
      role = opts.role;
      headless = opts.headless;
      # The same union server.nix acts on, computed rather than imported, so this
      # reports the CONDITION and not a second opinion about it.
      lingering = opts.headless || opts.mobileAgents.enable;
      dns =
        let
          d = dnsPolicy {headless = opts.headless;};
        in
        {
          inherit (d) owner;
          inherit (d) nameservers;
          maxnames = d.maxnames;
        };
    };

    # The invariant that made this a bug once, stated where it can be checked.
    # `nameservers` and `maxnames` come from the same function, so this cannot be
    # violated by editing one of them; the assertion is here so that a future
    # change that computes them separately fails the build instead of silently
    # reintroducing a rescue list that is never consulted.
    assertions = [
      {
        assertion = builtins.length config.hostPolicy.dns.nameservers <= config.hostPolicy.dns.maxnames;
        message = ''
          hostPolicy.dns: ${toString (builtins.length config.hostPolicy.dns.nameservers)}
          nameservers but maxnames is ${toString config.hostPolicy.dns.maxnames}. Everything
          past the cap is discarded by the resolver, so the list would be
          decoration. Derive both from nixos/lib/host-policy.nix (dnsPolicy).
        '';
      }
    ];
  };
}
