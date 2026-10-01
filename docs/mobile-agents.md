# Mobile Agents — reaching herdr from Android

Reach the Legion from a phone over Tailscale and drive the **same** persistent
herdr workspaces and pi / Claude Code / OpenCode agents you use at the desk.
Same server, same panes, same agent processes. The phone is a second client, not
a second stack.

Moshi (Android, Play Store) is the client. Termux is documented at the end as a
fully independent fallback that needs nothing from this setup beyond port 2222.

---

## 1. Architecture

```
  Android phone                      Legion (daily-driver desktop)
 ┌──────────────────┐                ┌──────────────────────────────────────┐
 │ Moshi            │                │  tailscale0 ── trusted by firewall    │
 │  ├ biometric key │──── SSH 2222 ──▶│    sshd :2222  key-only (Match block) │
 │  ├ mosh (UDP)    │──── 60000-10 ──▶│    mosh-server  -p 60000:60010       │
 │  └ gateway fwd   │──── 127.0.0.1 ─▶│    moshi-hook :24543 (loopback only) │
 └──────────────────┘      :24543    │        │                             │
                                       │        └── reads $HERDR_ENV         │
                                       │  herdr.service ── ONE server         │
                                       │   ├── workspace: aikami             │
                                       │   ├── pane: pi   (6 agents live)     │
                                       │   └── pane: claude                  │
                                       └──────────────────────────────────────┘
```

Three moving parts, three files, one flag.

| File | Adds |
| --- | --- |
| `nixos/config/system/mobile-agents.nix` | sshd `:2222` + `Match LocalPort` hardening, phone key, `linger`, bounded mosh |
| `nixos/config/home/moshi-hook.nix` | `moshi-hook` package on PATH, `moshi-hook.service`, `moshi-agent-hooks` installer |
| `nixos/config/home/herdr.nix` | `WantedBy` becomes `default.target` and `After` omits `graphical-session.target` when mobile is on |

Supporting changes: `nixos/pkgs/moshi-hook.nix` (pinned package + the bounded
`mosh-server`), `nixos/options.nix` (the `mobileAgents` block),
`nixos/hosts/legion/options.nix` (`enable = true`),
`config/system/default.nix` + `config/home/default.nix` (imports).

### Why port 2222 and not 22

`server.nix` already runs Tailscale with `--ssh=true`. Tailscale SSH answers on
tailnet port 22 **before** the OS `sshd` sees the connection, authenticating
with a Tailscale identity and bypassing `authorized_keys` entirely.

Moshi authenticates with a key file and expects the host to check it. Against a
Tailscale-SSH hijacked port 22 it stalls ~60 s then reports a misleading auth
error even though the key is authorized and the host is reachable. It also
breaks the mosh bootstrap, because mosh needs a real `sshd` to run
`moshi-server new` through.

So 2222 is ordinary OpenSSH. **Port 22 and Tailscale SSH are not touched** —
they remain the recovery path, and nothing about Tailscale SSH is disabled.

### Why not headless

`mobileAgents.enable` is independent of `opts.headless`. The Legion stays a
three-monitor desktop: it still autologins into mango and still sleeps when
closed. Verified: `gs65` (which has not opted in) evaluates to
`ports = [22]`, `moshEnable = false`, `linger = null`, and no `moshi-hook`
unit at all.

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
  — mosh + herdr), *workspace restore* (yes — layout and cwd), *agent command
  resumption* (no, except contract runs).

---

## 2. Safe activation

Use `nswitch-safe` from a **separate tmux session**, not from a herdr pane.
`nswitch-safe` refuses to run outside tmux/zellij/screen (it checks `TMUX`,
`ZELLIJ`, `STY` — it does not know about herdr), which is exactly the
behaviour you want here: a rebuild dropped by a lost connection must not also
disturb the agents you are trying to keep alive.

> We deliberately did **not** teach `nswitch-safe` about herdr. Adding
> `HERDR_ENV` to that check would make it accept a session whose lifetime is
> exactly what a rebuild endangers. tmux is installed on every host for this
> already (`server.nix`, `environment.systemPackages`).

