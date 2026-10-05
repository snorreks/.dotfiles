#!/usr/bin/env bash
# nixos/tests/server-foundation/host-eval.sh — evaluate the REAL flake outputs
# for both hosts, both variants and a set of role combinations.
#
# ── Why this is a separate suite ─────────────────────────────────────────────
# The other suites in this directory check logic: a script with fakes, or a pure
# function with `nix eval --file`. This one checks what actually gets BUILT, by
# asking the real flake to evaluate `nixosConfigurations.<host>.config.…`.
#
# It is kept out of the fast lane for the reason the maintenance VM test is kept
# out of it: it pulls in a full module evaluation (about a minute for four
# configurations here, minutes once the input set grows), and it needs `nix` on
# PATH. It is registered as its own flake check so it runs in `nix flake check`
# without making the seconds-long shell suite wait for it.
#
# Nothing here builds or activates anything. Evaluating a configuration reads
# no hardware, opens no socket and changes nothing on either machine.
#
# Run directly:  bash nixos/tests/server-foundation/host-eval.sh
set -o nounset -o pipefail

# `nix eval` is a CLI subcommand and needs the nix-command feature. Inside a
# `checks` sandbox there is no nix.conf and no HOME configuration to supply it,
# so the suite sets it for itself rather than depending on the caller's
# environment. Set, not prepended: whatever the caller already enabled is kept.
export NIX_CONFIG="${NIX_CONFIG:-}"$'\n'"experimental-features = nix-command flakes"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

printf '\n\033[1mserver-foundation — host evaluation (legion / gs65 / fast, role combinations)\033[0m\n'

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

t_start() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '  %s\n' "$1"
}
_fail() {
  printf '    FAIL %s: %s\n' "${CURRENT_TEST:-<none>}" "$*" >&2
  TESTS_FAILED=$((TESTS_FAILED + 1))
}
t_done() {
  [[ "$TESTS_FAILED" -gt 0 ]] && return 0
  printf '    ok   %s\n' "$CURRENT_TEST"
  CURRENT_TEST=""
}
assert_eq() {
  if [[ "$2" == "$3" ]]; then return 0; fi
  _fail "$1: expected '$2', got '$3'"
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then return 0; fi
  _fail "$1: expected '$3' in '$2'"
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then return 0; fi
  _fail "$1: did NOT expect '$3' in '$2'"
}

# Evaluate one path of one real flake output.
#
# stderr is captured separately and only reported when the evaluation FAILS.
# `nix eval` prints builtins.trace output on stderr, and the hosts emit policy
# warnings through exactly that mechanism — merging the streams would prepend
# "trace: …" to every value and make a correct assertion fail on formatting.
cfg() {
  local output="$1" path="$2" err
  err="$(mktemp)"
  if ! nix eval --impure --json --expr "
    let
      flake = builtins.getFlake (toString ${ROOT});
      system = flake.nixosConfigurations.\"${output}\";
    in
      ${path}
  " 2>"$err"; then
    printf 'EVAL ERROR: %s\n' "$(head -5 "$err")"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
}

# Evaluate a synthetic configuration: the repository's own system modules with a
# chosen `opts`, and nothing else. Fast (a few seconds), and it is how a role
# combination gets checked without editing a host's options file — which is the
# whole point of making the policy a pure function in the first place.
#
# The `headless` passed to the modules is derived by the SAME function the flake
# uses, not re-derived here. Otherwise a test would assert on its own idea of the
# precedence and could pass while the real flake does the opposite.
combo() {
  local role="$1" headless="$2" extra="$3" path="$4" modules="${5:-}" err
  [[ -n "$modules" ]] || modules='{}'
  err="$(mktemp)"
  if ! nix eval --impure --json --expr "
    let
      flake = builtins.getFlake (toString ${ROOT});
      policy = import ${ROOT}/lib/host-policy.nix;
      lib = flake.inputs.nixpkgs.lib;
      base = import ${ROOT}/options.nix;
      declared = { role = ${role}; headless = ${headless}; };
      # recursiveUpdate all the way down, including for the per-test override:
      # a shallow merge operator would replace a whole nested attrset (mobileAgents)
      # with a two-key stub, and the failure would read as a policy problem
      # rather than as the test's own mistake.
      opts = lib.recursiveUpdate (lib.recursiveUpdate (lib.recursiveUpdate base declared) {
        role = policy.resolveRole declared;
        headless = policy.resolveHeadless declared;
      }) ${extra};
      system = lib.nixosSystem {
        system = \"x86_64-linux\";
        specialArgs = { inputs = flake.inputs; system = \"x86_64-linux\"; inherit opts; };
        # Match the real hosts' external option declarations. Even disabled
        # mkIf definitions must refer to declared options.
        modules = [
          ${ROOT}/system.nix
          flake.inputs.sops-nix.nixosModules.sops
          flake.inputs.mangowm.nixosModules.mango
          flake.inputs.impermanence.nixosModules.impermanence
          ${modules}
        ];
      };
    in
      ${path}
  " 2>"$err"; then
    printf 'EVAL ERROR: %s\n' "$(head -5 "$err")"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
}

# ─────────────────────────────────────────────────────────────────────────────
t_start "both hosts and both variants evaluate"
# legion/gs65 come from the hosts' own option files; legion-fast/gs65-fast skip
# the CUDA build. All four have to keep working — a role change that broke the
# -fast variant would only be noticed the day someone wanted a quick rebuild.
for output in legion gs65 legion-fast gs65-fast; do
  out="$(cfg "$output" 'system.config.networking.hostName')"
  case "$out" in
    *'"legion"'* | *'"gs65"'*) ;;
    *) _fail "nixosConfigurations.$output did not evaluate (got: $(printf '%s' "$out" | head -3))" ;;
  esac
