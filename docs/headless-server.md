# Headless server mode

Turning a host into an always-on box that is only ever reached remotely — the
Legion parked in a basement while its owner is abroad, in the case this was
written for.

The guiding constraint behind every choice here: once the machine is on another
continent, the only recovery path that does not involve talking a relative
through a boot menu is _"it came back up on its own."_ So the design favours
coming back over being clever.

## What the flag does

Set `headless = true;` in `hosts/<host>/options.nix` and rebuild. That single
flag:

| Area     | Change                                                                | Why                                                                                    |
| -------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Desktop  | greetd stops autologging into mango                                   | Nothing should run a compositor for an empty room                                      |
| Sleep    | `sleep`/`suspend`/`hibernate` targets masked; lid + power key ignored | Resume is known-broken on this NVIDIA + mango combo (`config/home/idle.nix`)           |
| Wi-Fi    | MAC pinned to `permanent` instead of randomised                       | A new MAC per reconnect means a new DHCP lease, possibly a new IP                      |
| DNS      | Public resolvers appended behind dnscrypt-proxy                       | dnscrypt failing to start would otherwise leave the box with no name resolution at all |
| Firewall | Ports 11434 (ollama) / 8188 (ComfyUI) closed to the LAN               | Unauthenticated HTTP; a family LAN is not a trust boundary                             |
| Tailnet  | Advertises itself as an exit node                                     | A Norwegian IP for banking and geo-locked services from abroad                         |
| SSH      | Password and keyboard-interactive auth off, root login off            | Keys and Tailscale SSH are the two ways in                                             |
| Nix      | `${username}` added to `trusted-users`                                | Lets the travel laptop offload builds here                                             |
| Battery  | `batteryChargeLimit = 60` (set separately)                            | A pack held at 100% for months is a pack you replace                                   |

Crucially, **nothing is uninstalled**. Mango, waybar, Zed, Steam and the rest
stay in the closure. Walk up to the machine, log in at tuigreet, and the normal
desktop is there. The flag only stops anything from starting one unattended.

That was a deliberate call. Stripping the GUI would save disk and nothing else —
the desktop renders on the Intel iGPU (see `config/system/services.nix`), so it
never competed with ollama for VRAM in the first place, and the daemons that
_did_ cost something only ever start inside a session. Ripping packages out
would buy a few GB of a 2 TB disk in exchange for a machine that is useless the
next time you are physically in front of it.

## Everything on the tailnet, nothing on the internet

`services.tailscale` is enabled on **every** host, not just the headless one —
it is how the travel laptop reaches the basement at all. Tailscale dials out, so
the parents' router, its NAT, CGNAT, and any number of Wi-Fi resets are all
irrelevant. There is nothing to port-forward and nothing to keep working.

Two flags are applied automatically on every boot via `extraSetFlags`:

- **`--ssh=true`** — Tailscale SSH, a second and fully independent way in that
  does not depend on the OpenSSH key material being right. If one path breaks,
  the other still works. This redundancy is the entire reason password auth can
  safely be turned off.
- **`--accept-dns=false`** — not optional. Tailscale's resolver would take over
  `/etc/resolv.conf` and displace dnscrypt-proxy, which is both a privacy
  regression and one more way to strand a machine nobody can reach a console
  for. MagicDNS is therefore _off_, and peers are named through
  `opts.tailnetHosts` instead.

## First-time setup

Most of this is declarative. These are the parts that cannot be.

### 1. Join the tailnet

Once, on each host:

```console
sudo tailscale up
```

Then in the **Tailscale admin console**:

- **Disable key expiry** on both nodes. This is the single most likely way to
  lose the box six months in: the default 180-day key expiry will silently
  drop it off the tailnet while you are abroad, and the fix requires a console.
- **Approve the exit node** the Legion is advertising.

### 2. Record the tailnet address

MagicDNS is off, so name the peer statically. On the Legion:

```console
tailscale ip -4
```

Put the result in `nixos/options.nix`:

```nix
tailnetHosts = {"100.x.y.z" = ["legion"];};
```