```fish
# 1. From a desktop terminal, start a tmux session (NOT inside herdr)
tmux new -s rebuild

# 2. In tmux, arm the rollback and rebuild
nswitch-safe              # legion; ROLLBACK_TIMEOUT defaults to 20min

# 3. The script tells you to verify from a SECOND connection.
#    Open Moshi (or Termux) and connect on 2222 — do not trust session 1.
#    Confirm: herdr is attached, your agents are still there.

# 4. Only then:
nswitch-confirm           # disarm; this generation is now permanent
```

### Rollback

Every change is behind one flag, so rollback is a one-line revert plus a
rebuild:

```nix
# nixos/hosts/legion/options.nix
mobileAgents = { enable = false; };   # was: true
```

That reverts **all** of it: port 2222 closes, the `Match` block goes, `linger`
returns to unmanaged, mosh disappears, `moshi-hook` stops, and herdr's
`WantedBy` goes back to `graphical-session.target`.

To roll back a *running* system without a rebuild:

```fish
# Disabling moshi-hook leaves ordinary herdr access fully working.
systemctl --user stop moshi-hook.service
systemctl --user disable moshi-hook.service

# Stopping herdr DOES kill running agents. Only if you must:
systemctl --user stop herdr.service
```

### After changing the herdr unit

If you change `herdr.nix` while agents are running, home-manager will restart
the service on activation, and **that kills every agent in it**. Finish the work
first:

```fish
herdr agent list            # confirm nothing is mid-turn
```

Wait for the runs you care about, then activate. If you want to apply the change
without the restart risk, `loginctl` user services can be reloaded first:

```fish
systemctl --user daemon-reload
systemctl --user cat herdr.service   # inspect the new unit without applying it
```

The unit text deliberately references `/etc/profiles/per-user/%u/bin/herdr`,
not a store path, so ordinary `flake update` runs that change herdr's hash do
**not** alter the unit and do **not** trigger a restart.

---

## 3. The Android public key

Generate the key **on the phone**. Never generate it on the host and never copy
a host private key down — the point is that the phone holds the only copy of its
own key and the host only ever sees the public half.

**Option A — in Moshi.** Generate a key in the connection form (biometric
protected, stored in the Android Keystore), then tap the key row and copy the
public key.

**Option B — in Termux:**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/moshi_phone -C moshi-phone
cat ~/.ssh/moshi_phone.pub
```

Then set it in `nixos/options.nix`:

```nix
phoneAuthorizedKey = "ssh-ed25519 AAAA… moshi-phone";
```

Or keep it out of Git entirely, in the gitignored `nixos/local.nix`:

```nix
{ mobileAgents.phoneAuthorizedKey = "ssh-ed25519 AAAA… moshi-phone"; }
```

Until this is set the build emits a warning and port 2222 has **no** key
authorized — deliberate, so a fresh clone still evaluates.

Revoke the phone by removing that one line. Your desktop/GitHub key is a
separate entry and is unaffected.

---

## 4. Moshi connection settings

Create a saved host:

| Field | Value |
| --- | --- |
| Name | `legion` |
| Host | `tailscale ip -4` output — the `100.x.y.z` address |
| Port | `2222` |
| Username | `sonny` |
| Authentication | key — import the phone-generated private key |
| Connection type | **Mosh** (or Auto, which tries Mosh first) |
| Forward SSH Agent | **off** — see below |

Mosh options (visible when Connection type = Mosh):

| Field | Value |
| --- | --- |
| UDP port range | `60000-60010` |
| Mosh path | leave blank — `/run/current-system/sw/bin` is on the non-interactive SSH PATH |

**Use the Tailscale IP first.** MagicDNS names are optional on Android: the
Tailscale app resolves them, but an IP removes a whole class of failure where
the name does not resolve and the app gives up silently. `--accept-dns=false`
is preserved on the host and dnscrypt-proxy still owns DNS there — do not change
either.

Never use the LAN IP, the public IP, or a Tailscale web-SSH proxy URL.

### Agent forwarding is off, on purpose

Moshi can forward its key as an SSH agent, but:

- it **does not work over Mosh or Auto** — it is an SSH channel feature, and
  mosh cannot carry SSH channels;
- it is unnecessary — the host already has the Git and model credentials the
  agents need, in `authorized_keys` and the sops-imported environment;
- the server refuses it anyway (`AllowAgentForwarding no` on 2222), so a
  compromised phone session cannot reach a signing key.

Agents use **host-side** credentials. `git push` from a phone-attached pane
works because the host can already push.

---

## 5. Tailscale enrollment and policy

### On the phone

1. Install Tailscale from Google Play, sign in to the **same tailnet**.
2. Confirm the Legion appears and is online.

### On the host

Already enrolled by `server.nix`. Nothing to do.

```fish
tailscale status              # node is up
tailscale ip -4               # the 100.x.y.z address for the Moshi Host field
tailscale ping <phone>
```

### Tailnet access policy

Host firewalling is **not** a substitute for tailnet policy. `tailscale0` being
in `networking.firewall.trustedInterfaces` means *once a packet reaches this
host over the tunnel*, the host accepts it. Whether it reaches the host at all
is decided by the Tailscale ACL, upstream of that.

Add these grants in the Tailscale admin console → Access Controls:

```hujson
{
  "grants": [
    {
      "src":    ["tag:phone"],
      "dst":    ["tag:legion"],
      "ip":     ["tcp:2222", "udp:60000-60010"],
    },
  ],
}
```

Two separate requirements, often confused:

- **`tcp:2222`** — the SSH (and mosh bootstrap) connection.
- **`udp:60000-60010`** — the mosh session itself. Missing this gives you a
  successful SSH that then fails to become a mosh session.

The existing **Tailscale SSH recovery path on port 22** is separate: keep its
network access rule and its top-level `"ssh"` rule. Tailscale SSH authorization
is configured in that [top-level section](https://tailscale.com/kb/1337/policy-syntax#ssh),
not as an `"app"` capability in the network grant above.

Replace the tags with whatever identifies your devices today — literal IPs or
existing groups are fine. Confirm with:

```fish
tailscale ping <phone>        # tunnel is up
# then from the phone, after connecting: the session must survive a Wi-Fi→cellular switch
```

**Out of scope, deliberately not configured:** no Funnel, no public tunnels, no
router port-forwarding, no exit-node changes, no subnet routers. Everything
rides the existing tailnet.

---

## 6. Pairing

Pairing is an explicit manual step. No token is stored in this repo, and no
command below embeds one.

### First, on the host

```fish
# Nix owns the version: stop the daemon from checking for its own updates.
moshi-hook set auto-update off

