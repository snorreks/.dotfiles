# nixos/pkgs/moshi-hook.nix
#
# Moshi's host daemon — the thing that makes the agents in herdr visible to the
# Android app (inbox events, approvals, Chat View, diff/browser preview over the
# local gateway). Upstream: https://getmoshi.app/docs/install-moshi-hook
#
# NOT IN NIXPKGS. There is a `moshi` attribute in nixpkgs, but it is Eclipse
# Moshi 0.2.12, the Java JSON library — a name collision, nothing to do with the
# terminal app. Hence this derivation.
#
# ── Why a pinned fetchurl and not the install script ───────────────────────
# The documented one-liner is `curl -fsSL https://getmoshi.app/install.sh | sh`,
# which is three separate problems for a declarative host:
#
#   1. It is not reproducible. With no MOSHI_HOOK_VERSION it resolves "latest"
#      from the CDN at activation time, so two hosts built a week apart get
#      different daemons and a rebuild is never a no-op.
#   2. It writes the binary somewhere outside the store and adds `update`
#      behaviour, which fights Nix's own idea of what is installed.
#   3. It runs an interactive first-run prompt during activation.
#
# So: pinned version, verified hash, and `set auto-update off` applied from Nix
# in config/home/moshi-hook.nix. Upgrading becomes an ordinary flake update.
#
# ── Hash provenance ─────────────────────────────────────────────────────────
# `version` is what upstream's own CDN reports as current at
# cdn.getmoshi.app/hook/latest/version.txt. The hash below is the SHA-256 of
# moshi-hook_Linux_x86_64.tar.gz, and it was checked against the checksum
# upstream publishes for that same asset at
# cdn.getmoshi.app/hook/<version>/checksums.txt:
#
#   sha256 = e348ff0fa10d71f7ff2d260fb9d526b0498cfcfb02db9e26ef77e031ce9eb0ee
#
# That file is the one install.sh verifies against, so this is upstream's hash,
# not one we invented. Nix wants base32/SRI rather than the hex checksums.txt
# publishes, so the value below is that same digest converted:
#
#   sha256 = 40j/D6ENcff/LSYPudUmsEmM/PsC254m73fgMc6esO4=   (SRI, what Nix wants)
#         = e348ff0fa10d71f7ff2d260fb9d526b0498cfcfb02db9e26ef77e031ce9eb0ee (hex)
#
# Use the SRI form, not `nix hash convert --to base32`: Nix parses a
# `sha256-<letters>` hash as base64 unless it is padded, and an unpadded nix32
# digest decodes to the wrong length and is rejected as "invalid SRI hash".
# To move to a newer release: read the version from version.txt, read the
# asset's line out of checksums.txt, convert, and put both here.
{
  lib,
  stdenvNoCC,
  fetchurl,
  symlinkJoin,
  mosh,
  writeShellScriptBin,
  portRange,
}: let
  version = "0.4.11";

  # The archive ships the binary plus a docs/ tree. A statically linked Go
  # binary with no runtime dependencies is the whole story; stdenvNoCC is
  # correct here and keeps the derivation honest about not compiling anything.
  moshiHook = stdenvNoCC.mkDerivation {
    pname = "moshi-hook";
    inherit version;

    src = fetchurl {
      url = "https://cdn.getmoshi.app/hook/v${version}/moshi-hook_Linux_x86_64.tar.gz";
      hash = "sha256-40j/D6ENcff/LSYPudUmsEmM/PsC254m73fgMc6esO4=";
    };

    # fetchurl is a flat file, not a unpacked tree: $src stays the .tar.gz and
    # the unpackPhase writes the real contents into a separate source dir. So
    # read members out of $src explicitly rather than from $src/. That is also
    # why there is no sourceRoot to set.
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin" "$out/share/doc/moshi-hook"
      tar -xzf "$src" -C "$out/bin" --strip-components=0 moshi-hook
      chmod 755 "$out/bin/moshi-hook"
      tar -xzf "$src" -C "$out/share/doc/moshi-hook" --strip-components=0 \
        README.md docs/api.md docs/hooks.md docs/usage.md

      runHook postInstall
    '';

    meta = {
      description = "Moshi host daemon: agent hooks, local gateway and approvals";
      homepage = "https://getmoshi.app";
      license = lib.licenses.unfree; # proprietary binary; not redistributable
      platforms = lib.platforms.linux;
      mainProgram = "moshi-hook";
    };
  };
  # ── mosh, bounded ──────────────────────────────────────────────────────────
  # A wrapper, not a replacement. `pkgs.mosh` is patched to C++20 because its
  # configure step compiles a protobuf-generated file against abseil-cpp >=
  # 202508 headers that need std::partial_ordering (C++20); gcc defaults to
  # gnu++17 and the build otherwise dies with "Could not build output generated
  # by protoc". Overriding the dependency does not help — protobuf_33 and
  # abseil-cpp_202508 both still fail — because the cause is the language
  # standard, not the abseil version.
  #
  # 🔴 This is a LOCAL override: it applies to this closure only. Anything else
  # in the flake that pulls pkgs.mosh gets the unpatched derivation and fails to
  # build. Revisit when nixpkgs fixes mosh itself.
  moshCxx20 = mosh.overrideAttrs (_: {
    NIX_CFLAGS_COMPILE = "-std=c++20";
  });

  # The nixpkgs programs.mosh module has NO port-range option — `openFirewall`
  # only adds `allowedUDPPortRanges = [{from = 60000; to = 61000;}]`, i.e. it
  # opens 1001 ports on every interface without constraining the server, which
  # still allocates from its own default. We set openFirewall = false and bound
  # the server here instead.
  #
  # `-p` is the ONLY spelling mosh-server's `new` subcommand accepts (its usage
  # lists `[-p PORT[:PORT2]]`, no long form), and a flag before the `new`
  # subcommand is rejected with a usage dump. Verified against a live
  # mosh-server: with `-p 60000:60010` it bound exactly one socket,
  # 0.0.0.0:60000; unconstrained it walked up through 60001, 60002, ... and
  # would have left the range open.
  #
  # 🔴 moshServer MUST be listed before moshCxx20 in the paths list below.
  # symlinkJoin resolves same-named files by taking the FIRST occurrence, so
  # with the order reversed the real binary wins and the wrapper is silently
  # discarded — the build succeeds, mosh-server lands on PATH, and the port
  # range is quietly unbounded. That is not hypothetical: it is exactly what the
  # first build of this file did. `readlink -f` the result to check.
  moshServer = writeShellScriptBin "mosh-server" ''
    case "''${1-}" in
      new)
        shift
        exec ${moshCxx20}/bin/mosh-server new -p ${toString portRange.from}:${toString portRange.to} "$@"
        ;;
      *)
        # --version, --help and friends pass through untouched.
        exec ${moshCxx20}/bin/mosh-server "$@"
        ;;
    esac
  '';

  moshBounded = symlinkJoin {
    name = "mosh-bounded-${mosh.version}";
    paths = [
      moshServer
      moshCxx20
    ];

    # Fail the BUILD, not the network, if the wrapper ever stops winning.
    #
    # Compare the LINK TARGET, not the contents. $out/bin/mosh-server is a
    # symlink and lndir has already skipped the collision (it prints
    # "Keeping existing link to ..." when it does), so `cmp` on the file could
    # only ever succeed and the assertion would be worthless. readlink is what
    # actually distinguishes the wrapper from the real binary.
    postBuild = ''
      target="$(readlink "$out/bin/mosh-server")"
      if [ "$target" = "${moshServer}/bin/mosh-server" ]; then
        echo "mosh-server: bounded wrapper in place (allocates only ${toString portRange.from}-${toString portRange.to})"
      else
        echo "ERROR: the bounded mosh-server wrapper lost the name collision in" >&2
        echo "  symlinkJoin - $out/bin/mosh-server points at:" >&2
        echo "    $target" >&2
        echo "  so mosh would allocate outside ${toString portRange.from}-${toString portRange.to}." >&2
        echo "Fix: list moshServer BEFORE moshCxx20 in moshBounded.paths." >&2
        exit 1
      fi
    '';
  };
in
  symlinkJoin {
    name = "moshi-hook-${version}";
    paths = [moshiHook];

    # The install script also drops a `moshi` symlink next to `moshi-hook`, and
    # the docs use both spellings interchangeably (`moshi install`,
    # `moshi-hook install`); the Moshi app's host probe looks for the alias too.
    postBuild = ''
      ln -s $out/bin/moshi-hook $out/bin/moshi
    '';

    passthru = {
      inherit moshBounded;
    };

    meta = moshiHook.meta;
  }