### 3. BIOS

Two settings, both requiring physical access, both of which decide whether a
power cut is a non-event or a dead machine:

- **Restore on AC power loss / auto power-on** — enable it. Without this, the
  box stays off once the battery runs down, and stays off.
- **Boot order** — confirm the machine actually lands on NixOS. `boot.nix` gives
  the manual Windows entry `sort-key aa`, which places it at the _top of the
  menu_; systemd-boot's `default` directive should still win, but this is worth
  proving with a real power-cycle rather than trusting.

### 4. Prefer ethernet

If a cable can reach it, use one. Basement + Wi-Fi + six months unattended is
the kind of bet that only has to lose once.

### 5. Physical placement

Off carpet, with clearance around the intakes. The lid can be shut — logind
ignores it in headless mode — but a stand that keeps the vents clear is better
than a laptop lying flat on a shelf collecting basement dust for half a year.

## Updating it remotely

There are **four separate operations**, and the words that do them are
deliberately four different words. This replaces the old `nswitch-safe` wrapper,
which collapsed all four into one command that armed a dead-man timer *before*
building and rolled back with `systemctl reboot` — so a slow build rebooted the
server, and a failed activation was treated as proof that nothing had changed.

`ns-maint` implements the transaction. It is in `config/system/maintenance.nix`;
its header comment explains the reasoning, and `docs/headless-server.md` is only
the operator's side of it.

| Operation | Command | Arms a deadline | Activates | Reboots |
|---|---|---|---|---|
| Update inputs | `ns-maint prepare --update-input nixpkgs` | no | no | no |
| Build | `ns-maint prepare` | **no** | no | no |
| Apply live | `ns-maint activate` | yes, immediately before mutation | yes | no |
| Confirm | `ns-maint confirm <txid>` | disarms | no | no |
| Stage a reboot | `ns-maint stage` | no | no | no |
| Reboot | `ns-maint reboot --yes` | no | no | **yes** |

### Why the build is a separate command

`prepare` builds the exact closure for the selected host and pins it with a GC
root. It arms nothing, records no recovery state, and starts no unit — so there
is no deadline that can fire while a build is running. A build that takes six
hours causes zero activation and zero rollback, by construction rather than by
luck.

If a build fails, `prepare` says so and stops. The running system is untouched.

Input updates are separate and explicit. `--update-all` is **refused**: on a
machine that is your only way in, an unreviewed all-input bump is exactly the
failure this exists to prevent.

```console
ssh legion
sudo ns-maint prepare --update-input nixpkgs   # rewrites nixos/flake.lock
git -C ~/.dotfiles diff nixos/flake.lock        # review it before going further
sudo ns-maint prepare
```

### Applying it, and what "armed" means

```console
sudo ns-maint status            # read this first
sudo ns-maint activate --timeout 20m
```

`activate` does four things, in this order:

1. reads and records the old running closure, the profile and boot intent, the
   **booted** closure, the candidate, the transaction id and the deadline —
   atomically, into a root-owned record;
2. pins the recovery closure and the booted closure with GC roots, so a
   collection during the window cannot remove the way back;
3. refuses if the candidate carries a **different kernel** than the running
   closure (see "Kernel and driver changes" below);
4. only then arms the deadline, and hands activation to a transient **system**
   service — so a dropped SSH connection cannot kill it half-way.

Activation does not need a multiplexer any more. `tmux` is still installed,
because watching a build scroll for an hour in a bare session is unpleasant,
but nothing depends on it.

### Confirming properly

```console
sudo ns-maint status        # copy the txid
```

Then, **from a different connection**:

```console
ssh legion                   # a NEW session, not the one the activate ran in
sudo ns-maint confirm tx-20261003T120000Z-a1b2c3
```

`confirm` checks three things and refuses if any fails:

- **the transaction id matches.** A confirmation for an older update cannot
  bless a newer one. This is the whole point of printing the id.
- **local health evidence**: the profile resolves to the candidate,
  `/run/current-system` is the candidate, and `systemctl --failed` is empty. The
  evidence is stored in the record, so a later reader can see what was true when
  you said yes.