# 🔴 Nix owns the version. `auto` would download a release and replace the
# running binary with something outside the store.
```

### Then, in the app

Open Moshi → **Settings → Hooks** → copy the pairing token.

### Then, on the host

```fish
# Type or paste the token at the prompt. Prefer this over putting it in your
# shell history or a command line other processes can read:
read -rs MOSHI_TOKEN && echo
moshi-hook pair --token "$MOSHI_TOKEN"
unset MOSHI_TOKEN
```

The host secret lands in `~/.config/moshi/secrets.json` at mode `0600` — outside
Git and outside the Nix store. Never add it to `secrets.yaml`, never commit it.

### Install the agent hooks

Only after pairing, and only by hand — **no activation path runs this**:

```fish
moshi-agent-hooks        # backs up, then installs for agents actually present
```

The helper wires only `claude`, `opencode` and `pi`, and only if their config
directories exist. It backs up every file it is about to touch to
`~/.local/state/moshi/hook-backups/<UTC timestamp>/` (mode `0700`) and restores
that backup if the install fails partway. It is safe to re-run.

Why it is not automatic: `moshi-hook install` writes into
`~/.claude/settings.json`, which on this host **already contains a herdr-managed
`SessionStart` hook**, and into `~/.pi/agent/extensions/`, which herdr owns and
rewrites on reinstall. A silent activation-time edit to files another unit
manages is how you get a duplicated notification path or a mysteriously reset
hook. Upstream merges rather than overwrites, and the helper only adds a backup
and a rollback around it.

To undo everything Moshi added:

```fish
moshi-hook uninstall
```

### Verify

```fish
moshi-hook doctor
```

Expected: daemon ✓, gateway ✓, `herdr ✓` at
`/etc/profiles/per-user/sonny/bin/herdr`, pairing ✓, and the installed agents ✓.
Anything `✗` prints numbered fixes.

Currently unpaired and unhooked on this host (by design — see §11).

---

## 7. Android notifications and battery

Push is what makes the phone useful: an approval request or a finished build
arriving while the phone is in a pocket.

Reached by the phone, when Moshi works:

- **Inbox event summaries** — one small record per event
  (`approval_required`, `task_complete`, `session_started`, `session_ended`,
  `tool_running`, `tool_finished`).
- **Up to 200 characters of your prompt**, as the event body.
- **Up to 80 characters of the assistant's reply**, as the event title.
- **Up to 256 characters of the command or question** behind an approval
  request, so you can decide from the notification.
- **Metadata**: project name, session ID, agent, model, tool name, terminal
  identifiers, account ID, context-window percentage.
- Pairing, usage sync, approval decisions, WebSocket control traffic.

Stays between your host and your phone:

- **Full agent transcripts.** Chat View streams them from the host through the
  SSH-forwarded loopback gateway; they never pass through Moshi's backend.
- **Diff payloads**, read locally on the host.
- **Your source files** — file contents are never part of the cloud payload.
- **Terminal traffic**, which rides your own Tailscale tunnel.

So: notifications are **not** cloud-free, and this doc will not pretend
otherwise. Transcripts, diffs and terminal traffic are; prompt/reply/approval
snippets and metadata are not. If that trade is wrong for a given agent, leave
that agent's hooks uninstalled — the terminal still works over SSH/Mosh.

Verified controls, all of which the daemon exposes:

```fish
moshi-hook set usage-collection off   # stop rate-limit polling + snapshot uploads
moshi-hook set always-on-discovery off # stop idle dev-server/simulator scans
moshi-hook set suppress-nested-agent-push on  # drop events from agents spawned by agents
moshi-hook set scan-ports 3000,5173,8000-8010  # restrict Browser Preview probing
```

### Battery and background

If reconnect or notifications misbehave, check these first:

- **Tailscale app** — Android can kill it. Exempt it: Settings → Apps → Tailscale
  → Battery → *Unrestricted*. Without this the tunnel drops and Moshi cannot
  reach the host at all.
- **Moshi app** — Settings → Apps → Moshi → Battery → *Unrestricted*.
- **Notifications allowed for Moshi** — Settings → Apps → Moshi → Notifications.
  Without this, pushes arrive silently or not at all. `moshi-hook doctor` lists
  this as a "check these yourself" item.
- **Battery optimisation / Data saver** — both can suspend the Tailscale tunnel.
  Disable for Tailscale and Moshi.
- **Private DNS / VPN stacking** — Android's per-app VPN settings can exclude
  Tailscale and send Moshi traffic out unencrypted. Leave Tailscale exempt.
- **Mosh on cellular** — verify the UDP range works on mobile data specifically;
  some carriers shape UDP. If it fails, set Connection type to **SSH**: you lose
  roaming, not function.

---

## 8. Termux fallback

Fully independent: needs only port 2222, the phone key, and Tailscale. Nothing
from `moshi-hook`, nothing from herdr beyond the terminal itself.

### Install Termux from the official source

Choose a source using the project's [installation guidance](https://github.com/termux/termux-app#installation):

- **F-Droid** provides stable builds; updates can arrive later than GitHub
  because F-Droid builds and publishes them separately.
- **GitHub Releases** provides upstream APKs directly, including builds for
  specific architectures. Download only from the official repository below.
- **Google Play** provides a separate experimental branch for Android 11+,
  adapted to Play Store requirements, with functionality differences and bugs
  compared with the stable builds. Prefer F-Droid or GitHub for this fallback.

**Do not mix APKs from different sources:** Termux and all its plugins must come
from the same source because their signing keys differ. Before switching,
back up your data and uninstall Termux and all its plugins.

For GitHub Releases:

```bash
# In a browser on the phone, from the official GitHub repo:
#   https://github.com/termux/termux-app/releases
# Download termux-app_*-arm64-v8a.apk and install it.
```

Verify:

```bash
pkg update && pkg upgrade
pkg install openssh mosh-netcat
```

### Connect

```bash
# Over Tailscale — bring it up first in the Tailscale app
TS_IP=$(echo "<100.x.y.z from tailscale ip -4 on the host>")
ssh -p 2222 -i ~/.ssh/moshi_phone sonny@"$TS_IP"
```

Save it as a host alias so reconnects are one word:

```bash
cat >> ~/.ssh/config <<'EOF'
Host legion
  HostName 100.x.y.z
  Port 2222
  User sonny
  IdentityFile ~/.ssh/moshi_phone
