# Mobile Agents — reaching herdr from Android

Reach the Legion from a phone and drive the **same** persistent herdr workspaces
and pi / Claude Code / OpenCode agents you use at the desk. Same server, same
panes, same agent processes. The phone is a second client, not a second stack.

**Collie** is the primary Android interface: a PWA served from the host's own
loopback port through **private Tailscale Serve**, with HTTPS, a tailnet-identity
gate, and per-device pairing. It needs nothing from SSH and nothing from Moshi.

Two older paths remain available after provisioning the phone key (§8):

- **SSH / Mosh on port 2222** — client-independent infrastructure. Moshi uses it;
  so does Termux; so do you.
- **Moshi** — optional, and **off** on legion now. One boolean away.

---

## 1. Architecture

```
  Android phone                      Legion (daily-driver desktop)
 ┌──────────────────┐                ┌──────────────────────────────────────┐
 │ Chrome / PWA     │                │                                      │
 │  ├ Collie        │                │  tailscale0 ── trusted by firewall    │
 │  │  (paired)     │── HTTPS :443 ─▶│    tailscaled Serve (private)         │
 │  │               │  via tailscale  │      │                               │
 │  │               │                │      ▼                               │
 │  │               │                │    127.0.0.1:8787  collie _exec-bridge│
 │  │               │                │        │                             │
 │  └ Moshi (opt.)  │── SSH 2222 ───▶│    sshd :2222 (key-only, Match block)│
 │     └ mosh (UDP) │── 60000-60010 ─▶│    mosh-server  -p 60000:60010       │
 │     └ gw forward │── 127.0.0.1 ──▶│    moshi-hook :24543 (loopback only) │
 │                  │      :24543     │        │                             │
 └──────────────────┘                │  herdr.service ── ONE server         │
                                     │   ├── workspace: aikami              │
 Termux (fallback)                    │   ├── pane: pi   (6 agents live)      │
   ssh -p 2222 ─────────────────────▶│   └── pane: claude                   │
   mosh    60000-60010 ─────────────▶│                                      │
                                     └──────────────────────────────────────┘
```

Three layers, three files, three flags. They are separable on purpose.

| Layer | Option | Adds |
| --- | --- | --- |
| **Shared infrastructure** | `mobileAgents.enable` | `sshd :2222` + `Match LocalPort` hardening, phone key, bounded mosh, `linger`, and the herdr `WantedBy` change |
| **Collie** (primary) | `mobileAgents.collie.enable` | `collie.service`, the private Tailscale Serve mapping, `COLLIE_TRUSTED_USER`, `COLLIE_PUBLIC_HOSTS` |
| **Moshi** (optional) | `mobileAgents.moshi.enable` | `moshi-hook.service`, the Chat View gateway, the `moshi-agent-hooks` installer |

| File | Role |
| --- | --- |
| `nixos/config/system/mobile-agents.nix` | shared sshd/mosh/linger **+ the Tailscale Serve mapping** |
| `nixos/config/home/collie.nix` | the Collie bridge as a Home Manager user service |
| `nixos/config/home/moshi-hook.nix` | the optional Moshi daemon |
| `nixos/config/home/herdr.nix` | `WantedBy` becomes `default.target` so the server starts at boot |
| `nixos/pkgs/moshi-hook.nix` | pinned `moshi-hook` + the bounded `mosh-server` wrapper |

### Disabling Moshi does not disable remote access

This is the property the whole option split exists to guarantee, so it is worth
stating as a test rather than a promise:

| | `mobileAgents.enable` | `collie.enable` | `moshi.enable` | phone can |
| --- | --- | --- | --- | --- |
| legion today | true | **true** | **false** | Collie PWA; SSH, Mosh, Termux after phone-key provisioning |
| Moshi back on | true | true | true | Collie PWA; Moshi, SSH, Mosh, Termux after phone-key provisioning |
| Collie off, Moshi on | true | false | true | Moshi, SSH, Mosh, Termux after phone-key provisioning |
| **clients off** | true | false | false | **SSH, Mosh, Termux** after phone-key provisioning |

The bottom row preserves the fallback infrastructure independently of the client
flags. SSH/Mosh access also requires `phoneAuthorizedKey` to be provisioned (§8)
and the tailnet policy to permit it (§4). On legion the key is currently `null`,
so this fallback is not yet usable.

### Why port 2222 and not 22

`server.nix` already runs Tailscale with `--ssh=true`. Tailscale SSH answers on
tailnet port 22 **before** the OS `sshd` sees the connection, authenticating
with a Tailscale identity and bypassing `authorized_keys` entirely.

A client that authenticates with a *key file* — Moshi, or Termux's plain `ssh`
— against a Tailscale-SSH-hijacked port 22 stalls ~60 s and then fails with a
misleading auth error even though the key is authorized and the host is
reachable. It also breaks the mosh bootstrap, because mosh needs a real `sshd` to
run `mosh-server new` through.

So 2222 is ordinary OpenSSH. **Port 22 and Tailscale SSH are not touched** —
they remain the recovery path, and nothing about Tailscale SSH is disabled.

Collie uses neither. It is a browser on the tailnet and reaches nothing but port
443.

### Why not headless

`mobileAgents.enable` is independent of `opts.headless`. The Legion stays a
three-monitor desktop: it still autologins into mango and still sleeps when
closed. Verified: `gs65` (which has not opted in) evaluates to a byte-identical
`system.build.toplevel` derivation before and after this change, with
`ports = [22]`, `mosh.enable = false`, `linger = null`, no `moshi-hook` unit,
no `collie` unit and no `tailscale-serve-collie` unit.

### What is genuinely given up

- **Wayland at cold boot.** With `WantedBy = default.target`, herdr starts
  before any graphical login, so it has no `WAYLAND_DISPLAY`. Agents started
  into it *before* you log in cannot use `wl-copy` or `xdg-open`; they behave
  normally once you are. Inherent to "reachable when nobody is at the desk".
