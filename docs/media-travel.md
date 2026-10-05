# Media and travel

Private media on the Legion, and the MSI travel workflow. Both are **off by
default** and stay that way until somebody provisions them.

| Area | Where | Default |
|---|---|---|
| Jellyfin | `nixos/config/system/media/jellyfin.nix` | off |
| Isolated downloads | `nixos/config/system/media/torrents.nix` | off |
| Optional selective sync | `nixos/config/system/media/syncthing.nix` | off |
| Travel laptop | `nixos/config/home/travel.nix` | on for `gs65` |
| Media state + offline prep | `nixos/config/system/media/scripts/` | with Jellyfin |

Options live in `nixos/options.nix` under `opts.media` and `opts.travel`.

---

## Turning media on

Every switch is off because none of the three can be **half**-configured
safely:

* **Jellyfin** — its first-run wizard creates the administrator account.
  The backend is pinned to IPv4 loopback; private Serve publication is refused
  until both the explicit setup marker and the native completed-setup flag agree.
* **Torrents** — needs a WireGuard credential that cannot honestly be generated
  here. A private key in a git repository is a credential in history.
* **Syncthing** — propagates deletions, and must not be switched on before the
  folder list has been chosen deliberately.

The modules, their refusals and their tests are present and evaluated. What is
missing is your provisioning, which is a deployment step.

---

## Jellyfin

### 1. Enable and create the administrator

```nix
# hosts/legion/options.nix
media.jellyfin.enable = true;
```

Use an authenticated SSH local forward to the server's loopback port, then
open the forwarded URL locally, complete the wizard, and create an administrator.
For the default HTTP port:

```console
ssh -N -L 8096:127.0.0.1:8096 legion-ssh
# Open http://127.0.0.1:8096 on the client.
```

Provision the OpenSSH host-key pin first. Then record completion:

```nix
media.jellyfin.setupCompleted = true;
```

While the marker is false, Serve refuses publication. At startup, the publisher
also reads Jellyfin's native `IsStartupWizardCompleted` flag as the Jellyfin user;
a missing, malformed, or false flag refuses publication and revokes this port's
old mapping. Neither helper creates users nor modifies authentication/setup state.

The startup helper atomically repins native network binding and the configured
HTTP port, preserving unrelated XML settings. IPv6 listeners and discovery are
disabled. This is an inbound boundary, not an outbound metadata policy.

### 2. After the setup wizard — review application settings

These application choices remain operator-managed:

* **Dashboard → Playback → Transcoding**: leave *hardware acceleration* off
  until `jellyfin-accel-check` passes (below).
* **Dashboard → Network → Enable external access**: leave off. The service is
  published through a private Tailscale Serve listener; Jellyfin must not also
  believe it is on the public internet.
* Review installed plugins and metadata providers before allowing outbound
  requests. Do not assume private Serve also enforces an egress policy.

### 3. The Serve port

Collie owns tailnet HTTPS **443** (`config/system/mobile-agents.nix`). Jellyfin
takes **8443** by default. If you set Jellyfin's port to 443 while Collie is
enabled, the build **fails** — two units writing one Serve port is a race where
the loser is silently broken, so it is an evaluation error rather than a
boot-time surprise.

`ExecStop` turns off its own port and nothing else. `tailscale serve reset`
erases every mapping on the node, including Collie's — which is why A's
reconcile script avoids it and why no unit here runs it.

#### Checking the Serve port

The pinned Tailscale is **1.102.5**. Confirm before enabling:

```console
$ tailscale serve --help | grep -A2 -- --https
```

`--https=<port>` is accepted; the CLI also refuses conflicting listeners
(`cannot serve TCP; already serving web on %d`). 8443 is the alternate HTTPS
port Tailscale Serve supports. Verify on your own node with
`tailscale serve status` after the first activation.

### 4. Hardware transcoding — check first, then decide

"It has an Intel GPU" is not a statement about QSV being usable. The render
node, `intel-media-driver`, the GuC/HuC firmware and the codec build each have
to be present independently.

```console
$ jellyfin-accel-check
ok   VAAPI render node present: /dev/dri/renderD128
ok   intel-media-driver userspace present (/nix/store/…/bin/vainfo)
ok   codec available: h264_vaapi
ok   codec available: hevc_vaapi
=== verdict ===
Hardware transcoding is available.
```

If it fails, **leave it off**. Software transcoding is correct and slower, and
it keeps the discrete NVIDIA GPU free for inference. To override deliberately:

```nix
media.jellyfin.hardwareAcceleration.enable = true;
media.jellyfin.hardwareAcceleration.acknowledgeMissing = true;   # visible in the diff
```

