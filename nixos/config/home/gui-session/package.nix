{
  writeShellApplication,
  systemd,
  jq,
  mango,
}:
writeShellApplication {
  name = "ns-gui";
  runtimeInputs = [systemd jq mango];
  text = builtins.readFile ./ns-gui.sh;
}