- **Processes do not survive a reboot.** herdr restores workspaces, tabs, panes
  and their cwds — **not their commands** (`session.json` has no command field).
  After a reboot you get the layout back with bare shells. Interactive agents
  must be restarted by hand. The one automated exception is headless contract
  runs, via `herdr-contract-resume.service`, which only qualifies runs with a
  live heartbeat.

  Three different things, worth not conflating: *reconnection* persistence (yes
  — mosh + herdr; expected but unverified for Collie via the browser session),
  *workspace restore* (yes — layout and cwd), *agent command resumption* (no,
  except contract runs).

---

## 2. Safe activation

Use `nswitch-safe` from a **separate tmux session**, not from a herdr pane.
`nswitch-safe` refuses to run outside tmux/zellij/screen (it checks `TMUX`,
`ZELLIJ`, `STY` — it does not know about herdr), which is exactly the behaviour
you want here: a rebuild dropped by a lost connection must not also disturb the
agents you are trying to keep alive.

> We deliberately did **not** teach `nswitch-safe` about herdr. Adding
> `HERDR_ENV` to that check would make it accept a session whose lifetime is
> exactly what a rebuild endangers. tmux is installed on every host for this
> already (`server.nix`, `environment.systemPackages`).

```fish
# 1. From a desktop terminal, start a tmux session (NOT inside herdr)
tmux new -s rebuild

# 2. In tmux, arm the rollback and rebuild
nswitch-safe

# 3. The script tells you to verify from a SECOND connection.
#    Open the Collie PWA on the phone (or Termux on 2222) — do not trust
#    session 1. Confirm: herdr is attached, your agents are still there.
# 4. Only then:
nswitch-confirm
```

### What activation does and does not touch

- **herdr is not restarted.** `herdr.service`'s unit text is byte-identical
  before and after this change — verified by comparing the two generated unit
  store paths. Nothing in the Collie or Moshi modules is `Requires=`,
  `PartOf=` or `BindsTo=` herdr; both are `Wants=` after it.
- **No reboot.** Activation installs the unit, enables the Serve mapping, and
  starts `collie.service` in the (already running) user manager.
- **sshd is not restarted** by the Collie half; that was already true of the
  Moshi half.
- **`tailscale serve` is re-applied at boot** by the Nix-owned
  `tailscale-serve-collie.service`.

### Rollback

```fish
# 1. Back to the previous generation, which is what nswitch-safe would have
#    done for you:
sudo nixos-rebuild switch-generation -   # or nixos-rollback-to <n> + reboot

# 2. Or remove just the Collie half and keep the phone's SSH/Mosh path:
#    in nixos/hosts/legion/options.nix
#      mobileAgents.collie.enable = false;
#    rebuild. Port 2222, mosh, linger and boot-time herdr are untouched, so
#    configured fallback access is preserved. SSH/Mosh still requires the
#    phone key (§8) and tailnet access policy (§4).
```

Two things that must be undone by hand, because they are runtime state and not
in the flake:

```fish
# Removing tailscale-serve-collie.service runs its ExecStop to disable the
# node's HTTPS 443 mapping. If a stale mapping remains after rollback:
sudo tailscale serve --https=443 off

# Collie's own pairing credentials and VAPID keys are NOT in Git and NOT in
# the store. To forget a phone completely, revoke rather than delete:
collie devices list
collie devices revoke my-phone
rm -rf ~/.config/collie ~/.local/state/collie   # only if you want a clean slate
```

### After changing the herdr unit

Changing `herdr.nix` itself changes `herdr.service`'s text, and Home Manager
will restart it. That kills live agents. It is unchanged by this work, but the
rule stands: if you edit `herdr.nix`, do it with nothing important running.

---

## 3. Collie on the host

### What is installed, and who owns it

| Thing | Owner | How |
| --- | --- | --- |
| `collie` binary | Nix | pinned flake input `github:AltanS/collie/v1.15.3` |
| `collie.service` | Nix | `systemd.user.services.collie` (Home Manager) |
| `tailscale serve` mapping | Nix | `systemd.services.tailscale-serve-collie` |
| VAPID keypair | you, manually | `collie push-keys` → `~/.config/collie/.env` (0600) |
| pairing credentials | Collie | `~/.local/state/collie/` |
| the **version** | Nix | `collie update` refuses; see below |

The service runs `collie _exec-bridge`, which is the bridge in the foreground
and nothing else — no unit generation, no `tailscale serve`, no pidfile
ownership record. Upstream documents exactly this for a supervisor-managed
install.

> ### 🔴 Never run `collie start`, `collie restart`, `collie stop` or `collie uninstall` on this host
>
> Each of them writes `~/.config/systemd/user/collie.service` and/or runs
> `tailscale serve` — both of which Nix owns. Running one hands ownership to
> Collie and the next reboot hands it back, with a window in between where the
> phone has a front door nobody declared.
>
> **Restart with `systemctl --user restart collie`.**
> **Read state with `collie status` / `collie url` / `collie logs` / `collie doctor` /
> `collie pair` / `collie devices`.**

`collie update` needs no such discipline: a Nix store path is read-only and
outside `$HOME`, which is one of the shapes Collie reads as a *packaged*
install, so it declines and names the package manager. Verified on this
derivation — `collie update --check` reports
`✓ package updates come from your package manager`.

To move the version, edit the tag in `flake.nix` and `nix flake lock`. Note that
a collie bump changes `ExecStart`, so Home Manager will restart the bridge on
the next activation. That is intended, and it is harmless: the phone's
websocket reconnects on its own.

> The flake package at tag `v1.15.3` reports `1.15.0`. That is upstream's
> `packaging/nix/sources.json` running one release behind, not a packaging
> mistake — the package wraps the published, hashed release tarball rather than
> building from source. The manifest in that file is what proves the payload is
> genuine.

### The two gates

Collie's access control is two independent factors. Both are configured here.

**1. Identity — who is asking.** `COLLIE_TRUSTED_USER` is your tailnet login.
tailscaled puts it in the `Tailscale-User-Login` header on every request that
arrives through Serve, and Collie rejects a mismatch. It also rejects an
*absent* header: this gate fails closed, because an absent identity from a
tailnet node is not a loopback caller, it is some other device.

```fish
tailscale debug prefs | jq -r '.Config.UserProfile.LoginName'
# -> snorristrand@gmail.com   (lowercase, NO trailing dot)
```