`type = "nvenc"` is **refused by assertion**. The discrete GPU is for inference
in this configuration; handing the transcoder the same device is the ordinary
way inference runs out of memory the first time somebody plays something.

> **PENDING — real hardware.** Hardware acceleration, playback and seek, and
> real-WAN throughput have **not** been verified on this machine. Nothing below
> is a claim that they work. Run § "Acceptance before travelling" yourself.

---

## Isolated downloads

qBittorrent runs **unprivileged, inside a dedicated network namespace**, whose
only way out is a WireGuard tunnel.

### The property that matters

The tunnel disappearing must stop downloads. It must **not** stop SSH,
tailscaled, Collie, herdr or Jellyfin.

That is structural rather than a matter of unit ordering: none of those are in
the namespace. Inside it, `OUTPUT`'s policy is `DROP` and the tunnel is allowed
**by name**:

```sh
iptables -A OUTPUT -o wg0 -j ACCEPT     # while wg0 is absent this matches NOTHING
iptables -P OUTPUT DROP                # unmatched packets are refused
```

Binding qBittorrent to the tunnel is **defence in depth**, not the kill switch.
It covers only the paths that go through that socket — a resolver running
separately, or any code that opens its own socket, is not covered by it.

### Egress, exhaustively

| Rule | Purpose |
|---|---|
| `-o lo` | loopback |
| `-o wg0` | the tunnel; matches nothing while absent |
| veth replies to the host proxy's established WebUI connection | proxy responses only |
| no veth DNS/Internet rule | no namespace DNS or Internet escape |
| `OUTPUT` **DROP** | policy |
| `ip6tables OUTPUT` **DROP** | all IPv6 |
| `INPUT` allow lo and exact host proxy tuple; reject tunnel WebUI; default **DROP** | no direct tunnel WebUI access |

There is **no default route via the veth** — a `/32` host route to the veth
peer and nothing more. Routing and netfilter are two independent mechanisms;
either alone would be a single point of failure.

### Why the endpoint is numeric

The WireGuard interface is created on the host and then moved into the namespace.
Its encrypted UDP socket remains host-born: no endpoint exception, forwarding,
DNAT or masquerading is needed inside the namespace. A numeric IPv4 endpoint
keeps bootstrap deterministic; `netns-up.sh` rejects a hostname endpoint.

Resolve once, on the host, and paste the result:

```console
$ getent ahosts vpn.example.com | head -1
203.0.113.7
```

### The host firewall is not touched

**This lane never changes the host OUTPUT policy.** A narrowly scoped owner rule
rejects direct backend traffic from any UID other than the dedicated proxy UID.

The existing wg-quick kill-switch in `config/system/networking.nix` is why:
an OUTPUT rule that rejects everything not marked for the tunnel rejects the
**tailnet** too, and on a box in a basement that is a lockout. That module
structurally omits it on a server for exactly this reason.

The veth is not a trusted interface. The owner-scoped OUTPUT rejection targets
only the namespace backend address/port, not general host traffic; no host NAT or
forwarding is enabled. The proxy binds loopback and authenticates before connecting.

### The WebUI

Reachable from exactly one place: `127.0.0.1` on the server, through a proxy
that refuses to bind anything else at start-up and requires a token from a
**systemd credential**. A refused request never produces a packet inside the
namespace.

qBittorrent's own authentication is necessary but not sufficient: a freshly
provisioned instance — and an instance restored from backup — has no password.

### Upload is bounded, or not at all

`uploadLimitKbit = null` means **unbounded seeding**, and you get a build
warning saying so. Seeding competes directly with remote builds, SSH and
streaming over the tailnet.

Shape it on the tunnel with a token bucket, not in qBittorrent's settings: a
UI change cannot raise it.

### Provisioning

```nix
# hosts/legion/options.nix
media.torrents.enable = true;
media.torrents.tunnel.endpoint = "203.0.113.7:51820";   # numeric, from getent
media.torrents.uploadLimitKbit = 900;                   # after measuring
```

Generate the WireGuard config **on a machine already configured for the
provider**, and keep it out of this repository:

```console
$ wg-quick strip wg0 > media-wg.conf     # on the provider-configured machine
$ sops --encrypt --in-place media-wg.conf
# store at the path in opts.media.torrents.tunnel.configSecretPath
```

Do the same for the proxy token:

SOPS rejects `--in-place` when the value arrives on stdin with no input file,
so piping `openssl` into it cannot produce the encrypted file this module
reads. Write it first, then encrypt that file in place:

```console
$ umask 077 && openssl rand -hex 32 > media-webui-token
$ sops --encrypt --in-place media-webui-token   # -> proxyTokenSecretPath
```