done
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the Legion resolves to the server role and the GS65 to desktop"
legion="$(cfg legion 'system.config.hostPolicy')"
gs65="$(cfg gs65 'system.config.hostPolicy')"
assert_contains "legion is a server" "$legion" '"role":"server"'
assert_contains "legion is headless" "$legion" '"headless":true'
assert_contains "gs65 is a desktop" "$gs65" '"role":"desktop"'
assert_contains "gs65 is not headless" "$gs65" '"headless":false'
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "role drives the behaviours modules actually gate on"
# NOTE on what is asserted here: `systemd.targets.sleep` is not a good probe.
# The option only EXISTS because config/system/server.nix references it under a
# headless condition, so on a desktop the attribute is genuinely absent and
# asserting on it tests the reference, not the policy. These three are declared
# unconditionally, which is what makes them evidence.
server="$(combo '"server"' true '{}' 'system.config.networking.networkmanager.wifi.macAddress')"
desktop="$(combo '"desktop"' false '{}' 'system.config.networking.networkmanager.wifi.macAddress')"
assert_eq "a server pins its Wi-Fi MAC" '"permanent"' "$server"
assert_eq "a travel laptop still randomises it" '"random"' "$desktop"

server="$(combo '"server"' true '{}' 'builtins.elem "sonny" system.config.nix.settings.trusted-users')"
desktop="$(combo '"desktop"' false '{}' 'builtins.elem "sonny" system.config.nix.settings.trusted-users')"
assert_eq "a server trusts the user for the nix daemon (remote builds)" "true" "$server"
assert_eq "a desktop does not, by default" "false" "$desktop"

desktop="$(combo '"desktop"' false '{}' 'system.config.services.greetd.settings.initial_session.command or "none"')"
assert_contains "a desktop still autologins into mango" "$desktop" "mango"
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "role = null still resolves from the compatibility boolean"
legacy="$(combo 'null' true '{}' 'system.config.hostPolicy.role')"
assert_eq "headless = true alone still means server" '"server"' "$legacy"
plain="$(combo 'null' false '{}' 'system.config.hostPolicy.role')"
assert_eq "headless = false alone means desktop" '"desktop"' "$plain"
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "server without mobile agents still gets lingering"
# The bug this lane exists to prevent: an always-on box with the phone clients
# switched off had a session-lifetime policy inherited from a laptop.
out="$(combo '"server"' true '{ mobileAgents.enable = false; }' 'system.config.users.users."sonny".linger')"
assert_contains "the user manager exists with nobody logged in" "$out" "true"

# …and the phone-only host keeps it too, which is the other half of the union.
out="$(combo '"desktop"' false '{ mobileAgents.enable = true; }' 'system.config.users.users."sonny".linger')"
assert_contains "mobile agents alone are enough" "$out" "true"