- **a NEW connection was accepted by sshd since the switch was armed.** It reads
  `SSH_CONNECTION` to identify your peer, then asks the sshd journal whether a
  session from that peer was accepted *after* the arming time. A socket that was
  already open when the network unit was rewritten proves nothing about whether
  a fresh client can get in — that is the check the old workflow was missing.

From a local console there is no `SSH_CONNECTION`; pass
`--assume-new-connection` once you have actually checked reachability from
another device. The record notes that the evidence was asserted rather than
verified.

### When nothing is confirmed

A persistent systemd timer runs `ns-maint tick` every 30 seconds. If the
deadline passes with the transaction still pending, it restores the old closure
**live**:

1. `switch-to-configuration switch` on the old closure — runtime, profile and
   boot entry together;
2. if that fails, `switch-to-configuration boot` on the old closure, so the next
   ordinary boot is known-good, and the record is marked `restore-failed` with
   the reason.

**Nothing reboots.** Not on timeout, not on failure, not as a fallback. The
previous implementation's rollback was `systemctl reboot`, which on this machine
means killing every running agent and stream.

Read the result plainly:

```console
sudo ns-maint status
```

- `phase=restored` — the old closure is live again.
- `phase=restore-failed` — **this is an outage, not a warning.** The runtime may
  be a mixture of two closures. Check what is actually running:

  ```console
  readlink -f /run/current-system
  readlink -f /run/booted-system
  readlink /nix/var/nix/profiles/system
  bootctl list
  ```

### A failed activation is not "nothing happened"

`nh os switch` activates with `switch-to-configuration test` before it moves the
profile. So a failure can leave **live units reconfigured and the profile
unchanged**. The old wrapper read that as "no new generation exists, nothing to
revert" and disarmed its rollback — on exactly the case that needed one.

`ns-maint` never infers safety from the profile. A nonzero activation restores,
whatever the profile says. `restore_result` in the record says whether that
succeeded.

### Cold boots and the persistent record

The record outlives reboots; a transient timer does not. `ns-maint-reconcile`
runs once at boot and classifies whatever it finds:

| Situation | Result | What it does |
|---|---|---|
| Booted into the candidate | `reconciled-booted` | Clears the deadline. Nothing restored; needs an explicit confirm. |
| Booted on the old closure | `reconciled-not-applied` | Clears the deadline. **Nothing is retried.** |
| Was restoring, came back on the old closure | `restored` | Records `restored-by-reboot`. |
| Was restoring, came back on neither | `restore-failed` | Says so. |

Reconcile never arms anything, never activates and never reboots. That is what
makes a restore/reboot/restore loop impossible: if it re-armed on boot, a machine
that fails to restore would boot, re-arm, restore, fail, and reboot forever.

To retry a candidate that was not applied, start a new transaction:

```console
sudo ns-maint activate
```

### Kernel and driver changes

A live switch **cannot load a new kernel**. `ns-maint activate` therefore
compares the kernel module trees of the candidate and the running closure and
**refuses** if they differ, pointing at staging instead. This is not caution:
activating userspace that expects different kernel modules is what produces
`nvidia-smi: Driver/library version mismatch`, and a live rollback cannot fix it
because the kernel is still the old one.

```console
sudo ns-maint prepare
sudo ns-maint stage          # boot entry written, nothing switched live
sudo bootctl list            # confirm the entry exists
sudo ns-maint reboot --yes   # the ONLY reboot, and only when you chose it
```

Read `.pi/skills/nixos-kernel-bump/SKILL.md` for the full procedure. Short
version: on this machine a reboot needs a window in which you have a second way
in, and if you do not, stage the kernel and defer it. Applying userspace updates
without rebooting is safe; rebooting is the part that needs a plan.

### Verifying the installation

`ns-maint-verify` runs at every boot and checks the properties the rest of the
tool assumes — most importantly that `/var/lib/nixos/maintenance` is root-owned
and not group/other-writable. A non-root caller that could write the record could
forge a transaction and make root activate something.

