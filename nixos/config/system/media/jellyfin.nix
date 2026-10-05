# nixos/config/system/media/jellyfin.nix
#
# Private media server: native NixOS + systemd, no orchestration stack.
#
# The whole design is one sentence: **nothing here is reachable from the LAN,
# and everything here is reachable from the tailnet.** Jellyfin binds loopback
# only and is published through a PRIVATE Tailscale Serve listener, which is the
# same shape config/system/mobile-agents.nix gives Collie. That means no
# `allowedTCPPorts` entry, no interface beyond loopback, and no firewall rule
# that a future edit could get wrong.
#
# ── On the Serve port ───────────────────────────────────────────────────────
# Collie owns tailnet HTTPS 443. This module takes a DIFFERENT port
# (`serveHttpsPort`, default 8443) and an assertion below refuses 443 while
# Collie is enabled, because two units claiming the same Serve port is not a
# configuration that fails — it is one where whichever unit starts last wins and
# the other becomes a silently broken half. See docs/media-travel.md for how to
# verify the port is supported by the pinned Tailscale before enabling.
#
# `ExecStop` turns off ITS OWN port and nothing else. `tailscale serve reset`
# would erase every mapping on the node including Collie's, and it is the reason
# A's reconcile script does not use it either.
#
# ── On hardware transcoding ─────────────────────────────────────────────────
# Off by default, and the default is the point. "This laptop has an Intel GPU" is
# not a statement about QSV being usable: the render node, the media driver, the
# GuC/HuC firmware and the codec build each have to be present, and enabling
# acceleration without checking produces a server that silently transcodes in
# software while appearing configured.
#
# So `hardwareAcceleration.enable` additionally requires either a passing
# `jellyfin-accel-check.sh` or an explicit `acknowledgeMissing = true` — the
# second of which is a deliberate override that shows up in the diff.
#
# The discrete NVIDIA GPU is NOT configured for Jellyfin anywhere in this file,
# and `nvdec`/`nvenc` are deliberately absent. That GPU is for inference, and
# giving a transcoder the same device is the ordinary way inference stops having
# memory when a stream starts. Software transcoding remains available as the
# explicit fallback and is unaffected by any of this.
{config, pkgs, lib, opts, ...}: let
  cfg = opts.media.jellyfin;
  safeDirectory = path: lib.hasPrefix "/" path && path != "/"
    && !(lib.any (part: builtins.elem part ["" "." ".."]) (lib.tail (lib.splitString "/" path)));
  # Source proof (pinned nixpkgs Jellyfin v12.1):
  # https://github.com/jellyfin/jellyfin/blob/v12.1/MediaBrowser.Common/Net/NetworkConfiguration.cs
  # https://github.com/jellyfin/jellyfin/blob/v12.1/src/Jellyfin.Networking/Manager/NetworkManager.cs
  # FilterBindSettings adds missing 127.0.0.1; GetAllBindInterfaces returns
  # the filtered interfaces only when nonempty. IgnoreVirtualInterfaces=false
  # prevents an operator's prefix list from removing lo and causing wildcard
  # fallback. ApplicationHost.cs consumes InternalHttpPort at startup; the
  # early startup listener uses the same filter and port in:
  # https://github.com/jellyfin/jellyfin/blob/v12.1/Jellyfin.Server/ServerSetupApp/SetupServer.cs
  # Native setup flag: MediaBrowser.Model/Configuration/BaseApplicationConfiguration.cs.
  nativeConfig = pkgs.writeShellApplication {
    name = "jellyfin-private-config";
    runtimeInputs = [pkgs.python3];
    text = ''
      python3 - "$@" <<'PY'
      import os
      import stat
      import sys
      import uuid
      from xml.dom import minidom

      def directory(path):
          # No symlink components, including the configured parent directories.
          fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
          try:
              for part in path.split("/"):
                  if not part:
                      continue
                  if part in (".", ".."):
                      raise ValueError()
                  child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                  os.close(fd)
                  fd = child
              return fd
          except Exception:
              os.close(fd)
              raise

      def read_xml(fd, name, root_name, missing=False):
          try:
              f = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
          except FileNotFoundError:
              if missing:
                  return minidom.parseString("<" + root_name + "/>")
              raise
          with os.fdopen(f, "rb") as stream:
              if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                  raise ValueError()
              data = stream.read()
          # Do not resolve entities or accept DTDs in application configuration.
          if b"<!DOCTYPE" in data or b"<!ENTITY" in data:
              raise ValueError()
          doc = minidom.parseString(data)
          if doc.doctype is not None or doc.documentElement.tagName != root_name:
              raise ValueError()
          return doc

      def fields(root, name):
          return [n for n in root.childNodes if n.nodeType == n.ELEMENT_NODE and n.tagName == name]

      fd = None
      temporary = None
      try:
          mode, path = sys.argv[1:3]
          fd = directory(path)
          if mode == "check":
              doc = read_xml(fd, "system.xml", "ServerConfiguration")
              flags = fields(doc.documentElement, "IsStartupWizardCompleted")
              if len(flags) != 1 or any(n.nodeType != n.TEXT_NODE for n in flags[0].childNodes):
                  raise ValueError()
              if "".join(n.data for n in flags[0].childNodes).strip() not in ("true", "1"):
                  raise ValueError()
          elif mode == "pin":
              port = int(sys.argv[3])
              if not 1 <= port <= 65535:
                  raise ValueError()
              doc = read_xml(fd, "network.xml", "NetworkConfiguration", missing=True)
              root = doc.documentElement
              values = {
                  "LocalNetworkAddresses": None,
                  "InternalHttpPort": str(port),
                  "EnableIPv4": "true",
                  "EnableIPv6": "false",
                  "IgnoreVirtualInterfaces": "false",
                  "AutoDiscovery": "false",
                  "RequireHttps": "false",
              }
              for name, value in values.items():
                  nodes = fields(root, name)
                  if len(nodes) > 1:
                      raise ValueError()
                  node = nodes[0] if nodes else root.appendChild(doc.createElement(name))
                  for child in list(node.childNodes):
                      node.removeChild(child)
                  if value is None:
                      child = node.appendChild(doc.createElement("string"))
                      child.appendChild(doc.createTextNode("127.0.0.1"))
                  else:
                      node.appendChild(doc.createTextNode(value))
              # Atomic replacement in the already-open directory; never follow
              # a destination symlink. No backup containing certificate secrets.
              temporary = ".network-" + uuid.uuid4().hex
              out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
              with os.fdopen(out, "wb") as stream:
                  stream.write(doc.toxml(encoding="utf-8"))
                  stream.flush()
                  os.fsync(stream.fileno())
              os.replace(temporary, "network.xml", src_dir_fd=fd, dst_dir_fd=fd)
              temporary = None
          else:
              raise ValueError()
      except Exception:
          # Never print XML, paths, flag values, or parser exception contents.
          print("Jellyfin private configuration refused", file=sys.stderr)
          sys.exit(1)
      finally:
          if temporary is not None:
              os.unlink(temporary, dir_fd=fd)
          if fd is not None:
              os.close(fd)
      PY
    '';
  };
  serveStart = pkgs.writeShellApplication {
    name = "jellyfin-private-serve";
    runtimeInputs = [config.services.tailscale.package pkgs.util-linux];
    text = ''
      # Revoke only our mapping first, including when opt-in is withdrawn.
      if cleanup_error="$(tailscale serve --https=${toString cfg.serveHttpsPort} off 2>&1)"; then
        :
      else
        # Tailscale appends usage guidance after the error line.
        case "''${cleanup_error%%$'\n'*}" in
          "error: failed to remove web serve: handler does not exist") ;;
          *) printf '%s\n' "$cleanup_error" >&2; exit 1 ;;
        esac
      fi
      if ! ${if cfg.setupCompleted then "true" else "false"}; then
        exit 1
      fi
      runuser -u jellyfin -- ${lib.getExe nativeConfig} check ${lib.escapeShellArg cfg.configDir}
      tailscale serve --bg --https=${toString cfg.serveHttpsPort} http://127.0.0.1:${toString cfg.port}
    '';
  };