# …and a plain desktop is not silently opted into lingering, which would keep a
# user manager alive forever on a laptop that is closed for a week.
out="$(combo '"desktop"' false '{ mobileAgents.enable = false; }' 'system.config.users.users."sonny".linger')"
assert_eq "a plain desktop is left alone" "null" "$out"
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the DNS owner, the list and the cap agree on a server"
out="$(combo '"server"' true '{}' 'system.config.hostPolicy.dns')"
assert_contains "one owner" "$out" '"owner":"dnscrypt-proxy"'
assert_contains "loopback first" "$out" '"127.0.0.1"'
assert_contains "a numeric rescue" "$out" '"9.9.9.9"'
assert_contains "the list fits glibc MAXNS" "$out" '"maxnames":3'

# The cap is only meaningful if it reaches the resolver. resolv.conf options are
# where glibc reads MAXNS from, so this asserts the wiring, not just the number.
out="$(combo '"server"' true '{}' 'system.config.networking.resolvconf.extraOptions')"
assert_eq "unsupported maxnames option is absent" '[]' "$out"

out="$(combo '"server"' true '{}' 'system.config.networkmanager.dns or system.config.networking.networkmanager.dns')"
assert_contains "NetworkManager still keeps out of the resolver's way" "$out" '"none"'
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the Proton VPN is structurally absent from a server role"
wg="$(combo '"server"' true '{}' 'system.config.networking.wg-quick.interfaces.wg0 or "absent"')"
assert_eq "no wg0 interface exists" '"absent"' "$wg"

rules="$(combo '"server"' true '{}' 'system.config.security.sudo.extraRules')"
case "$rules" in
  *wg-quick* | *proton-wg*) _fail "a server must have no NOPASSWD rule that can write the VPN config (got: $rules)" ;;
  *) : ;;
esac

# …and it is all still there on a desktop, or the toggle would simply be broken.
wg="$(combo '"desktop"' false '{}' 'builtins.hasAttr "wg0" system.config.networking.wg-quick.interfaces')"
assert_eq "the desktop keeps the interface" "true" "$wg"
rules="$(combo '"desktop"' false '{}' 'system.config.security.sudo.extraRules')"
assert_contains "and its sudo rule" "$rules" "wg-quick-wg0"
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "boot counting is opt-in, and wired when it is on"
out="$(cfg legion 'system.config.boot.loader.systemd-boot.bootCounting.enable')"
assert_eq "off by default on the shipped server" "false" "$out"

out="$(combo '"server"' true '{ bootHealth.enable = true; }' 'system.config.boot.loader.systemd-boot.bootCounting')"
assert_contains "boot counting turns on" "$out" '"enable":true'
assert_contains "with the configured number of tries" "$out" '"tries":3'

out="$(combo '"server"' true '{ bootHealth.enable = true; }' 'system.config.systemd.services.systemd-bless-boot.requires')"
assert_contains "and the blessing waits for the local gate" "$out" "boot-health-local.service"
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the shared NTFS volume is not mounted by default, on either host"
for output in legion gs65; do
  out="$(cfg "$output" 'builtins.hasAttr "/mnt/shared" system.config.fileSystems')"
  assert_eq "$output has no /mnt/shared" "false" "$out"
  # The kernel module stays: copying a file off it by hand during recovery is a
  # different question from mounting it at every boot.
  out="$(cfg "$output" 'builtins.hasAttr "ntfs" system.config.boot.supportedFilesystems')"
  assert_eq "$output can still read NTFS by hand" "true" "$out"
done
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "both OpenSSH listeners survive, and 2222 is never the LAN's business"
for output in legion gs65; do
  ports="$(cfg "$output" 'system.config.services.openssh.ports')"
  assert_contains "$output still listens on 22" "$ports" "22"
  # 2222 exists only where the mobile layer is enabled, and asserting otherwise
  # would be asserting that a switch has no effect.
  if [[ "$output" == "legion" ]]; then
    assert_contains "the Legion also listens on 2222" "$ports" "2222"
    open="$(cfg "$output" 'system.config.services.openssh.openFirewall')"
    assert_eq "and does not open its sshd ports on every interface" "false" "$open"
    allowed="$(cfg "$output" 'system.config.networking.firewall.allowedTCPPorts')"
    assert_contains "only 22 is opened, never 2222" "$allowed" "22"
    case "$allowed" in
      *2222*) _fail "2222 must never be a firewall exception on any interface (got: $allowed)"; ;;
      *) : ;;
    esac
  else
    open="$(cfg "$output" 'system.config.services.openssh.openFirewall')"
    assert_eq "the travel laptop keeps today's sshd firewall behaviour" "true" "$open"
  fi
