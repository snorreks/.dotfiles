# nixos/config/home/scripts/scripts.nix
{
  pkgs,
  lib,
  ...
}: let
  scriptsDir = ./scripts;
  entries = builtins.readDir scriptsDir;

  # Filter to parse regular .sh, .py, and .ts files
  validFiles =
    lib.filterAttrs (
      filename: type:
        type
        == "regular"
        && (
          lib.hasSuffix ".sh" filename
          || lib.hasSuffix ".py" filename
          || lib.hasSuffix ".ts" filename
        )
    )
    entries;

  generatedScripts =
    lib.mapAttrsToList (
      filename: _: let
        # Extract filename without extension (e.g., "get_zen_info.ts" -> "get_zen_info")
        name = builtins.head (builtins.match "(.*)\\.[^.]+" filename);
        filePath = scriptsDir + "/${filename}";
        content = builtins.readFile filePath;
      in
        if lib.hasSuffix ".sh" filename
        then
          # Simple shell script wrapper
          pkgs.writeShellScriptBin name content
        else
          # Python (.py) and TypeScript (.ts) scripts preserving shebangs
          pkgs.writeTextFile {
            inherit name;
            executable = true;
            destination = "/bin/${name}";
            text = content;
          }
    )
    validFiles;
in {
  home.packages = generatedScripts;
}