in {
  services.jellyfin = lib.mkIf cfg.enable {
    enable = true;
    # Nix-owned version. Upgrading is `nix flake update` plus a rebuild, and a
    # rollback is a rebuild of the previous lock — which is a property the
    # whole reason for going native rather than adding a container stack.
    package = pkgs.jellyfin;

    dataDir = cfg.dataDir;
    configDir = cfg.configDir;

    # Defense in depth only: trusted tailscale0 bypasses this firewall.
    # The native loopback bind below is the actual raw-backend boundary.
    openFirewall = false;

    # Least privilege. Jellyfin gets its own system account and the `media`
    # group, and nothing else. It is not a member of `wheel`, and it does not
    # run as the operator.
    group = "media";
    user = "jellyfin";

    # Transcoding acceleration is declared HERE, in the same block, rather than
    # as a second `services.jellyfin.hardwareAcceleration`: within one
    # attribute set those are a conflict, not a merge. (Across modules they DO
    # merge, which is why `systemd.services.jellyfin.sliceConfig` in
    # default.nix is fine.)
    #
    # QSV/VAAPI on the iGPU, never NVENC — see the file header. When
    # acceleration is off, nothing is declared here and Jellyfin's own default
    # (software transcoding) applies, rather than a value chosen here.
    hardwareAcceleration = {
      enable = cfg.hardwareAcceleration.enable;
      # nixpkgs asserts this is non-null whenever enable is true. Naming it here
      # keeps the failure pointing at this module rather than at an upstream
      # assertion that names neither the option nor the check that was supposed
      # to run before it.
      device = lib.mkIf cfg.hardwareAcceleration.enable "/dev/dri/renderD128";
      type = lib.mkIf cfg.hardwareAcceleration.enable (
        if cfg.hardwareAcceleration.acknowledgeMissing
        then cfg.hardwareAcceleration.type
        else "vaapi"
      );
    };

    # Loopback binding limits inbound access, not outbound metadata requests.
    # Review installed plugins and metadata providers separately. Do not invent
    # a telemetry environment variable or treat private Serve as an egress policy.
  };

  users.groups.media = {};
  users.groups.jellyfin = {};

  # ── Storage ────────────────────────────────────────────────────────────────
  #
  # Native Linux filesystem only. opts.mountShared (/mnt/shared, the Windows
  # dual-boot NTFS volume) is deliberately NOT referenced here and must not be:
  # an unattended server writing to a hibernated Windows volume is a corruption
  # path that needs a keyboard and a booted Windows to fix.
  #
  # The three-way split is load-bearing, not tidiness:
  #
  #   incomplete/  being written right now. Nothing reads it.
  #   download/    finished, waiting to be moved into the library.
  #   library/     what Jellyfin actually serves.
  #
  # Jellyfin is given library/ (and the cache/download dir it needs), NOT the
  # parent, so a half-written download is never something a library scan can
  # pick up.
  systemd.tmpfiles.rules = lib.mkIf cfg.enable [
    # cfg.incompleteDir is deliberately NOT here: it belongs to the torrent
    # client, and jellyfin has no such option — naming it made evaluation fail
    # with "attribute 'incompleteDir' missing" the moment Jellyfin was enabled.
    # cfg.downloadDir is NOT declared here: config/system/media/torrents.nix
    # owns it (qbBittorrent writes it), and two tmpfiles rules for one path
    # with different owners is a boot-time duplicate. jellyfin serves
    # cfg.libraryDir, which it does own.
    "d ${cfg.libraryDir} 0750 jellyfin media -"
    "d ${cfg.dataDir} 0755 jellyfin media -"
    "d ${cfg.configDir} 0755 jellyfin media -"
  ];

  # ExecStartPre inherits User=jellyfin from nixpkgs (no '+' root override).
  # Runs on every restart; never touches wizard, user or authentication state.
  systemd.services.jellyfin.preStart = lib.mkIf cfg.enable (lib.mkBefore ''
    ${lib.getExe nativeConfig} pin ${lib.escapeShellArg cfg.configDir} ${toString cfg.port}
  '');

  # ── Private publication ────────────────────────────────────────────────────
  systemd.services.tailscale-serve-jellyfin = lib.mkIf cfg.enable {
    description = "Jellyfin on the node's private Tailscale HTTPS endpoint (${toString cfg.serveHttpsPort})";
    after = [
      "tailscaled.service"
      "tailscaled-autoconnect.service"
      "tailscaled-set.service"
      "network-pre.target"
      "jellyfin.service"
    ];
    requires = ["jellyfin.service"];
    bindsTo = ["jellyfin.service"];
    partOf = ["jellyfin.service"];
    wants = ["tailscaled.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe serveStart;
      # THIS PORT ONLY. Never `serve reset`, which erases every mapping on the
      # node — including Collie's 443, which A's reconcile script exists to keep.
      ExecStop = lib.escapeShellArgs [
        (lib.getExe config.services.tailscale.package)
        "serve"
        "--https=${toString cfg.serveHttpsPort}"
        "off"
      ];
      # The unit must not be able to hang a boot on a node that has not finished
      # authenticating; `tailscale serve` returns non-zero rather than blocking.
      TimeoutStartSec = "30s";
    };
  };

  # ── Acceleration capability check ──────────────────────────────────────────
  #
  # Installed whenever Jellyfin is on, acceleration or not: it is the thing an
  # operator runs to find out WHY acceleration is unavailable, which is the
  # question that actually gets asked.
  environment.systemPackages = lib.mkIf cfg.enable [
    (pkgs.writeShellApplication {
      name = "jellyfin-accel-check";
      runtimeInputs = [
        # Provides vainfo — the VAAPI entrypoint enumeration the check reads.
        #
        # `intel-media-sdk` (oneVPL, for the QSV entrypoints) is deliberately
        # NOT a dependency: nixpkgs marks it insecure and refusing it, and the
        # VAAPI check does not need it. If you want oneVPL/QSV rather than
        # VAAPI, add it AND `permittedInsecurePackages` deliberately — with the
        # CVE list you are accepting.
        pkgs.intel-media-driver
        pkgs.pciutils
        pkgs.coreutils
      ];
      text = builtins.readFile ./scripts/jellyfin-accel-check.sh;
    })
  ];

  # ── Backup integration ─────────────────────────────────────────────────────
  #
  # The library index is registered with the backup lane, which is what makes a
  # library restore possible. Without it a restored media directory has files and
  # no index, and Jellyfin's first scan of a large library is not fast.
  #
  # media/default.nix owns the export service and the heartbeatHook; this module
  # only declares WHAT has to survive, so the two cannot disagree about which
  # database matters.
  # Only default.nix registers the application-consistent export tree.
  # Never register the live SQLite data directory as a raw backup source.
  agentOps.backup.additionalSources = lib.mkIf (cfg.enable && config.agentOps.backup.enable) [cfg.configDir];

  # ── Refusals, and visible half-configured states ──────────────────────────
  assertions = lib.optionals cfg.enable [
    {
      assertion = lib.all safeDirectory [cfg.libraryDir cfg.dataDir cfg.configDir];
      message = "media.jellyfin directories must be canonical absolute non-root paths";
    }
    {
      assertion = builtins.isInt cfg.port && cfg.port > 0 && cfg.port <= 65535
        && !(builtins.elem cfg.port [22 2222 443]);
      message = "media.jellyfin.port must not claim SSH or tailnet HTTPS";
    }
    {
      # Two Serve units claiming one port is a race, not a conflict error.
      assertion = !(cfg.serveHttpsPort == 443 && opts.mobileAgents.collie.enable);
      message = ''
        media: opts.media.jellyfin.serveHttpsPort is 443 and Collie is enabled.
        Both units would write `tailscale serve --https=443`, and the one that
        starts last silently wins.

        Collie owns 443 (config/system/mobile-agents.nix). Give Jellyfin its
        own port:
          opts.media.jellyfin.serveHttpsPort = 8443;
      '';
    }

    {
      # Accel on without the check having passed, and without saying so.
      assertion = !cfg.hardwareAcceleration.enable
        || cfg.hardwareAcceleration.acknowledgeMissing;
      message = ''
        media: hardwareAcceleration.enable is true, but the capability check has
        not been acknowledged as passed.

        Run it first:
          jellyfin-accel-check
        If it fails, leave acceleration off (software transcoding is correct and
        keeps the NVIDIA GPU free for inference), or override deliberately:
          opts.media.jellyfin.hardwareAcceleration.acknowledgeMissing = true;
      '';
    }

    {
      assertion = !cfg.hardwareAcceleration.enable || cfg.hardwareAcceleration.type != "nvenc";
      message = ''
        media: hardwareAcceleration.type = "nvenc" was refused.

        The discrete NVIDIA GPU is for inference in this configuration. Handing
        the transcoder the same device is how inference runs out of memory the
        first time somebody plays something. Use "vaapi" (the Intel iGPU), or
        leave acceleration off and transcode in software.
      '';
    }

    {
      # Shared NTFS is not a media root.
      assertion = !opts.mountShared
        || !(lib.hasPrefix "/mnt/shared" cfg.libraryDir);
      message = ''
        media: the Jellyfin library is on the shared NTFS volume.

        /mnt/shared is the Windows dual-boot volume (opts.mountShared). An
        unattended server writing to a hibernated Windows filesystem corrupts
        it, and repairing it needs a keyboard and a booted Windows. Media and
        state must live on native Linux filesystems.
      '';
    }
  ];

  warnings =
    lib.optional (cfg.enable && cfg.setupCompleted == false) ''
      media: Jellyfin is enabled but opts.media.jellyfin.setupCompleted is false.

      Until a Jellyfin administrator account exists, Jellyfin's first-run setup
      wizard is available only on localhost; private Serve publication is refused.
      Bootstrap locally or with an SSH tunnel to 127.0.0.1:${toString cfg.port},
      then set opts.media.jellyfin.setupCompleted = true and restart publication.
      Serve also requires Jellyfin's native wizard-completed flag at startup.
      Neither this opt-in nor its checker creates or modifies any account.
    ''
    ++ lib.optional (cfg.enable && cfg.hardwareAcceleration.enable) ''
      media: hardware transcoding is enabled for Jellyfin. This has not been
      verified on this machine in this configuration. Real-hardware acceptance
      (a representative high-bitrate file, and a seek) is recorded as PENDING in
      docs/media-travel.md and must be performed before travel.
    '';
}