If you get the trailing dot, every request is refused with `identity not
trusted` and the phone shows a blank page.

> `COLLIE_SKIP_SERVE` is deliberately **not** set. Collie disables the identity
> check entirely when it believes no Serve is in front — but Nix's
> `tailscale-serve-collie.service` *is* a Serve in front, whatever Collie believes.
> Leaving the flag unset buys fail-closed enforcement. The cost is cosmetic:
> `collie status` cannot see a Serve mapping it did not create, so its
> "serve config" section may read empty. It is not.

**2. Pairing — which device.** Until a device is paired, anything that passes
the identity gate can type into your panes. `collie pair` mints an 8-character
code valid for 10 minutes; the phone exchanges it for a token it stores, and the
host keeps only the hash. Pairing gates **writes** only — reads stay open to
anything that clears the identity and Host gates.

`config/home/collie.nix` rejects `trustedUser = null`, `trustedUser = ""`, and
`serveHosts = []` when Collie is enabled, so a generation with a missing gate
**does not build**. Collie itself treats an empty `COLLIE_TRUSTED_USER` as
disabling the identity gate; the assertion prevents that configuration.

### Check it

```fish
systemctl --user status collie.service
journalctl --user -u collie -n 50
collie status
collie doctor
```

A healthy log starts with the bridge listening on `127.0.0.1:8787`. If you see
`COLLIE_TRUSTED_USER is empty`, you are running a build that predates this
change. If you see `no non-loopback Host is allowed`, `serveHosts` is wrong.

---

## 4. Tailscale HTTPS

Three things have to be true. Two are in the flake; one is a one-time tailnet
setting.

**In the flake** — `nixos/hosts/legion/options.nix`:

```nix
mobileAgents.collie = {
  enable = true;
  trustedUser = "snorristrand@gmail.com";
  serveHosts = ["legion.tailf24d02.ts.net"];
};
```

`serveHosts` must match this machine's MagicDNS name: the node-level Serve
mapping uses that name automatically, and `serveHosts` supplies Collie's
Host-header allowlist. Change it if the tailnet name ever changes.

**In the tailnet**, once, in the admin console → DNS → **Enable HTTPS**. Serve
then obtains and renews a real Let's Encrypt certificate for
`legion.tailf24d02.ts.net` automatically. Note that `server.nix` sets
`--accept-dns=false`, which disables MagicDNS *resolution* on the host — it has
no effect on HTTPS certificates.

**Verify:**

```fish
tailscale serve status
# https://legion.tailf24d02.ts.net (tailnet only)
# |-- / proxy http://127.0.0.1:8787

curl -I https://legion.tailf24d02.ts.net/     # from a tailnet machine allowed TCP 443 by policy
```

### Private, not Funnel

The Nix-owned `tailscale-serve-collie.service` runs
`tailscale serve --bg --https=443 http://127.0.0.1:8787`. Serve is private to
the tailnet; this unit never enables Funnel.

### Preserving existing Serve configuration

The pinned NixOS `services.tailscale.serve.services.<name>` option creates
`svc:<name>` Tailscale Services. Its `set-config --all` command manages those
Services, not node hostname mappings. Collie therefore uses a dedicated
Nix-owned unit to configure HTTPS 443 on the node's MagicDNS hostname.

The unit owns the node's HTTPS 443 mapping; other ports and named Services
remain separate. **Check before enabling Collie on a host:**

```fish
tailscale serve status --json
```

If HTTPS 443 already has handlers, reconcile them before enabling Collie:
startup sets the root proxy, and stopping or removing the unit disables the
node's entire HTTPS 443 listener. Do not share that listener with unrelated
handlers. Restart the mapping with
`sudo systemctl restart tailscale-serve-collie`.

### Tailnet access policy

The tailnet is the trust boundary, and the ACL is a separate layer from
everything in this repository. A device not permitted by the ACL is refused
before the host firewall or Collie is consulted.