EOF
ssh legion
```

### Mosh

```bash
mosh legion
```

If UDP is blocked, plain `ssh legion` still works — mosh is the resilience layer,
not the transport everything depends on.

### Attach herdr

```bash
herdr                        # attach the default session
herdr session list           # list sessions
herdr session attach work    # a named one
```

Then start agents with the wrappers you already use — `pi`, `claude`. They
launch through herdr exactly as they do on the desktop.

### Detach and reconnect

- **Detach:** `Ctrl-B` then `q`. The agent keeps running.
- **Reconnect:** `herdr` (or `herdr session attach <name>`).

This attaches to the **existing** session. It does not start a second agent —
see the duplicate-agent check in §11.

---

## 9. Terminal keys on a phone

Moshi pre-binds herdr's prefix chords (`Ctrl-B` + key). Moshi's **Settings →
Shortcuts → Herdr** must match `~/.config/herdr/config` — default prefix is
`Ctrl-B`.

| Action | Keys |
| --- | --- |
| New tab | `Ctrl-B` `C` |
| Next / previous tab | `Ctrl-B` `N` / `Ctrl-B` `P` |
| Next / previous pane | two-finger swipe |
| Workspace navigator | `Ctrl-B` `W` (or two-finger vertical swipe) |
| Goto prompt | `Ctrl-B` `G` |
| **Zoom pane** | pinch, or `Ctrl-B` `Z` |
| Kill pane | `Ctrl-B` `X` |
| **Detach** | `Ctrl-B` `Q` |

Gestures: one-finger swipe = next/prev tab, two-finger swipe = next/prev pane,
two-finger vertical swipe = workspace navigator, pinch = zoom a pane
full-screen. All use the configured prefix and are remappable under **Settings →
Input → Gestures**.

- **Ctrl-C** interrupts whatever the focused pane is running. Through a prefix
  chord, `Ctrl-B` `C` is a *new tab* — these are different.
- **Escape** is sent as Escape. It is also what Chat View's stop button sends.
- **Multiline prompts:** agents accept pasted multi-line text. Prefer paste over
  typing newlines — a literal Enter may submit.
- **Paste:** long-press to paste, or use the clipboard row. Large pastes into
  an agent prompt are more reliable than in a raw shell.
- **Resize:** resizing the Moshi window reflows the remote terminal — mosh sends
  the new geometry and the TUI redraws. Full-screen on a phone is usually best;
  landscape helps with wide diffs. Tabs beat panes at phone width.
- **If the keyboard or rendering misbehaves**, switch that connection to
  Connection type **SSH**. You lose roaming and reconnect, not function.

---

## 10. Troubleshooting

### Moshi cannot find `herdr`

`herdr` is not on the **non-interactive** SSH PATH, which is what Moshi probes.

```fish
ssh <host> 'echo $PATH; command -v herdr'
ssh <host> 'sh -lc "command -v herdr"'    # what the "not installed" dot uses
```

On this host both already resolve to `/etc/profiles/per-user/sonny/bin/herdr`.
If a future change breaks it, fix the PATH rather than reaching for
`PermitUserEnvironment` — that is global, affects every user, and is not a PATH
tool.

### Daemon cannot find herdr, but the app can

`moshi-hook doctor` says *"installed, but the moshi-hook daemon cannot find it"*.
The app probes through a shell; the daemon does not. The unit already sets
`MOSHI_HERDR_PATH` and an explicit `PATH`. Check they survived:

```fish
systemctl --user show moshi-hook.service -p Environment
systemctl --user restart moshi-hook.service
```

### ~60 s hang, then an auth error, key is definitely authorized

Tailscale SSH has hijacked port 22. Confirm with:

```fish
tailscale debug prefs | grep RunSSH     # RunSSH: true
```

The fix here is port 2222 (real OpenSSH), not disabling Tailscale SSH. If you
deliberately connect to 22 from Moshi, empty the password and key fields and let
Tailscale authenticate — but key auth will not work there, and mosh cannot
bootstrap through it.

### `mosh-server` not found

Mosh bootstraps through a non-interactive SSH session, which loads no rc file.
Our unit puts `/run/current-system/sw/bin` on the daemon's PATH. Verify:

```fish
ssh -p 2222 sonny@<host> 'command -v mosh-server'
```

If blank, set **Mosh path** in the connection's Mosh options to the absolute
path, or check `programs.mosh.enable`.

### Mosh connects then dies; UDP blocked

```fish
ss -lunp | grep mosh-server        # must be within 60000-60010
tailscale ping <phone>
```

If the port is in range and `tailscale ping` works but mosh still fails, the
**tailnet ACL** is dropping UDP. Confirm the `udp:60000-60010` grant exists —
remember that is enforced before the host firewall is consulted. Carrier UDP
shaping on cellular is the other candidate; use Connection type SSH.

### Gateway forwarding / Chat View fails, terminal is fine

The gateway must stay on loopback and be reached over the same SSH connection.
On the host:

```fish
systemctl --user is-active moshi-hook.service
ss -tlnp | grep 24543               # expect 127.0.0.1:24543, NOT 0.0.0.0
```

In the app: reconnect the terminal session so the forward is re-established. If
Moshi says "disconnected", the tunnel is down, not the daemon.

If `ss` shows `0.0.0.0:24543`, something overrode
`MOSHI_HOOK_GATEWAY_LISTEN` — that would publish diffs and approval endpoints to
every interface.

### Chat View never becomes available

Chat View relays prompts through tmux or herdr, so an agent in a **bare shell**
is terminal-only no matter how the hooks are configured. Start it inside herdr
(`pi` and `claude` do this for you). Also check **Settings → Chat Mode → Chat
View → Enable Chat** is on. It is experimental and needs a live gateway.

### herdr will not start at boot

```fish
loginctl show-user sonny -p Linger   # must be Linger=yes
systemctl --user status herdr.service
journalctl --user -u herdr.service -b
```

If `Linger=no`, the user manager starts at first login — the mobile flag sets
`users.users.sonny.linger = true`, so re-check that `mobileAgents.enable` is
still true and rebuild.

### Secrets missing after a cold boot

```fish
systemctl --user status sops-import-environment.service
ls -l ~/.config/sops/secrets-env      # must exist and be readable
```

herdr and moshi-hook both `After`/`Want` that unit, so the user manager
environment is populated before either starts. `ANTHROPIC_API_KEY` is
intentionally **not** exported (OAuth is used instead); that exclusion is
honoured by both the secrets template and the session variables.

Do not print the environment to inspect it — use
`systemctl --user show-environment | grep -c '^OPENAI_API_KEY='` to count
matching entries (1 means present, 0 means absent) without printing the value.
Replace `OPENAI_API_KEY` with the variable name you need to check.

### Duplicate notifications / duplicate hooks

```fish
herdr agent list | grep -c '"agent"'      # expect one entry per agent
grep -c moshi ~/.claude/settings.json     # one Moshi entry
ls ~/.pi/agent/extensions/ | grep moshi   # exactly one moshi-hooks.ts
```

Two notification paths mean both a herdr hook and a Moshi hook are firing.
Remove Moshi's entries with `moshi-hook uninstall`, then re-run
`moshi-agent-hooks` if you still want them. Do not hand-edit
`~/.pi/agent/extensions/herdr-agent-state.ts` — herdr owns and rewrites it.

### Reconnect launched a second agent

`herdr` on the host, from a second SSH session:

```fish
herdr agent list
herdr workspace list
```

Attaching must not spawn anything. If a second agent appeared, it came from
starting an agent again rather than from attaching — the wrappers reuse a fresh
agent of the same kind in the same cwd, and only when one is not already
running. Close the duplicate pane (`Ctrl-B` `X`) rather than killing the server.

### Something is in the way after a rebuild

```fish
nswitch-confirm            # if you already verified, make it permanent
nixos-rollback-to <gen>    # otherwise, revert and reboot
```

If the rebuild succeeded but a unit did not reload,
`systemctl --user daemon-reload`.

---

## 11. Acceptance checklist

Two columns: **build-level** (safe, done from this repo) and **device-level**
(needs the phone and a real rebuild). Nothing disruptive was run against live
agents — §12 says exactly what was and was not executed.

### Build-level

- [x] `alejandra --check` passes on all changed files.
- [x] `nix eval` clean for `legion`: ports `[2222]`, `openFirewall false`,
      `linger true`, `moshEnable true`, `moshFw false`, `withUtempter false`,
      no 60000-61000 in `allowedUDPPortRanges`.
- [x] `nix eval` clean for `gs65` (leak check): `ports [22]`, `moshEnable
      false`, `linger null`, no `moshi-hook` unit, herdr still
      `graphical-session.target`.
- [x] `sshd -t` accepts the generated config, and `sshd -T -C …lport=…` shows
      port 22 keeping today's live settings while 2222 resolves to
      `PasswordAuthentication no` / `KbdInteractiveAuthentication no` /
      `PermitRootLogin no` / `AllowAgentForwarding no` / `AllowTcpForwarding yes`.
- [x] `moshi-hook 0.4.11` builds from the pinned hash, which matches upstream's
      published `checksums.txt`.
- [x] The bounded `mosh-server` wrapper is the one on PATH, asserted at build
      time by comparing link targets.
- [x] `moshi-server` with `-p 60000:60010` binds a port **inside** the range —
      verified live (`MOSH CONNECT 60000`).
- [x] Exactly **one** herdr in the closure; `MOSHI_HERDR_PATH` is the same
      stable profile symlink herdr's own unit uses.
- [x] herdr unit diff is confined to `WantedBy` and graphical-session `After`
      ordering; `ExecStart`, `ExecCondition`, `KillMode=mixed`,
      `Restart=on-failure`, no `PartOf` all unchanged.
- [x] Warning emitted while `phoneAuthorizedKey` is null.

### Device-level — manual, after a real activation

- [ ] **SSH 2222 authenticates with the phone key through Tailscale.**
      `ssh -p 2222 -i ~/.ssh/moshi_phone sonny@<ts-ip>` works; an unauthorized
      key does not.
- [ ] **Recovery on 22 still works.** `ssh -p 22 sonny@<ts-ip>` (Tailscale SSH)
      and LAN SSH both still succeed. Confirm `RunSSH: true`.
- [ ] **New ports are unreachable from ordinary LAN/WAN.** From another machine
      on the LAN, probe `nc -vz -w 5 <legion-lan-ip> 2222` and
      `sudo nmap -sU -p 60000-60010 <legion-lan-ip>`. From a non-tailnet WAN
      machine, probe `nc -vz -w 5 <legion-public-ip> 2222` and
      `sudo nmap -sU -p 60000-60010 <legion-public-ip>` against each public
      address (add `-6` for IPv6). UDP `open|filtered` is inconclusive: confirm
      drops with firewall counters or packet capture while probing with a live
      Mosh session. Leave this item unchecked until TCP 2222 and every UDP port
      in 60000–60010 are confirmed unreachable from both vantage points.
      Over the tailnet, SSH and Mosh must still succeed.
- [ ] **The configured Mosh UDP range is actually used.** During a mosh session:
      `ss -lunp | grep mosh-server` shows a port within `60000-60010`.
- [ ] **Closing and reopening Moshi preserves the same agent process.** Note
      `herdr agent list` PIDs, background the app, reopen, confirm unchanged.
- [ ] **Wi-Fi → cellular preserves the same process.** Same check across the
      switch. This is the headline Mosh benefit — confirm it.
- [ ] **Desktop-to-phone attachment does not duplicate agents.** Attach from the
      phone while watching `herdr agent list` on the desktop: count unchanged.
- [ ] **Logout does not terminate the server.** Log out on the desktop; the
      phone can still attach and the same PIDs are there.
- [ ] **Scheduled cold-boot test.** Schedule a reboot with nothing to save.
      After boot, *without logging in*, from the phone: herdr is reachable, and
      agents can start with credentials present. Verify unattended startup and
      secrets readiness:
      ```fish
      loginctl show-user sonny -p Linger        # Linger=yes
      systemctl --user is-active herdr.service  # active, no login
      systemctl --user is-active moshi-hook.service
      ```
      Confirm no desktop login was needed. Note the Wayland caveat from §1.
- [ ] **`moshi-hook doctor`** reports daemon, gateway, herdr, pairing, and each
      installed agent ✓.
- [ ] **Notifications and supported approvals work.** Trigger an approval prompt
      from a host-side agent; it appears on the phone and Approve/Deny acts on
      the live session.
- [ ] **Disabling moshi-hook leaves ordinary herdr access working.**
      `systemctl --user stop moshi-hook.service`, then attach from the phone and
      run `pi`: the terminal, herdr and the agents are all fine; only the Inbox,
      Chat View and diff/browser preview are gone.
- [ ] **Termux fallback works.** `ssh legion`, `mosh legion`, `herdr`, start `pi`.
- [ ] **Android Chat View: UNVERIFIED.** See below.

### Android-specific feature status

Marked honestly rather than assumed. Everything above the divider was verified on
this host; everything below needs a physical Android device and has not been
tested.

| Feature | Status |
| --- | --- |
| SSH on 2222 with phone key | **UNVERIFIED on device** (config verified via `sshd -T`) |
| Mosh over Tailscale, UDP range honoured | **UNVERIFIED on device** (server-side binding verified live) |
| Reconnect / Wi-Fi→cellular persistence | **UNVERIFIED on device** |
| Moshi session picker listing herdr | **UNVERIFIED on device** |
| Agent hooks: pi, Claude Code, OpenCode | **UNVERIFIED on device** (not yet installed; `moshi-hook doctor` reports "hooks out of date" for all three) |
| Inbox notifications | **UNVERIFIED on device** (host is not paired) |
| Chat View | **UNVERIFIED — treat as iOS-first.** Upstream's Chat View page is written entirely around iOS (Live Activity, Apple Watch, Command-Enter, iCloud sync). Android has the app and the hooks, but Chat View parity is not documented. Confirm in-app before relying on it; the plain terminal is the supported path either way. |
| Biometric key storage | **UNVERIFIED** (app-side) |
| Push notification permission flow | **UNVERIFIED** (app-side) |

---

## 12. What was and was not executed

**Executed (build validation):**

- `alejandra --check` on all changed `.nix` files — passes.
- `nix eval` of `legion` and `gs65` — both clean; option values recorded in §11.
- `sshd -t` plus `sshd -T -C …lport=22` and `…lport=2222` against this host's
  OpenSSH 10.5p1, using a scratch config and a throwaway host key in
  `/tmp`. The **live** sshd was not reconfigured or restarted.
- Built `moshi-hook 0.4.11` from the pinned hash; verified the hash against
  upstream's `checksums.txt` and against `sha256sum` of the downloaded
  archive.
- Built the bounded mosh package; verified by `readlink` that the wrapper, not
  the real binary, is `bin/mosh-server`; ran `mosh-server` with a fake SSH
  backend and confirmed via `ss` and the `MOSH CONNECT` line that it allocates
  only within `60000-60010`.
- `nix build` of `programs.mosh.package` for `legion`.
- Read-only probes against the live host: `moshi-hook doctor`,
  `herdr status server`, `herdr agent list`, one loopback `ssh` to inspect
  `$PATH`, `systemctl cat` / `show` on units, `/etc/ssh/sshd_config`.

**NOT executed (deliberately):**

- `nixos-rebuild switch` — the live generation was **not** switched. Port 2222
  is not open yet; that needs the activation in §2.
- No reboot, no `switch-to-configuration`, no `systemctl restart sshd`.
- **herdr was not stopped or restarted.** `herdr status server` reported
  `running` throughout and the 6 live pi agents were untouched. Every herdr check
  above is an eval of the generated unit, not a runtime change.
- `moshi-hook` was **not** installed, paired, or started on the live host; no
  agent hooks were written to `~/.claude`, `~/.pi` or `~/.config/opencode`. No
  existing agent config was modified. `doctor` was run read-only.
- No key was generated, and `phoneAuthorizedKey` is still `null`.
- No tailnet ACL was changed.
- Every device-level checkbox in §11 remains untested.
- `pkgs.mosh` is **patched only inside this closure** (`-std=c++20`, in
  `pkgs/moshi-hook.nix`). Any other consumer of mosh from this flake's nixpkgs
  gets the unpatched derivation and would fail to build. Revisit when nixpkgs
  fixes mosh.

### Known blocker

`moshi-hook` 0.4.11 requires Moshi Pro (or an active trial) for **Chat View**;
the terminal, Mosh, herdr and the agent hooks do not require it. Everything else
in this document works on the free tier.

### Out of scope for this change

Optional **OpenCode Web** and **Claude Remote Control** are deliberately not
part of the initial implementation. This setup reaches the agents already
running inside herdr; adding a second, web-based control surface would be a
different architecture with a different trust story.