done
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the Serve mapping is owned by the mobile layer, not by the reconciler"
# The reconciler repairs it; mobile-agents.nix declares it. Both are asserted so
# that neither quietly takes the other half.
for output in legion gs65; do
  out="$(cfg "$output" 'builtins.hasAttr "tailscale-serve-collie" system.config.systemd.services')"
  if [[ "$output" == "legion" ]]; then
    assert_eq "the Legion declares the Collie Serve unit" "true" "$out"
  else
    assert_eq "the GS65 declares no Collie Serve unit" "false" "$out"
  fi
  out="$(cfg "$output" 'system.config.systemd.services.tailscale-reconcile.environment.NM_TS_SERVE_HTTPS_PORT or "none"')"
  if [[ "$output" == "legion" ]]; then
    assert_eq "and the reconciler is told to manage 443" '"443"' "$out"
  else
    assert_eq "and the reconciler manages nothing there" '"0"' "$out"
  fi
done
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the kernel parameters that taint the kernel are gone, per host"
for output in legion gs65; do
  out="$(cfg "$output" 'system.config.boot.kernelParams')"
  assert_not_contains "$output no longer passes i915.enable_guc (it taints)" "$out" "enable_guc"
  assert_contains "$output keeps the NVIDIA video-memory parameter" "$out" "NVreg_PreserveVideoMemoryAllocations"
  assert_contains "$output keeps acpi_osi=Linux" "$out" "acpi_osi=Linux"
  out="$(cfg "$output" 'system.config.boot.kernelModules')"
  assert_not_contains "$output does not load acpi_call for nothing" "$out" '"acpi_call"'
done
# …and it can still be asked for explicitly, which is what "per-host" has to mean.
out="$(combo '"server"' true '{ acpi = { i915Guc = 2; acpiCall = true; }; }' 'system.config.boot.kernelParams')"
assert_contains "an operator can still ask for it" "$out" "i915.enable_guc=2"
out="$(combo '"server"' true '{ acpi = { i915Guc = 2; acpiCall = true; }; }' 'system.config.boot.kernelModules')"
assert_contains "and for acpi_call too" "$out" '"acpi_call"'
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the aggressive global service deadlines are gone"
for output in legion gs65; do
  out="$(cfg "$output" 'system.config.systemd.settings.Manager.DefaultTimeoutStopSec or "default"')"
  assert_eq "$output does not shorten every stop to 10s" '"default"' "$out"
  out="$(cfg "$output" 'system.config.systemd.services.nix-daemon.serviceConfig.TimeoutStopSec or "none"')"
  assert_eq "$output gives the nix daemon a real deadline instead" '"10min"' "$out"
done
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "start limits are in the [Unit] section where systemd reads them"
# StartLimitIntervalSec under serviceConfig is silently ignored, which is how a
# "keep retrying forever" resolver or tailscaled turns into "gave up after five
# tries" three weeks later.
for output in legion gs65; do
  for unit in dnscrypt-proxy tailscaled-set; do
    out="$(cfg "$output" "system.config.systemd.services.\"${unit}\".startLimitIntervalSec or \"absent\"")"
    assert_eq "$output/$unit rate limiting off, in [Unit]" "0" "$out"
  done
  out="$(cfg "$output" 'system.config.systemd.services.dnscrypt-proxy.serviceConfig.StartLimitBurst or "none"')"
  assert_eq "$output has no StartLimitBurst hiding in [Service]" '"none"' "$out"
done
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the tailscale flags are unchanged where they must not change"
out="$(cfg legion 'system.config.services.tailscale.extraSetFlags')"
assert_contains "SSH is still on" "$out" "--ssh=true"
assert_contains "MagicDNS is still refused" "$out" "--accept-dns=false"
assert_contains "the exit node is still advertised" "$out" "--advertise-exit-node=true"
out="$(cfg gs65 'system.config.services.tailscale.extraSetFlags')"
assert_contains "the travel laptop does not advertise an exit node" "$out" "--ssh=true"
assert_not_contains "and has no exit node" "$out" "--advertise-exit-node"
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the reconciler is timer-driven, and never persistent"
out="$(cfg legion 'system.config.systemd.timers.tailscale-reconcile.timerConfig.Persistent')"
assert_eq "a missed tick is not replayed" "false" "$out"
out="$(cfg legion 'system.config.systemd.timers.tailscale-reconcile.timerConfig.OnUnitActiveSec')"
assert_eq "it retries on a schedule" '"5min"' "$out"
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "sudo is configured to keep the variables the new-connection check reads"
# `ns-maint confirm` must run as root, and sudo's env_reset strips SSH_CONNECTION
# on the way — which turns every confirmation from an SSH session into "this is
# not an SSH session". The fix has to be keeping those variables, not weakening
# the check; the other answer is --assume-new-connection, which is precisely the
# flag that means "I could not verify this".
out="$(cfg legion 'system.config.security.sudo.extraConfig')"
for var in SSH_CONNECTION SSH_CLIENT SSH_TTY; do
  case "$out" in
    *env_keep*"$var"* | *"env_keep"*"$var"*) : ;;
    *) _fail "sudo must keep $var across the privileged wrapper (got: $out)" ;;
  esac
