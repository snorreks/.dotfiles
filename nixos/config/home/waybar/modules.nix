# nixos/config/home/waybar/modules.nix
#
# The two "middle of the bar" data sources, packaged as standalone binaries so
# they can also be run by hand (`waybar-agenda --once`, `waybar-weather --once`).
#
#   waybar-agenda   Google Calendar (secret iCal URL) → next event + tooltip
#   waybar-weather  OpenWeatherMap                    → conditions + forecast
#
# Both follow the same contract as the sys-daemon streams: a long-lived process
# that prints one JSON line whenever the rendered state changes, so waybar gets
# push updates instead of an interval poll. Both read their credential from the
# sops `secrets-env` file (see sops.nix) — nothing secret enters the nix store,
# and they degrade to a "setup" pill instead of failing when it is missing.
{
  pkgs,
  opts,
  ...
}: let
  # icalendar + recurring_ical_events do the RRULE/EXDATE/override expansion —
  # hand-rolling recurrence handling is where every homegrown agenda widget
  # eventually goes wrong.
  agendaPython = pkgs.python3.withPackages (ps: [
    ps.icalendar
    ps.recurring-ical-events
  ]);

  mkPythonScript = {
    name,
    python,
    source,
  }:
    pkgs.writeTextFile {
      inherit name;
      text = "#!${python}/bin/python3\n" + builtins.readFile source;
      executable = true;
      checkPhase = ''
        PYTHONPYCACHEPREFIX="$TMPDIR" ${python}/bin/python3 -m py_compile "$out"
      '';
    };

  agendaScript = mkPythonScript {
    name = "waybar-agenda.py";
    python = agendaPython;
    source = ./agenda.py;
  };

  weatherScript = mkPythonScript {
    name = "waybar-weather.py";
    python = pkgs.python3;
    source = ./weather.py;
  };

  waybar-agenda = pkgs.writeShellScriptBin "waybar-agenda" ''
    exec ${agendaScript} "$@"
  '';

  # Coordinates come from nixos/options.nix (same source as wlsunset), and
  # xdg-open is pinned so `--open` works regardless of waybar's PATH.
  waybar-weather = pkgs.writeShellScriptBin "waybar-weather" ''
    export PATH="${pkgs.xdg-utils}/bin:$PATH"
    export WAYBAR_WEATHER_LAT="''${WAYBAR_WEATHER_LAT:-${opts.latitude}}"
    export WAYBAR_WEATHER_LON="''${WAYBAR_WEATHER_LON:-${opts.longitude}}"
    exec ${weatherScript} "$@"
  '';
in {
  home.packages = [waybar-agenda waybar-weather];
}
