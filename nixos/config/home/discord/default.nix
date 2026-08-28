{pkgs, ...}: {
  # Vesktop (Discord client with Vencord) — see ./vesktop.nix for the setup
  # 17.08.2026 buggy with opening link, also don't really see any rice or nice with vesktop
  # imports = [
  #   ./vesktop.nix
  # ];

  home.packages = [
    pkgs.discord
  ];
}