done
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the confirm unit is the one BOTH OpenSSH listeners log to"
out="$(cfg legion 'let p = builtins.head (builtins.filter (p: (p.name or "") == "ns-maint") system.config.environment.systemPackages); in builtins.elem "export NM_SSH_UNIT=sshd.service" (builtins.filter builtins.isString (builtins.split "\n" p.text))')"
assert_eq "the trusted executable embeds sshd.service, which covers 22 and 2222" 'true' "$out"
out="$(cfg legion 'system.config.maintenance.confirmSSHUnit')"
assert_eq "and the option behind it says the same" '"sshd.service"' "$out"
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the boot staging preflight knows which partition and how much it needs"
out="$(cfg legion 'system.config.maintenance.espPath')"
assert_eq "the ESP is measured at the mount systemd-boot writes to" '"/boot"' "$out"
out="$(cfg legion 'system.config.maintenance.espMinMib')"
assert_eq "with a floor above one NixOS entry" "150" "$out"
out="$(cfg legion 'let p = builtins.head (builtins.filter (p: (p.name or "") == "ns-maint") system.config.environment.systemPackages); in builtins.elem "export NM_ESP_MIN_MIB=150" (builtins.filter builtins.isString (builtins.split "\n" p.text))')"
assert_eq "and the trusted executable embeds the same floor" 'true' "$out"
out="$(cfg legion 'builtins.filter (name: builtins.substring 0 3 name == "NM_") (builtins.attrNames system.config.systemd.services.ns-maint-verify.environment)')"
assert_eq "the unit no longer relies on caller/manager NM_* injection" '[]' "$out"
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "resource weights reach real services and user slices have a valid hierarchy"
resource_modules='{ agentOps.resources.enable = true; services.ollama.enable = true; services.jellyfin.enable = true; services.syncthing.enable = true; }'
out="$(combo '"server"' true '{ enableOllama = false; }' 'system.config.systemd.user.slices."agent-workload-build".sliceConfig' "$resource_modules")"
assert_contains 'build slice has its real CPU weight' "$out" '"CPUWeight":128'
assert_not_contains 'Slice= is not emitted into a [Slice] section' "$out" '"Slice"'
out="$(combo '"server"' true '{ enableOllama = false; }' '[ system.config.systemd.services.nix-daemon.serviceConfig.CPUWeight system.config.systemd.services.ollama.serviceConfig.CPUWeight system.config.systemd.services.jellyfin.serviceConfig.CPUWeight system.config.systemd.services.syncthing.serviceConfig.CPUWeight system.config.systemd.services.sshd.serviceConfig.CPUWeight system.config.systemd.services.tailscaled.serviceConfig.CPUWeight ]' "$resource_modules")"
assert_eq 'real build, inference, transcode, sync and management services receive weights' '[128,256,256,64,2048,2048]' "$out"
out="$(combo '"server"' true '{}' '[ system.config.agentOps.resources.policy.build.cpuWeight system.config.agentOps.resources.policy.build.ioWeight system.config.agentOps.resources.policy.management.cpuWeight ]' '{ agentOps.resources.enable = true; agentOps.resources.policy.build.cpuWeight = 192; }')"
assert_eq 'a partial class override retains every other default' '[192,32,2048]' "$out"
out="$(combo '"server"' true '{}' 'builtins.hasAttr "custom-load-build" system.config.systemd.user.slices' '{ agentOps.resources.enable = true; agentOps.resources.slice = "custom-load"; }')"
assert_eq 'class hierarchy follows the configured parent name' true "$out"
t_done

if [[ "$TESTS_FAILED" -ne 0 ]]; then
  printf '\n\033[31mhost-eval: %d assertion(s) failed\033[0m\n' "$TESTS_FAILED"
  exit 1
fi
printf '\n\033[32mhost-eval: all %d checks passed\033[0m\n' "$TESTS_RUN"