The effective policy must allow the operator's phone to reach the Legion on
**TCP 443** for Collie, plus TCP 2222 and UDP 60000-60010 for the SSH/Mosh
fallback. [Tailscale Serve remains subject to tailnet access rules](https://tailscale.com/kb/1312/serve).
An existing broader allow rule may already cover 443; Serve does not bypass
policy. `COLLIE_TRUSTED_USER` further narrows access inside Collie.

For example, merge these grants into the tailnet policy, replacing
`<legion-tailnet-ip>` with the node's actual Tailscale IP (from `tailscale ip -4`):

```json
{
  "grants": [
    {
      "src": ["snorristrand@gmail.com"],
      "dst": ["<legion-tailnet-ip>"],
      "ip": ["tcp:443"]
    },
    {
      "src": ["snorristrand@gmail.com"],
      "dst": ["<legion-tailnet-ip>"],
      "ip": ["tcp:2222", "udp:60000-60010"]
    }
  ]
}
```

During setup, check the effective policy for the phone's identity and this
node's TCP 443, then open the Serve URL from the phone. Check TCP 2222 and the
UDP range too if provisioning the fallback. These rules are managed in the
tailnet admin console, outside this repository.

Where a tailnet is shared with other people, `COLLIE_TRUSTED_USER` is the thing
that makes this safe, and it is not optional.

---

## 5. Pairing the phone

Pairing is an explicit manual step. No token is stored in this repo, and no
command below embeds one.

### On the host

```fish
HERDR_PLUGIN_CONFIG_DIR=~/.config/collie collie pair
```

The prefix is for consistency with §7, not because pairing needs it: pairing
state lives in `~/.local/state/collie/`, which the CLI and the bridge both
resolve the same way without it. It costs nothing and it removes one more
place for the two to disagree.

Prints an 8-character code valid for **10 minutes**, plus a QR code that opens
the pairing screen on the phone with the code already filled in.

### On the phone

1. Open **Tailscale** and turn it on. Everything below is unreachable without it.
2. Open `https://legion.tailf24d02.ts.net` in Chrome.
3. Go to **Settings → System → Paired devices**.
4. Enter the code (or scan the QR), give the device a label — `pixel-8` — and
   tap **Pair this device**.

The phone stores the token; the host keeps only its hash. **Pair inside the
installed PWA (§6), not in the browser tab** — the home-screen app keeps its own
storage, so a pairing made in a tab does not carry over.

No restart is needed: the running daemon applies pairings and revocations on the
next request.

### Revoking a device

```fish
collie devices list                    # labels, paired-at, last-seen
collie devices revoke pixel-8          # live, no restart
```

Revocation takes effect on the next request from that device.

### The Claude beacon hook (optional)

Collie identifies which herdr pane a Claude Code session belongs to using a
*beacon* written by an agent hook. Everything else — the dashboard, the terminal
mirror, typing, approvals, notifications — works without it. Install it only if
you want Claude sessions labelled per pane:

```fish
collie hooks install claude      # merges; leaves your own hooks alone
collie hooks status
collie hooks uninstall claude    # removes only what collie owns
```

> 🔴 `~/.claude/settings.json` on this host already carries a **herdr-managed
> SessionStart hook**. `collie hooks install` merges rather than replaces, which
> upstream is careful about, but "careful" is not the same as "safe to run on
> every activation". Nothing in this repo runs it. Do it by hand, once.

Collie has no hooks for pi or OpenCode; it identifies those panes from the
multiplexer directly.---

## 6. Install the PWA on Android

Collie is a web app. The browser adds it to your home screen without an app
store, giving it a standalone icon and a full-screen view.

1. Open `https://legion.tailf24d02.ts.net` in **Chrome**.
2. Open Collie's **Settings** and tap **Install** on the top card.
3. If the card is not there, open Chrome's menu (⋮) → **Add to home screen** →
   **Install**. Some Chrome builds label it **Install app**.

Installing only adds the icon and full-screen mode — Android already supports
Web Push in ordinary tabs. Pair **after** installing (§5), so the pairing lands
in the app's own storage.

Firefox and Samsung Internet use **Add to home screen** in their main menus.

---

## 7. Web Push (optional)

Disabled by default. Collie is fully usable without it; it is what makes an
approval request arrive while the phone is in a pocket.

```fish
HERDR_PLUGIN_CONFIG_DIR=~/.config/collie \
  collie push-keys mailto:you@example.com
systemctl --user restart collie
```

#### 🔴 `HERDR_PLUGIN_CONFIG_DIR` is load-bearing here

Without that prefix the keys land in the **wrong file** and push stays silently
disabled. Verified on this host, and the failure is quiet:

```
$ collie push-keys mailto:…
✓ wrote … to /home/sonny/.config/herdr/plugins/config/herdr.collie/.env (mode 600)
$ ls ~/.config/collie/          # still empty — that is where the bridge reads
```

The bridge is Nix-supervised and reads the path its unit declares,
`HERDR_PLUGIN_CONFIG_DIR=%h/.config/collie`. The **CLI** resolves the same
variable itself, and its precedence is (from `cli/context.ts`):

1. `HERDR_PLUGIN_CONFIG_DIR` from the environment, if set — **the only one that
   wins unconditionally**;
2. `herdr plugin config-dir herdr.collie`, *but only if a `.env` already exists
   there*;
3. `~/.config/collie`;
4. `~/.config/collie`, else herdr's answer anyway.

On a host with `herdr` on PATH and no `herdr.collie` plugin installed, step 2
misses (no `.env` there), step 3 misses, so it falls to the last line and
**herdr's answer wins**. And `herdr plugin config-dir herdr.collie` returns
`~/.config/herdr/plugins/config/herdr.collie` even when `herdr plugin list`
says *No plugins installed* — so it always looks like the right answer.

Hence the prefix: it pins the CLI to the same directory the service reads, and
it is the only one of the four paths that does not depend on what happens to be
on disk. Pin every `collie` verb that writes config for the same reason.

Confirm it worked — the log line is the only signal, because nothing else fails:

```fish
journalctl --user -u collie -n 5 --no-pager | grep '\[push\]'
# [push] enabled (0 saved subscription(s))
```

`disabled (no VAPID keys configured)` means the keys went somewhere else.

`push-keys` generates the keypair and writes `COLLIE_VAPID_PUBLIC` and
`COLLIE_VAPID_PRIVATE` into `~/.config/collie/.env` **at mode 600**. That file
is outside Git and outside the Nix store. Never put the private key in
`secrets.yaml`, never commit it, never copy it to the phone.

`--force` overwrites, and **replacing the keys invalidates every existing
subscription** — every device must re-subscribe before notifications work again.
Passing a subject on an existing configuration updates only the contact address
and preserves the keys.

Then on the phone: **Settings → Alerts**, and turn on **Needs input** (on by
default).

Test it:

```fish
HERDR_PLUGIN_CONFIG_DIR=~/.config/collie collie push-test
HERDR_PLUGIN_CONFIG_DIR=~/.config/collie collie push list   # subscribed endpoints
HERDR_PLUGIN_CONFIG_DIR=~/.config/collie collie push forget <substring>|--all
```

Notifications are derived by Collie **polling the multiplexer**, not from agent
hooks. The host observes a pane change and signs the push with the VAPID key
above. Collie does not use its own application cloud service, but delivery
requests are still sent through the browser's push service.

---

## 8. SSH / Mosh fallback (independent of both clients)

Fully independent: needs only port 2222, the phone key and Tailscale. Nothing
from Collie, nothing from moshi-hook, nothing from herdr beyond the terminal.

### The phone's public key

Generate it **on the phone**. Never create it on the host and never copy a host
private key down — the point is that the phone holds the only copy of its own
key and the host only ever sees the public half.

```fish
# in Termux, or Moshi → Settings → the key row → generate
ssh-keygen -t ed25519 -f ~/.ssh/phone -C phone
cat ~/.ssh/phone.pub
```

Put the `.pub` line in `nixos/hosts/legion/options.nix` (or the gitignored
`nixos/local.nix`):

```nix
mobileAgents.phoneAuthorizedKey = "ssh-ed25519 AAAA... phone";
```

Until you do, the build warns and port 2222 has **no key authorized**. That is
deliberate — a null key must not silently look like a working setup.

### Install Termux from the official source

Use the project's [installation guidance](https://github.com/termux/termux-app#installation).
The Play Store build is unmaintained and lags; get the APK from the official
GitHub releases instead:

```
https://github.com/termux/termux-app/releases
→ termux-app_*-arm64-v8a.apk
```

```fish
pkg update && pkg install -y openssh mosh git
pkg install -y nodejs-lts     # only if you want pi/claude/opencode on the phone too
```

### Connect

```fish
# bring Tailscale up in the Tailscale app first
ssh -p 2222 -i ~/.ssh/phone sonny@legion      # add a Host block so you can just `ssh legion`
```

Mosh must be told the port: the `moshPortRange` above bounds the server to
60000-60010, and mosh's default `60000-61000` search can land outside the tailnet
ACL. Point it at the exact range:

```fish
mosh --ssh="ssh -p 2222 -i ~/.ssh/phone" --port=60000:60010 legion
```

Verify the range is honoured server-side during a session:

```fish
ss -lunp | grep mosh-server      # a port inside 60000-60010
```

If Mosh fails over cellular specifically, some carriers shape UDP. Fall back to
plain SSH: you lose seamless roaming, not function.

### Attach herdr

```fish
herdr attach        # or: herdr  (inside the remote shell)
```

Reconnection — switching Wi-Fi ↔ cellular, backgrounding the app, locking the
screen — is mosh's job, and the agent processes keep running because they live
in the host's herdr server, not in your phone.

### Terminal keys on a phone

- **Termux** — the notification-bar **extra keys row** gives you `Ctrl`, `Alt`,
  `Esc` and `Tab`, which is the difference between a usable agent and a
  frustrating one. Turn it on in Termux → Settings → Keyboard.
- **Moshi** — has its own key row and a palette; see §9 for the fallback notes.

---

## 9. Moshi (optional)

Off on legion. Everything below is what you get back by setting
`mobileAgents.moshi.enable = true` and rebuilding; nothing below is required for
Collie or for the SSH fallback.

### What it adds

The moshi-hook daemon, an Inbox of agent events, approval prompts, Chat View, and
a diff / browser preview served on `127.0.0.1:24543`, reached from the phone by
forwarding that port over the same SSH connection on 2222. That is why the sshd
`Match` block for 2222 carries `AllowTcpForwarding yes`.

### Connection settings in the app

| Field | Value |
| --- | --- |
| Host | `<ts-ip>` or the MagicDNS name |
| Port | `2222` |
| Username | `sonny` |
| Key | the phone key from §8 |
| Auth | public key |
| Connection type | `SSH`, or `Mosh` with the range from §8 |
| Forward | `127.0.0.1:24543` |

`AllowAgentForwarding` is **off** on 2222, deliberately. It is unnecessary — the
host already holds the Git and model credentials in `authorized_keys` and the
sops environment — and it would put a phone-held key in reach of anything that
lands in a shell here. It also cannot work over mosh, which cannot carry SSH
channels.

### Pairing Moshi

```fish
# Nix owns the version: stop the daemon from checking for its own updates.
# `auto` would download a release and replace the running binary with
# something outside the store.
moshi-hook set auto-update off

# In the app: Settings → Hooks → copy the pairing token. Then:
read -rs MOSHI_TOKEN && echo
moshi-hook pair --token "$MOSHI_TOKEN"
unset MOSHI_TOKEN
```

The host secret lands in `~/.config/moshi/secrets.json` at mode 0600 — outside
Git and outside the store.

### Agent hooks (Moshi's own, distinct from Collie's)

```fish
moshi-agent-hooks        # backs up, then installs for agents actually present
moshi-hook doctor
```

This wires `claude`, `opencode` and `pi` only if their config directories exist,
after backing up every file it touches. Manual, and idempotent — no activation
path runs it, because `~/.claude/settings.json` already carries a herdr-managed
SessionStart hook and `~/.pi/agent/extensions/` is herdr-owned.

> **Moshi's hooks and Collie's hooks are different things.** Collie's Claude hook
> writes a *pane-identity beacon*; Moshi's hooks push *events to Moshi's
> servers*. Installing both is not a duplicate hook, but it is two independent
> event pipelines.

### Notifications, honestly

Reached by the phone, when Moshi works:

- small per-event summaries, up to 200 characters of your prompt as the body,
  up to 80 characters of the reply as the title, up to 256 characters of the
  command behind an approval request, plus project / session / agent / model /
  tool / context-window metadata;
- pairing, usage sync, approval decisions and WebSocket control traffic.

Stays between host and phone: full transcripts (streamed through the SSH-forwarded
loopback gateway), diff payloads, your files, and all terminal traffic.

So Moshi is **not** cloud-free and this doc will not pretend otherwise. Those
controls exist if you want them:

```fish
moshi-hook set usage-collection off        # stop rate-limit polling + snapshots
moshi-hook set always-on-discovery off     # stop idle dev-server scans
moshi-hook set suppress-nested-agent-push on
moshi-hook set scan-ports 3000,5173,8000-8010
```

If that trade is wrong for a given agent, leave its hooks uninstalled — the
terminal still works over SSH/Mosh.

### Chat View: UNVERIFIED on Android

Upstream's Chat View page is written entirely around iOS (Live Activity, Apple
Watch, Command-Enter, iCloud sync). Android has the app and the hooks, but
Chat View parity is not documented. Confirm in-app before relying on it; the
plain terminal is the supported path either way.

