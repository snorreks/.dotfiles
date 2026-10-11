# nixos/config/system/default.nix
# persistence.nix is imported only when opts.enablePersistence is true
# (see nixos/options.nix / hosts/<host>/options.nix).
{
  lib,
  opts,
  ...
}: {
  imports =
    [
      ./battery.nix
      ./boot.nix
      ./display-manager.nix
      ./environment.nix
      ./intel-nvidia.nix
      ./internationalization.nix
      ./kernel.nix
      ./networking.nix
      ./power-management.nix
      ./role.nix # reports the resolved server/travel policy (read-only options)
      ./security.nix
      ./mouse.nix
      ./server.nix
      # Transactional, reboot-free OS updates. Installed on every host (see the
      # module header for why); config/home/fish/default.nix decides which
      # commands route through it.
      ./maintenance.nix
      ./mobile-agents.nix # phone→herdr over Tailscale (gated on opts.mobileAgents.enable)
      # Agent operations (agent-operations PR): the reviewed state manifest, the
      # running-daemon GC roots, and the opt-in backup / health / resource
      # modules. Each declares its own `options.agentOps.*` and defaults to
      # disabled — enabling one is a decision, never a side effect of an import.
      ./agent-ops/state-manifest.nix
      ./agent-ops/credentials.nix
      ./agent-ops/daemon-roots.nix
      ./agent-ops/backup.nix
      ./agent-ops/health.nix
      ./agent-ops/resources.nix
      # Private media and isolated downloads (media-travel PR). Every service
      # inside is opt-in and defaults to disabled — see opts.media in
      # nixos/options.nix. This import changes nothing on a machine that has
      # not asked for it.
      ./media
      ./services.nix
      ./ssh.nix
      ./sound.nix
      ./user.nix
      ./hardware.nix
      ./docker.nix
      ./cache-cleanup.nix
    ]
    ++ lib.optionals opts.enablePersistence [./persistence.nix]
    # Gaming needs a desktop to play on, and this import is not free on a host
    # without one. Steam ran as a service on the parked Legion and opened
    # 27015/27036/27037/27040 in the firewall — Remote Play, the Source
    # dedicated server, and LAN transfers — on a machine with no screen and no
    # player. Gating the whole import closes those ports and drops Steam,
    # gamemode, gamescope, the extra fonts and the udev rules together, rather
    # than leaving a service enabled and then ignoring it.
    #
    # Set opts.desktop.enable = false to turn it off; set it back and gaming
    # returns with it, which is the only way a parked server would ever want it.
    ++ lib.optionals opts.desktop.enable [./gaming.nix];
}
