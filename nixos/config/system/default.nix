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
      ./services.nix
      ./ssh.nix
      ./sound.nix
      ./user.nix
      ./gaming.nix
      ./hardware.nix
      ./docker.nix
      ./cache-cleanup.nix
    ]
    ++ lib.optionals opts.enablePersistence [./persistence.nix];
}