### Checking the ENABLED configuration

Every media service ships disabled, so ordinary evaluation only proves the
defaults are inert — and an inert-but-broken configuration looks exactly like an
inert one. The enabled path has to be checked by hand, by temporarily flipping
the `enable = false` defaults in `nixos/options.nix`:

```console
$ cd nixos
$ nix eval --raw '.#nixosConfigurations.legion.config.system.build.toplevel.drvPath'
$ git checkout -- options.nix        # revert; never commit the flip
```

Do this before merging anything that touches these modules. On this PR it found
faults that no default-off evaluation could see: an unresolved `package = null`
reaching `lib.getExe`, a tmpfiles rule naming `cfg.incompleteDir` in a module
that has no such option, `networking.firewall.interfaces.*.log` (not an option),
an attrset passed to `serviceConfig.Environment` on three units, and a
self-referencing `config.environment.etc` read that presented as infinite
recursion. Each would have been the first failure of a real deployment, found
after the fact instead of in review.

## Verify before travelling

```console
$ netns-audit
=== netns-audit: namespace medtns ===
  ok   iptables OUTPUT policy is DROP
  ok   iptables INPUT policy is DROP
  ok   an ACCEPT rule for -o wg0 is installed
  ok   no default route via mtns0
  ok   every permitted INPUT rule is loopback or the host proxy on 18080
  --- permitted rules scoped to mtns0 (3) ---
      -A OUTPUT -o mtns0 -p udp -d 203.0.113.7 --dport 51820 -j ACCEPT
      -A OUTPUT -o mtns0 -p udp --dport 53 -j DROP
      -A OUTPUT -o mtns0 -p tcp --dport 53 -j DROP
=== netns-audit: 14 check(s), 0 failure(s) ===
The namespace is fail-closed.
```

It is **read-only**: it adds, removes and flushes nothing. Run it against the
live namespace, and again after pulling the tunnel.

---

## The travel laptop

### SSH aliases

Two aliases, because they are two different services:

| Alias | Port | Auth | Use for |
|---|---|---|---|
| `legion` | 2222 | key | scripts, the Nix builder, port forwards |
| `legion-tailscale` | 22 | Tailscale identity | a device with no private key |

The Tailscale alias deliberately offers **no** `IdentityFile`: a key cannot
authenticate there, and offering one just waits for a handshake that will not
succeed.

#### Pin the host key

Unpinned is generated as a **visible failing configuration**, not a working one:

```console
$ legion$ cat /etc/ssh/ssh_host_ed25519_key.pub
```

```nix
# hosts/gs65/options.nix
travel.serverHostKey = "ssh-ed25519 AAAAC3…";
```

A TOFU prompt on a tailnet is exactly where you do not want to be asked to
approve a key you did not verify.

### The Nix builder

**Port 2222, not 22.** `--ssh=true` means Tailscale SSH answers on tailnet port
22 *before* the OS sshd sees the connection, authenticating with a Tailscale
identity and bypassing `authorized_keys`. A key-based builder pointed at 22
stalls on a handshake or is refused by the ACL, and reports from the wrong
layer. "SSH to the Legion works" is **not** evidence the builder works.

> `hostName` is kept **bare**. `/etc/nix/machines` is a whitespace-split line of
> `<host> <system> <sshKey> <maxJobs> …`, so an `-p 2222` inside `hostName`
> shifts every later field — the builder then no longer advertises
> `x86_64-linux` and is silently skipped for those builds. The port is pinned
> with `NIX_SSHOPTS` on the Nix daemon, which is Nix's own mechanism, plus the
> generated `Host legion / Port 2222` ssh config.

**On privilege:** the builder's account is in `nix.settings.trusted-users`, and
trusted users can drive the daemon, which is **root-equivalent**. A dedicated
account does not make that unprivileged — it makes it separately revocable. It
is deliberately **not** given blanket `NOPASSWD` sudo to imitate a narrower
boundary.

### herdr remote attachment

```console
$ herdr-travel status
$ herdr-travel attach legion        # native --machine <id>, resolved from herdr machine list
$ herdr-travel run legion <cmd>
$ herdr-travel local <cmd>          # no server needed — the offline fallback
```

* **`--machine` is not sticky.** Selecting a machine in the UI does not
  retarget your shell. Every remote command passes an explicit `--machine <id>`,
  resolved from the server rather than hard-coded.
* **Nothing here restarts, upgrades or replaces a herdr server.** The server
  holds your running agents; an incompatible client is refused with a pointer
  to fixing the *client*, and the local fallback works with no server at all.

---

## Offline media preparation