### Android battery and background

Check these first if reconnect or notifications misbehave — and they apply to
**Tailscale** and **Chrome** for Collie just as much as to Moshi:

- **Tailscale** — Settings → Apps → Tailscale → Battery → *Unrestricted*.
  Without this Android kills the tunnel and the phone cannot reach the host at
  all. This is the single most common failure.
- **Chrome** — Background activity: *Allowed*.
- **Notifications for Chrome** — Settings → Apps → Chrome → Notifications.
  Web Push needs this; without it pushes arrive silently.
- **Private DNS / VPN stacking** — Android's per-app VPN settings can exclude
  Tailscale and send traffic out unencrypted. Leave Tailscale exempt.

---

## 10. Notifications: one, not two

With both clients enabled the phone receives **two** notifications for the same
agent waiting for input:

- moshi-hook posts agent events to Moshi's servers;
- Collie polls the multiplexer and pushes through this host's own VAPID keys.

They are separate pipelines and there is no upstream way to merge them. That is
why `moshi.enable = false` on legion rather than "leave it on and ignore the
spams".

If you run both deliberately, turn notifications off in whichever one you are
not using, rather than turning the host's reporting off.

Neither client's *hooks* cause duplicate notifications: Collie's Claude hook
only writes a pane-identity beacon and Collie derives every notification from
polling.