```console
sudo ns-maint verify-installation
systemctl status ns-maint-verify ns-maint-reconcile ns-maint-deadline.timer
```

### Recovery closures and garbage collection

Recovery generations are not enough: a daemon can be running from a closure that
no generation points at any more. `ns-maint` pins the booted closure, the
running closure and any prepared candidate with explicit GC roots, so they
survive collection regardless of how many generations are kept.

```console
sudo ns-maint roots        # what is pinned, and what it points at
sudo ns-maint gc --keep 3  # collection, and NEVER -d
```

`-d` deletes generations. That is the old `ngc -d` alias and the old
`programs.nh.clean` timer, both removed: deleting a generation deletes a way
back, and on an unattended box "can I go back to the last known-good system" has
to keep working.

### Pinned recovery closures are not a backup

These roots protect against *collection*, not against a disk failure, and they
say nothing about application data. Database migrations, agent conversations and
media databases do not roll back when you roll back OS packages.

## Never start the Proton VPN on it

`networking.wg-quick.interfaces.wg0` carries a kill-switch that `REJECT`s all
output not marked for `wg0`. That includes the tailnet. Starting it remotely
severs the only way back in. It does not autostart and is not
`wantedBy = multi-user.target`, so this only happens if someone runs it by hand.

## LLM workflow

Ollama is already configured and tuned for the 4090's 16 GB in
`config/system/services.nix` — flash attention, q8 KV cache, a 30-minute
keep-alive, one model resident at a time.

**Adding models needs no rebuild.** They live in `/var/lib/ollama`:

```console
ssh legion
ollama pull qwen3:32b
ollama list
```

Reach the API from any tailnet device — the port is closed to the LAN but the
tailnet interface is trusted:

```console
curl http://legion:11434/api/tags       # needs tailnetHosts set
```

**On latency:** Asia to Norway is roughly 150–250 ms round trip. That is a fixed
addition to time-to-first-token; once streaming starts it is invisible. Fine for
chat and agentic work, irritating for inline autocomplete. Worth being honest
that a 16 GB-VRAM-class local model will not beat a hosted frontier model for
most coding — the wins are privacy, unmetered use, and jobs you would rather not
pay per token for (batch summarisation, transcription, ComfyUI).

## Remote builds

The sleeper feature: stop grinding builds through the travel laptop.

One-time key exchange, since nix runs distributed builds as the daemon user and
cannot use Tailscale SSH:

```console
# on the client (gs65)
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_nixbuilder
sudo cat /root/.ssh/id_nixbuilder.pub
```

Add that public key to `sshAuthorizedKeys` in `nixos/options.nix`, rebuild the
Legion, then teach root the host key and verify:

```console
sudo ssh -i /root/.ssh/id_nixbuilder sonny@legion true
```

Finally, in `hosts/gs65/options.nix`:

```nix
remoteBuilder = {
  enable = true;
  hostName = "legion";   # or the 100.x address if tailnetHosts is unset
};
```

`builders-use-substitutes` is on, so the Legion pulls dependencies from the
binary caches itself rather than having them fetched over a hotel connection and
pushed across the tailnet.

## Pre-departure checklist

- [ ] `headless = true` and `batteryChargeLimit = 60` in `hosts/legion/options.nix`
- [ ] Rebuilt, and verified SSH still works from a _second_ session
- [ ] Key expiry disabled on both tailnet nodes
- [ ] Exit node approved in the admin console
- [ ] `tailnetHosts` filled in with the Legion's `100.x` address
- [ ] BIOS: restore on AC power loss enabled
- [ ] Verified with a real power-cycle that it boots to NixOS unattended
- [ ] Ethernet connected if at all possible
- [ ] Remote builder key exchanged and a test build offloaded
- [ ] Models pulled that you expect to want
- [ ] Parents shown where the power cable is, and told "unplug, wait ten
      seconds, plug back in" is the whole recovery procedure

## Refrences

- consider looking at https://github.com/Osmantic/ODS
- https://wiki.nixos.org/wiki/Jellyfin