Copies **already-chosen** library items to a cache the laptop can carry. No
downloads, no purchases, no subscriptions, no services.

```console
$ media-offline-prep 'Films/Example (2024)/Example (2024).mkv'
  Films/Example (2024)/Example (2024).mkv                      12G
1 item(s), 12G total
[offline-prep] space ok: 410000 MiB free
[offline-prep] copied Films/Example (2024)/Example (2024).mkv
[offline-prep] offline cache ready: 1 item(s)
```

The selector is **required** and all-or-nothing: every item is resolved before
anything is copied, because a partial offline cache is indistinguishable from a
complete one until you are on a plane. It then verifies readability *as the
media user*, because a cache that Jellyfin cannot open looks like an empty
library.

Dry run first: `MEDI_DRY_RUN=1`.

---

## Sync is not backup

🔴 **Syncthing propagates deletions.** A file removed on the laptop is removed
on the server, immediately.

* **restic** — a snapshot in time; deleting a file does not delete yesterday's
  copy. **This is the backup.**
* **Syncthing** — a live mirror. Not a backup, under any reading.

The ignore rules are the security control, not a convenience:

* `.git/`, `worktrees/` — two repositories that disagree; corrupted uncommitted
  work.
* `*.db`, `*.sqlite*`, `*-wal`, `*-journal` — a half-copied database is valid
  and corrupt at once.
* `.pi/`, `sessions/`, `herdr/` — two agents writing one synchronised session
  store corrupts both.
* `.ssh/`, `id_*`, `*.age`, `*.key`, `*.pem`, `.env*`, `secrets.yaml` — a
  synchronised private key is a private key on another device.
* `tailscaled.state` — two devices sharing one node key is a tailnet incident.

Folders default to **empty**. The module refuses a whole-home or Tailscale-state
folder at evaluation.

Media state is **exported** (`media-state`) and backed up by restic, not
mirrored — see `docs/agent-operations.md`.

---

## Measuring bandwidth

Tailscale may use direct UDP or relays; encryption does not guarantee
worldwide bitrate. Reserve upload headroom for interactive access.

1. Measure the **home upstream** from where you will actually be — an upload
   from a hotel measures the hotel.
2. Reserve headroom for SSH, builds and streaming.
3. Set `uploadLimitKbit` to 20–30% of the measured upstream. A starting point,
   not a recommendation.

A 1080p 4–8 Mbps remote profile is an experiment, not a promise. Test a
representative high-bitrate file and seek behaviour.

---

## Acceptance before travelling

**Not performed. Recorded as pending, not as passing.**

- [ ] `netns-audit` against the live namespace, before and after pulling the tunnel
- [ ] Leak drill: remove the tunnel mid-transfer; confirm IPv4, IPv6 and direct
      DNS are all dead **and** that SSH, Tailscale, Collie and Jellyfin stay up
- [ ] `jellyfin-accel-check`; playback and seek of a representative high-bitrate file
- [ ] Direct-vs-relay measurement from the real WAN
- [ ] Confirm `herdr-travel local` works with no server reachable (hotel wifi)
- [ ] `media-offline-prep` dry run, then a real copy
- [ ] Builder: `nix build` on the laptop, confirm it ran on the Legion
- [ ] Confirm restic restore into a scratch location (never over live data)

---

## Tests

```console
$ bash nixos/tests/media-travel/run.sh          # developer run; every suite must run
$ nix build .#checks.x86_64-linux.media-travel  # sandbox
```

| Suite | Covers |
|---|---|
| `netns-failclosed.sh` | hostname refusal, DROP policies on both stacks, single-UDP bootstrap, DNS drops, no default route, INPUT scope |
| `state-restore.sh` | real SQLite export, corrupt database refused, previous export preserved, missing export is a failure |
| `selective-sync.sh` | ignore rules against a fixture tree of one of each hazard |
| `travel-builder.sh` | explicit `--machine`, capability refusal, **server-restart tripwire**, local fallback |
| `host-isolation.sh` | both hosts evaluated: media inert by default, Collie keeps 443, firewall unchanged, builder pinned |

`netns-failclosed.sh` drives the **shipped** `netns-up.sh` with stubbed
privileged tools, so it asserts the netfilter calls the script actually makes
rather than that a string appears in a file.

**Pending:** a live namespace (`netns-audit.sh`, needs root and a provisioned
tunnel) and real hardware. See "Acceptance before travelling".

> **Known pre-existing failure, not caused by this PR:**
> `nixos/tests/server-foundation/host-eval.sh` fails 24 assertions on `master`
> (`1a4d262`) as well as on this branch. It is a server-foundation issue and is
> left alone here; see the PR description.