---

## 11. Troubleshooting

### The phone shows a blank page

Almost always one of two gates, both of which refuse rather than half-work.

```fish
journalctl --user -u collie -n 50 | grep -iE "warning|refus|not allowed|identity"
```

| Log line | Cause | Fix |
| --- | --- | --- |
| `host not allowed` | `serveHosts` is empty or stale | `tailscale status --json \| jq -r '.Self.DNSName \| rtrimstr(".")'` and put it in `serveHosts` |
| `identity not trusted` | `trustedUser` has a trailing dot, or is a different login | `tailscale debug prefs \| jq -r '.Config.UserProfile.LoginName'` |
| `identity required` | the request arrived without a Serve header | you are reaching `127.0.0.1:8787` directly, or `tailscale serve` is not running — check `tailscale serve status` |
| `no non-loopback Host is allowed` | `COLLIE_PUBLIC_HOSTS` empty | `serveHosts` again |
| `COLLIE_TRUSTED_USER is empty` | running a generation that predates this change | rebuild |

### `collie status` says the serve config is empty

Expected, and explained in §3. `collie status` reports what *it* would publish;
Nix publishes this one. `tailscale serve status` is the truthful command here.

### The phone can load Collie but cannot type into anything

Unpaired. Writes need a paired device even when the identity gate passes:

```fish
collie devices list
```

### `collie start` / `restart` was run by accident

Nix owns the unit and the Serve mapping. The next activation takes both back:

```fish
systemctl --user stop collie          # do not run `collie stop`, it deletes the unit
# rebuild; the unit and the mapping return to Nix's versions
```

> ### 🔴 Ignore anything that tells you to reach Collie through a herdr plugin
>
> `collie push-keys` prints `herdr plugin action invoke restart --plugin
> herdr.collie`, and `collie pair` and `collie start` print the same shape of
> instruction. **On this host there is no such plugin** — `herdr plugin list`
> says *No plugins installed*, because Collie is supervised by the Nix unit, not
> by herdr. Running the printed command either fails or, worse, stands up a
> second Collie beside the one systemd already owns.
>
> Every one of those becomes `systemctl --user restart collie`.

### Push stays disabled after `collie push-keys`

```
[push] disabled (no VAPID keys configured)
```

The keys went to a file the bridge does not read. Check *both* locations:

```fish
ls -la ~/.config/collie/.env                                  # the bridge reads this
ls -la ~/.config/herdr/plugins/config/herdr.collie/.env 2>/dev/null   # the CLI may write this
```

A file in the second place with an empty first place is §7's config-dir
redirect, not a broken keypair. Move it:

```fish
mv ~/.config/herdr/plugins/config/herdr.collie/.env ~/.config/collie/.env
chmod 600 ~/.config/collie/.env
rmdir ~/.config/herdr/plugins/config/herdr.collie
systemctl --user restart collie
```

Then `journalctl --user -u collie -n 5 --no-pager | grep '\[push\]'` must say
`enabled`. Push reads its keys **at start only**, so a restart is required
after moving them — no other change is.

### `systemd` did not restart Collie after an upgrade

Check that Home Manager wrote the unit:

```fish
systemctl --user cat collie.service | grep ExecStart
```

If it names an old store path, the activation did not run. If it names the new
one and the process is old, `systemctl --user restart collie`.

### Collie cannot see any panes

It is pointed at the wrong multiplexer or socket:

```fish
systemctl --user show collie -p Environment | tr ' ' '\n' | grep -E 'HERDR_SOCKET_PATH|COLLIE_MUX'
herdr status server                    # must say: status: running
```

### `sshd.conf-final` fails with exit code 137

Pre-existing trap, documented so it is not re-diagnosed: `extraConfig` in
`mobile-agents.nix` is rendered through an **unquoted** heredoc, so a backtick,
`$` or backslash in that block is executed by `/bin/sh` while the config is
built. A stray backtick makes the build run `yes`, which never returns, and the
OOM killer surfaces it as `Cannot build '…-sshd.conf-final.drv' … exit code 137`
— pointing at a config that has nothing to do with sshd. Plain prose only.

### `mosh-server` not found / Mosh connects then dies

- The bounded wrapper lives in `/run/current-system/sw/bin` (`programs.mosh`), not
  on the stable per-user symlink. If mosh was bumped, restart whatever depends
  on it and reconnect.
- Over cellular, test plain SSH first. UDP shaping by the carrier is the usual
  cause and there is no fix on this side.

### Gateway forwarding / Chat View fails, terminal is fine (Moshi only)

Port 2222's `Match` block carries `AllowTcpForwarding yes`. Verify it survived:

```fish
sshd -T -C user=sonny,host=legion,addr=<ts-ip>,lport=2222 | grep -i allowtcpforwarding
```

### herdr will not start at boot

```fish
loginctl show-user sonny -p Linger        # must be Linger=yes
systemctl --user is-enabled herdr.service
systemctl --user status herdr.service
```

### Secrets missing after a cold boot

`herdr.service` and `collie.service` both run `After=`/`Wants=`
`sops-import-environment.service`. If the sops age key is missing, agents start
without credentials:

```fish
systemctl --user status sops-import-environment.service
```

### Duplicate notifications

See §10. It is two enabled clients, not a bug, and the fix is a flag.

### Reconnect launched a second agent

Reconnection must never start a process. If it seems to, the terminal client
started one itself (a bare `pi` in the pane) rather than attaching. Check
`herdr agent list` for two entries in one pane and delete the duplicate.

### Something is in the way after a rebuild

`nswitch-safe` arms a dead-man timer. If the rebuild finished but you did not
run `nswitch-confirm`, the host reverts on its own:

```fish
nswitch-confirm
```

---

