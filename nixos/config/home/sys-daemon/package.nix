{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "sys-daemon";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./ports.json
      ./src
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;
  doCheck = false;
  meta = {
    description = "Event-driven system status daemon (waybar streaming + dev-ports dashboard + idle-guard)";
    mainProgram = "sys-daemon";
  };
}
