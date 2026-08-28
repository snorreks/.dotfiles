# nixos/config/system/mouse.nix
#
# Logitech mouse (MX Master 3S) — declarative device settings.
#
# Why this exists instead of just running the Solaar tray:
# Solaar only pushes saved settings to the device while its daemon is running
# and happens to see the connect event. Launching it from mango's autostart made
# that a race — hence "sensitivity doesn't update unless I launch Solaar". Here
# the settings are applied with `solaar config` (pure CLI, no GUI, no daemon,
# no user session) from a unit driven by the events that actually matter:
# boot, receiver hotplug, and resume.
#
# The Solaar tray applet is now optional and purely a battery indicator; it
# lives in config/home/mouse.nix.
#
# Driven by `opts.mouse` (see nixos/options.nix).
{
  pkgs,
  lib,
  opts,
  ...
}: let
  cfg = opts.mouse;

  # `solaar config` succeeds at writing the setting but then dies during
  # teardown with a pygobject/python-3.14 incompatibility in solaar 1.1.19:
  #   Gio.Application.run -> TypeError: Unable to marshal str as an array
  # It exits 1 even on a fully successful write. So we ignore the exit code and
  # verify by reading the value back instead — that is the only trustworthy
  # signal here. Re-check when solaar is next bumped: if a plain
  # `solaar config <dev> dpi <n>` starts exiting 0, this wrapper can be
  # simplified to a straight sequence of calls.
  mouseApply = pkgs.writeShellApplication {
    name = "mouse-apply";
    runtimeInputs = [pkgs.solaar pkgs.coreutils pkgs.gnugrep];
    text = ''
      dev=${lib.escapeShellArg cfg.device}

      # On boot / hotplug the receiver may not have enumerated the device yet.
      for _ in $(seq 1 30); do
        if solaar show "$dev" >/dev/null 2>&1; then break; fi
        sleep 1
      done

      if ! solaar show "$dev" >/dev/null 2>&1; then
        echo "mouse-apply: '$dev' not present after 30s — nothing to do." >&2
        exit 0
      fi

      rc=0
      apply() {
        local key="$1" want="$2" got
        solaar config "$dev" "$key" "$want" >/dev/null 2>&1 || true
        # Read back: `solaar config <dev> <key>` ends with a "key = value" line.
        got="$(solaar config "$dev" "$key" 2>/dev/null \
                | grep -E "^$key = " | tail -n1 | cut -d= -f2- | tr -d ' ')"
        if [ "$got" = "$want" ]; then
          echo "mouse-apply: $key = $got"
        else
          echo "mouse-apply: FAILED to set $key (wanted '$want', device reports '$got')" >&2
          rc=1
        fi
      }

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList
        (k: v: "apply ${lib.escapeShellArg k} ${lib.escapeShellArg (toString v)}")
        cfg.settings)}

      exit "$rc"
    '';
  };
in
  lib.mkIf cfg.enable {
    # Also exposed as a command so the settings can be re-pushed by hand
    # (e.g. after power-cycling the mouse) without opening the Solaar window.
    environment.systemPackages = [mouseApply];

    systemd.services.mouse-apply = {
      description = "Apply Logitech mouse settings (${cfg.device})";
      # Runs as root: `solaar config` talks to /dev/hidraw* directly and needs
      # no graphical session, which is exactly why this is a system unit.
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe mouseApply;
      };
      wantedBy = ["multi-user.target"];
    };

    # Re-apply when the receiver appears, so replugging it (or booting with the
    # mouse off and switching it on later) doesn't leave stale settings.
    # NOTE: this does NOT cover power-cycling the mouse itself — with a Bolt
    # receiver that produces no hidraw event. Run `mouse-apply` for that case.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="046d", TAG+="systemd", ENV{SYSTEMD_WANTS}+="mouse-apply.service"
    '';

    # The user systemd manager has no suspend.target (checked on systemd 261),
    # so a user-level resume hook silently never fires. NixOS's resumeCommands
    # is the supported hook and runs in the system manager where it works.
    powerManagement.resumeCommands = "${lib.getExe mouseApply} || true";
  }