## 12. Migration from the Moshi-only setup

Nothing here is destructive, and the order is chosen so the phone is never
without a way in.

**Before:** PR #1 configured port 2222, bounded mosh and `linger`; herdr starts
at boot. The phone key is still `null` in the checked-in configuration. Provision
`phoneAuthorizedKey` using §8, rebuild, verify the tailnet policy (§4), and test
SSH/Mosh from the phone before treating the fallback as live or disabling Moshi.

**The change** is: add Collie, turn Moshi off.

```nix
# nixos/hosts/legion/options.nix
mobileAgents = {
  enable = true;
  collie = {
    enable = true;
    trustedUser = "snorristrand@gmail.com";        # tailscale debug prefs | jq -r '.Config.UserProfile.LoginName'
    serveHosts = ["legion.tailf24d02.ts.net"];        # tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")'
  };
  moshi = {
    enable = false;
  };
};
```

**Then**, in order:

1. Enable HTTPS for the tailnet (admin console → DNS → Enable HTTPS), once,
   and verify the effective TCP 443 allow rule for the phone → Legion (§4).
2. Add the `collie` flake input and rebuild (`nix flake lock`, then
   `nswitch-safe` from tmux). **herdr is not restarted**; its unit text is
   unchanged.
3. `systemctl --user status collie` and `curl -I https://legion.tailf24d02.ts.net/`.
4. Install the PWA on the phone (§6).
5. `collie pair` and pair inside the app (§5).
6. Optional: `collie push-keys`, restart, enable Alerts (§7).
7. Optional: `collie hooks install claude` (§5).
8. Only now uninstall Moshi from the phone if you are done with it. The host
   side is already gone — `moshi-hook` is no longer on `PATH` and no unit exists.

**Roll back at any point:** `mobileAgents.collie.enable = false` and rebuild.
The configured SSH/Mosh fallback is preserved; access depends on the phone key
and tailnet policy verified above.

---

## 13. Acceptance tests

Two columns. Checked **build-level** items record prior validation, with focused
checks of the updated assertion and Serve unit noted below. **Device-level** needs
the phone and a real activation, and nothing disruptive was run against live
agents.

### Build-level — historical results and focused rechecks

- [x] `alejandra --check` passes on every changed file. (`config/home/default.nix`
      has a pre-existing deviation that master also has; left alone rather than
      reformatted, to keep the diff reviewable.)
- [x] `nix eval` clean for `legion`: `sshd.ports [22 2222]`, `openFirewall false`,
      `allowedTCPPorts` unchanged, `linger true`, bounded `mosh-server`
      wrapper, `WARNING` emitted while `phoneAuthorizedKey` is null.
- [x] `nix eval` clean for `gs65`, and `gs65` + `gs65-fast` produce a
      **byte-identical `system.build.toplevel` derivation** before and after this
      change — no option leakage to a host that did not opt in. `legion` and
      `legion-fast` differ, as intended.
- [x] The `collie` flake package **builds** (including upstream's `doInstallCheck`,
      which runs `collie --version` on the patchedelf'd binary) and installs
      upstream's `$out/lib/collie` + `$out/bin/collie` symlink layout, which is
      what `bridge/root.ts` resolves its install root through.
- [x] The generated `collie.service` contains `COLLIE_TRUSTED_USER=<email>`,
      `COLLIE_PUBLIC_HOSTS=<host>`, `HERDR_SOCKET_PATH=%h/.config/herdr/herdr.sock`,
      `COLLIE_MUX=herdr`, `ExecStart=… _exec-bridge`, `EnvironmentFile=-…`,
      `NoNewPrivileges`, `PrivateTmp`, `StartLimitIntervalSec=0`,
      `After/Wants = herdr.service sops-import-environment.service`, and **no**
      `Requires`/`PartOf`/`BindsTo` on herdr.
- [x] `collie update --check` on this derivation reports
      `updates come from your package manager` — the packaged-install
      classification works, so the updater cannot replace the Nix-owned binary.
- [x] Focused NixOS module evaluation: the generated `tailscale-serve-collie.service` runs
      `tailscale serve --bg --https=443 http://127.0.0.1:8787` and stops with
      `tailscale serve --https=443 off`; no `svc:collie` is configured. Both
      enable flags and a custom Collie port were checked; activation was not.
- [x] `herdr.service`'s generated unit is **byte-identical** before and after this
      change (same store path) — activation will not restart it, and no live
      agent is interrupted.
- [x] `home.packages` still contains exactly **one** herdr, plus `collie-1.15.0`;
      `environment.systemPackages` count is unchanged (208 → 208).
- [x] `sshd -T -C …lport=…` against the config Nix actually built: port 22 keeps
      `PasswordAuthentication yes` / `KbdInteractiveAuthentication yes` /
      `PermitRootLogin prohibit-password`, while 2222 resolves to `no` / `no` /
      `no` with `AllowTcpForwarding yes` and `AllowAgentForwarding no`.
- [x] `tailscale serve status` reported `No serve config` (and `--json` `{}`)
      before the change, so nothing is being overwritten.
- [x] Focused assertion evaluation: `trustedUser = null`, `trustedUser = ""`,
      and `serveHosts = []` each produce a false assertion when enabled. A valid
      identity and host pass; disabling Collie still permits null/empty values.
- [x] The Moshi-off path and the Moshi-on path both evaluate; with
      `moshi.enable = true` the unit reappears at
      `MOSHI_HOOK_GATEWAY_LISTEN=127.0.0.1:24543` from
      `opts.mobileAgents.moshi.gatewayPort`.
- [x] `gs65` still evaluates with zero warnings.

### Device-level — manual, after a real activation

Each line says what "working" looks like. None has been run.

- [ ] **Collie loads on the phone** at `https://legion.tailf24d02.ts.net`, over
      the tailnet, with Tailscale on. The dashboard lists the herdr workspaces
      and panes that exist right now.
- [ ] **Private, not public.** From a machine *not* on the tailnet, the URL does
      not resolve and does not connect. From a phone on the tailnet, it does.
- [ ] **Tailnet policy.** Confirm the effective rule permits the phone → Legion
      on TCP 443, then load the Serve URL. A source denied TCP 443 by policy
      cannot connect. Check TCP 2222 and UDP 60000-60010 for the fallback too.
- [ ] **Identity gate.** From a tailnet device permitted TCP 443 by policy but
      belonging to another user (or a tagged node), confirm Collie refuses the
      request. This checks `COLLIE_TRUSTED_USER` independently of the ACL.
- [ ] **Pairing.** Before pairing, typing into a pane from the phone is refused
      (`device not paired`). After pairing it works.
- [ ] **pi.** Start `pi` in a herdr pane from the phone; the terminal mirror
      updates; a prompt sent from the phone reaches the running agent.
- [ ] **Claude Code.** Same, in a pane running Claude Code. If the beacon hook is
      installed, the pane is labelled with the session; without it, the pane is
      still usable, just less well labelled.
- [ ] **OpenCode.** Same, in a pane running OpenCode.
- [ ] **No agent is duplicated by attaching.** Note `herdr agent list` PIDs on
      the desktop, browse from the phone, confirm the count is unchanged.
- [ ] **Reconnect.** With a session open, switch Wi-Fi → cellular → Wi-Fi, and
      separately lock and unlock the screen, and separately background Chrome
      for a minute. The page reconnects and the same agent process answers.
      (For a *shell* reconnect this is mosh's job — see §8 — not Collie's.)
- [ ] **Desktop logout does not terminate the server.** Log out on the desktop;
      the phone still reaches every pane with the same PIDs.
- [ ] **Cold boot, no login.** Reboot with nothing to save. After boot,
      *without logging in*, from the phone:
      ```fish
      loginctl show-user sonny -p Linger          # Linger=yes
      systemctl --user is-active herdr.service    # active
      systemctl --user is-active collie.service   # active
      ```
      Confirm Collie shows the panes. Note the Wayland caveat from §1.
- [ ] **Web Push, if enabled.** `collie push-test` produces a notification on the
      phone. Then a real agent needing input produces exactly **one** push
      within ~30 s of `COLLIE_NOTIFY_DELAY_MS`.
- [ ] **Exactly one notification per event.** With Moshi off, an agent waiting
      for input produces one notification, not two.
- [ ] **Device revocation.** `collie devices revoke <label>`, then try to type
      from that phone: refused, without restarting the daemon.
- [ ] **Disabling Collie preserves configured fallback access.** Run only after
      `phoneAuthorizedKey` is configured and SSH/Mosh access is verified (§8);
      otherwise this check is blocked.
      `systemctl --user stop collie`, then attach over SSH 2222 from Termux and
      run `pi`: the terminal, herdr and the agents are all fine; only the web UI
      is gone.
- [ ] **Moshi still works when re-enabled** (§9), or is confirmed unwanted.

### Feature status

The table distinguishes prior host validation from the updated mapping and
physical Android checks that remain unverified.

| Feature | Status |
| --- | --- |
| Collie package builds, pinned, updater-declining | **verified** |
| Nix-owned unit + private Tailscale Serve mapping | **verified (focused module eval); activation UNVERIFIED** |
| `COLLIE_TRUSTED_USER` and `COLLIE_PUBLIC_HOSTS` emitted | **verified (unit text)** |
| herdr untouched by activation | **verified (identical unit)** |
| No impact on `gs65` | **verified (identical derivation)** |
| Collie PWA on Android | **UNVERIFIED on device** |
| Pairing flow end to end | **UNVERIFIED on device** |
| pi / Claude Code / OpenCode from the phone | **UNVERIFIED on device** |
| Reconnect persistence (WebSocket) | **UNVERIFIED on device** |
| Device revocation, live | **UNVERIFIED on device** (upstream-documented) |
| Web Push delivery on Android | **UNVERIFIED on device** |
| SSH on 2222 with the phone key | **UNVERIFIED on device** (`sshd -T` verified) |
| Mosh over the tailnet, range honoured | **UNVERIFIED on device** (server binding verified live) |
| Moshi Chat View on Android | **UNVERIFIED — treat as iOS-first** |

---

## 14. What was and was not executed

**Executed (build validation):**

- `alejandra --check` on all changed files.
- `nix flake lock`, and a full build of the pinned `collie` package including
  upstream's `doInstallCheck`.
- `nix eval` of `legion`, `legion-fast`, `gs65` and `gs65-fast`, old and new,
  comparing `system.build.toplevel.drvPath`.
- Reading the generated `collie.service`, the original named-Service JSON
  and `ExecStart` of `tailscale-serve.service` (superseded by the node-level
  `tailscale-serve-collie.service`; its activation remains unverified),
  `home.packages`, `environment.systemPackages`, the firewall, DNS and
  Tailscale flag lists.
- `sshd -T -C …lport=22` and `…lport=2222` against the sshd config Nix actually
  built, with only the `HostKey` lines redirected at throwaway keys in `/tmp`.
- `collie update --check`, `collie version`, `collie help`, `collie status` and
  `collie url` against the built package, with `HOME` pointed at a throwaway
  directory so nothing touched real state.
- Both fail-closed assertions, and both `moshi.enable` values.

**Not executed — deliberately, and each is a manual step in this document:**

- `nixos-rebuild` / `switch-to-configuration` of any kind. **No generation was
  activated.**
- Any reboot.
- Any restart, stop or reload of `herdr`, `sshd`, `tailscaled`, `moshi-hook` or
  anything else live. **No agent was interrupted.**
- `tailscale serve` — the mapping was evaluated, never applied.
- `collie pair`, `collie push-keys`, `collie push-test`, `collie hooks install`,
  `collie devices revoke`, `moshi-agent-hooks`.
- Every device test in §13.
- Editing `~/.claude/settings.json`, `~/.pi/agent/extensions/`, or any file a
  herdr-managed hook owns.

**Known limitation, carried over from PR #1:** `phoneAuthorizedKey` is still
`null`, so port 2222 has no key authorized and the build warns. Collie does not
need it; the SSH/Mosh fallback does.

**Out of scope for this change:** crew / multi-machine, speech-to-text,
attachments, themes and quick replies, `config.toml`, anything involving a
reverse proxy, and any Tailnet ACL edit. ACL grants are documented in §4 for you
to apply.