# Headless server mode

Turning a host into an always-on box that is only ever reached remotely — the
Legion parked in a basement while its owner is abroad, in the case this was
written for.

The guiding constraint behind every choice here: once the machine is on another
continent, the only recovery path that does not involve talking a relative
through a boot menu is _"it came back up on its own."_ So the design favours
coming back over being clever.

## What the role does

The switch is `role`, per host:

```nix
# hosts/legion/options.nix
role = "server";        # stays behind, reached only remotely
headless = true;        # the resolved answer, written out; see below

# hosts/gs65/options.nix
role = "desktop";       # travels, suspends when the lid shuts
```

`headless` is still the boolean every module reads, and it is still what you can
set on its own. The role is a second way in, not a replacement:

| `role`         | `headless` | Result                                                          |
| -------------- | ---------- | --------------------------------------------------------------- |
| `"server"`     | anything   | `headless` resolves to **true**; the whole server behaviour applies |
| `"desktop"`    | `false`    | A laptop: suspends, lid works, desktop autologins                 |
| `"desktop"`    | `true`     | **Refused at evaluation**, with both switches named in the error   |
| `null`         | either     | `headless` decides, exactly as it always did                       |

Two of those rows matter more than they look.

**A host promoted to a server edits one line.** Setting `role = "server"` on a
host whose `headless` is still the untouched `false` default gets every headless
behaviour, because the role is resolved in `nixos/flake.nix` and folded back into
the boolean. Nothing has to remember a second line, and there is no half-applied
state where a host is a server in one module and a laptop in another.

**The contradictory pair is refused rather than resolved.** `role = "desktop"`
next to `headless = true` cannot be true: modules that read `headless` (suspend
removal, lingering, LAN ports, exit node) would behave as a server while the role
says laptop. That is an evaluation-time error naming both switches, not a warning
you scroll past.

The policy itself is a pure function — `nixos/lib/host-policy.nix`, builtins
only, no nixpkgs — and it is the single place either answer is decided. It also
rejects two more combinations that have no good half-state: a phone listener on
port 22 (Tailscale SSH answers there before sshd does, so a key-authenticated
client stalls and then reports an auth error that says nothing about the key), and
Collie enabled on top of `mobileAgents.enable = false` (a bridge with no way in).

What a server role changes:

| Area     | Change                                                                | Why                                                                                    |
| -------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Desktop  | greetd stops autologging into mango                                   | Nothing should run a compositor for an empty room                                      |
| Sleep    | `sleep`/`suspend`/`hibernate` targets masked; lid + power key ignored | Resume is known-broken on this NVIDIA + mango combo (`config/home/idle.nix`)           |
| Lingering| `linger` on, with **no** dependency on the phone clients being on      | The user manager must exist with nobody logged in; that is the server, not the phone     |
| Wi-Fi    | MAC pinned to `permanent` instead of randomised                       | A new MAC per reconnect means a new DHCP lease, possibly a new IP                      |
| DNS      | Numeric resolvers appended behind dnscrypt-proxy, `maxnames` raised   | dnscrypt failing to start would otherwise leave the box with no name resolution at all |
| Firewall | Ports 11434 (ollama) / 8188 (ComfyUI) closed to the LAN               | Unauthenticated HTTP; a family LAN is not a trust boundary                             |
| VPN      | Proton `wg0`, its kill-switch and its `NOPASSWD` sudo rules **absent** | The kill-switch REJECTs all output that is not marked for wg0 — the tailnet included     |
| NTFS     | `/mnt/shared` not mounted                                             | A hibernated Windows volume mounted `rw` is a corruption waiting to happen              |
| Tailnet  | Advertises itself as an exit node                                     | A Norwegian IP for banking and geo-locked services from abroad                         |
| SSH      | Password and keyboard-interactive auth off, root login off            | Keys and Tailscale SSH are the two ways in                                             |
| Nix      | `${username}` added to `trusted-users`                                | Lets the travel laptop offload builds here                                             |
| Battery  | `batteryChargeLimit` honoured if set; the achieved limit is reported   | A pack held at 100% for months is a pack you replace                                   |

The VPN row is the one worth pausing on. The Proton kill-switch was previously
present on every host, with four `NOPASSWD` sudo rules to start and stop the
tunnel and to write its config. On a machine whose only ingress is the tailnet,
those rules hand a passwordless privilege to anything that reaches the session —
including writing the config file the tunnel reads — and the kill-switch itself
would cut the tailnet off with a five-second fuse. On a server role the
interface, the kill-switch and the sudo rules are all *structurally* absent: not
documented as discouraged, gone. The Waybar toggle fails with a sudo prompt,
which is the correct outcome.

Crucially, **nothing is uninstalled**. Mango, waybar, Zed, Steam and the rest
stay in the closure. Walk up to the machine, log in at tuigreet, and the normal
desktop is there. The role only stops anything from starting one unattended.

That was a deliberate call. Stripping the GUI would save disk and nothing else —
the desktop renders on the Intel iGPU (see `config/system/services.nix`), so it
never competed with ollama for VRAM in the first place, and the daemons that
_did_ cost something only ever start inside a session. Ripping packages out
would buy a few GB of a 2 TB disk in exchange for a machine that is useless the
next time you are physically in front of it.

### The travel side of the same policy

`desktop` is not a consolation prize for the other machine. It means: suspends
when the lid shuts, the lid and idle keys behave like a laptop, the desktop
autologins, LAN service ports stay open, no exit node, no lingering. There is
deliberately no third `travel` role — an enum value with no behaviour of its own
is how a policy stops being readable, and a machine that is not a server already
behaves like a laptop.

What is travel-specific is per host, and therefore already scoped that way:
`hosts/gs65` leaves `batteryChargeLimit` unset at the base default; a limit may
be configured there once its writable threshold is confirmed (see below). The
sleep behaviour comes from the firmware and the desktop session rather than
from a role.

## Everything on the tailnet, nothing on the internet

`services.tailscale` is enabled on **every** host, not just the server's — it is
how the travel laptop reaches the basement at all. Tailscale dials out, so the
router, its NAT, CGNAT, and any number of Wi-Fi resets are all irrelevant. There
is nothing to port-forward and nothing to keep working.

Two flags are applied automatically on every boot via `extraSetFlags`:

- **`--ssh=true`** — Tailscale SSH, a second and fully independent way in that
  does not depend on the OpenSSH key material below being right. If one path
  breaks, the other still works. This redundancy is the entire reason password
  auth can safely be turned off.
- **`--accept-dns=false`** — not optional. Tailscale's resolver would take over
  `/etc/resolv.conf` and displace dnscrypt-proxy (see below), which is both a
  privacy regression and one more way to strand a machine nobody can reach a
  console for. MagicDNS is therefore _off_, and peers are named through
  `opts.tailnetHosts` instead.

### Coming back on its own

`tailscaled-set` is a oneshot. It retries now — with a bound, 10s → 20s → … →
5 minutes, forever, because the old fixed 10s meant a node whose uplink arrived
an hour later had woken the unit thirty times first and buried the real error in
the noise.

Retrying one command does not cover the failures that matter, though. What
`tailscale-reconcile.service` (a persistent timer, every five minutes) adds is
convergence: it looks at the node and moves it towards the declared state. Each
of these now fixes itself with nobody at the machine:

| Situation                                              | What it does                                                                 |
| ------------------------------------------------------ | ---------------------------------------------------------------------------- |
| Cold boot, uplink not up yet                           | Keeps finding `NeedsLogin`, says so, retries; changes nothing                 |
| Credentials available minutes later                    | The next tick sees `Running` and applies the preferences                      |
| Serve mapping never written (certificate not issued)   | Repairs that one mapping, individually                                        |
| A future listener added on 443 alongside Collie        | Left completely alone — only a missing or wrong mapping is ever written        |
| DNS name changed under a stale `serveHosts`            | Fails with both names, rather than serving a name Collie will refuse          |

What it will never do, and each of those has a reason:

- **`tailscale up`** — that is the login flow. On an already-authenticated node
  it can start an interactive re-auth prompt on a machine with nobody at the
  keyboard; on a logged-out node it does nothing useful without a browser.
  Preferences are changed with `tailscale set`, which cannot log in.
- **`tailscale serve reset`** — it erases *every* mapping on the node, including
  the Collie HTTPS/443 one and any listener added later.
- **`tailscale funnel`** — that publishes to the public internet. The mapping is
  private Serve only, and the reconciler has no funnel code path at all.
- **any reboot** — a repair job must not interrupt a box you reach only remotely.

### DNS: one owner, and a rescue list that is not silently truncated

There is exactly one component listening on port 53 — dnscrypt-proxy — and
NetworkManager is kept out of its way with `dns = "none"`. Two things follow that
were previously wrong:

**The rescue resolvers were being discarded.** The old list was
`127.0.0.1`, `::1`, `9.9.9.9`, `1.1.1.1`, `2620:fe::fe` with no cap. `resolv.conf(5)`
limits how many nameservers a resolver consults (MAXNS) and *silently discards*
the rest, and openresolv — what NixOS installs — applies a default of its own. So
on the host where losing dnscrypt-proxy means losing name resolution entirely,
including for `controlplane.tailscale.com`, the rescue list was truncated away by
the mechanism meant to apply it.

The list and the cap are now computed together, in `nixos/lib/host-policy.nix`
(`dnsPolicy`), and `maxnames` is set from the length of the list. A server gets
four (two loopback, Quad9, Cloudflare); the travel laptop keeps only its two
loopback addresses, because a machine on hotel wifi is better off not silently
sending every lookup to a public resolver when its local cache misses. Both
values are readable from a built configuration:

```console
nix eval --json .#nixosConfigurations.legion.config.hostPolicy.dns
```

The rescue addresses are **numeric** on purpose: a resolver named by a hostname
depends on DNS working in order to be reachable, which is precisely the condition
the rescue exists for. They are plain UDP/53 resolvers — this is availability,
not privacy. dnscrypt-proxy is asked first every time and is the privacy half.

**The retry limits were in the wrong section.** `StartLimitBurst` was set under
`serviceConfig` for dnscrypt-proxy, where systemd does not read it: it is a
`[Unit]` directive. That line was inert, and the resolver kept systemd's default
of 5 starts in 10 seconds — which anything that takes longer to fail than that
blows through on a cold boot, after which the machine has no DNS at all until
something restarts it. Both the resolver and `tailscaled-set` now set
`startLimitIntervalSec` where it belongs, with bounded exponential backoff
instead.

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

### Everyday use on the Legion

The Legion is an always-on server with an optional local desktop. Its current
`role = "server"` disables suspend and autologin. `desktop.enable = true`
keeps the graphical login screen available; set it to `false` in
`hosts/legion/options.nix` once the machine is remote-only. Desktop packages
remain installed, and agent services run without Mango in either case.
The GS65's desktop role and update aliases are unchanged.

Use `nupdate` to update nixpkgs, build, and apply. Use `nswitch` to apply your
edited dotfiles offline without updating inputs, or `nswitcho` to allow
network downloads. All three use the same kernel check: a new kernel is staged
for a planned reboot, while compatible changes use guarded live activation.
After a live activation, check a fresh connection and run `nconfirm`. If you
skip confirmation, the previous configuration is restored after 20 minutes.
`nswitchu` is a compatibility name for `nupdate`; `nswitchu herdr` updates only
that explicitly named input. `ns-maint` remains the lower-level maintenance
interface described below. None of these commands automatically reboots.

Herdr is for persistent terminals and agents. Use `ns-gui <command>` for GUI
apps launched from those panes after desktop login; Zed uses it automatically.
The launcher validates the current Mango session, forwards arguments without a
shell, and ends the application with the desktop session. It never kills an
existing Zed process based on a window-list guess.

Collie's Serve unit owns HTTPS/443 and retries startup failures with backoff.
The Tailscale reconciler checks drift and restarts that owner when repair is
needed. It does not independently write the same Serve mapping.

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

`confirm` checks that the transaction ID matches, the confirmation deadline has
not expired, and both the running system and system profile match the candidate.
Confirmation is your explicit decision after checking the machine from another
connection. It works over Tailscale SSH, OpenSSH, or a local console; it does not
parse login journals. Failed services are shown as warnings and recorded, so you
can judge them without an unrelated service forcing a rollback.

`activate` waits for the detached system service to finish, then prints a
copyable `sudo ns-maint confirm <txid>` command. Losing the waiting client does
not stop the activation service. Reconnect and run `sudo ns-maint status` to see
the result. An unprivileged status command reports inaccessible state rather
than claiming that there is no transaction.

### When nothing is confirmed

A persistent systemd timer runs `ns-maint tick` every 30 seconds. Expired
transactions are restored by a detached system service, so replacing the timer
service during rollback cannot kill the restoration. If the
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

#### Which kernel, and what "the pin" actually is

The kernel is `pkgs.linuxPackages_latest` from whatever revision `flake.lock`
currently pins, and the root dependency is **not** pinned to a fixed nixpkgs rev:
`flake.nix` tracks `nixos-unstable`, with the last known-good revision sitting
commented out beside it. So "the kernel changed" and "an input moved" are the
same event, and the one deliberate act that moves it is
`ns-maint prepare --update-input nixpkgs`.

Two structural properties make a bump survivable, and both are load-bearing
rather than incidental:

- the NVIDIA driver and `acpi_call` are both taken from
  `config.boot.kernelPackages`, never from the top-level `pkgs`, so a bump moves
  them **with** the kernel instead of stranding them;
- a module built for a different kernel refuses to load, which is why `activate`
  refuses a kernel change outright rather than half-applying it.

Changing kernel *family* — downgrading to something "safer" — is deliberately
not done here. It is a hardware decision, not an evaluation one: downgrading
trades a known property (latest stable kernel, newest driver) for an unknown one
on a laptop whose ACPI and fan control already live deep in vendor firmware. If
a family change is ever needed it should be driven by a specific failure,
validated on this hardware with the out-of-tree modules in play, and written down
in `config/system/kernel.nix` with the reason.

#### Per-host quirks, and one that was quietly wrong

`acpi_osi=…`, `i915.enable_guc=…` and the `acpi_call` module used to be one
shared list, which meant a value either applied to both machines or to neither.
They are per host now (`opts.acpi`), with the values unchanged except one:

`i915.enable_guc=2` was removed from both hosts, on evidence from this machine's
own boot log:

```console
# journalctl -b | grep enable_guc
kernel: Command line: … i915.enable_guc=2 nvidia.NVreg_… acpi_osi=Linux …
kernel: Setting dangerous option enable_guc - tainting kernel
```

"**Tainting kernel**" is the kernel marking itself as started with options whose
effects it cannot vouch for, which then propagates into module signing and
supportability. Meanwhile `/sys/module/i915/parameters/enable_guc` is not
writable on this kernel: the driver no longer offers it as a runtime parameter,
so the command-line value was not reaching a knob at all. GuC and HuC firmware
are loaded by the driver itself now. The old comment — that `2` "enables GuC
only", offloading scheduling tasks to the iGPU — described the parameter as it
was a decade ago and nothing about the current behaviour.

The parameter is still available per host (`opts.acpi.i915Guc`) for anyone on a
kernel where it is still meaningful. **Pending hardware acceptance:** confirm the
iGPU still loads GuC/HuC firmware without it, and that nothing in the i915
sysfs (`/sys/kernel/debug/dri/0/i915_guC*`) looks wrong.

`acpi_call` is no longer loaded on either host. Nothing in this configuration
calls it — it exists for vendor tools that are not installed here — and a kernel
module nobody uses is a little attack surface and a little boot time for no
benefit. It is one boolean per host (`opts.acpi.acpiCall`) if you ever want it
back.

#### The GPU, checked rather than assumed

```console
# cat /sys/class/drm/card0/device/uevent | grep PCI_ID
PCI_ID=10DE:2757          # NVIDIA GeForce RTX 4090 Laptop GPU (Ada/AD103)
```

`10DE:2757` is Ada, comfortably past the Turing cut-off, so
`hardware.nvidia.open = true` (the open kernel modules) is the supported path for
this card and the proprietary ones are a choice rather than a requirement. This
was verified on the card rather than inherited from a config written for a
different machine.

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
sudo ns-maint gc           # collection only; every generation link is retained
```

`--keep` is rejected: this command does not prune generations. `-d` deletes
generations. That is the old `ngc -d` alias and the old
`programs.nh.clean` timer, both removed: deleting a generation deletes a way
back, and on an unattended box "can I go back to the last known-good system" has
to keep working.

### Pinned recovery closures are not a backup

These roots protect against *collection*, not against a disk failure, and they
say nothing about application data. Database migrations, agent conversations and
media databases do not roll back when you roll back OS packages.

## Boot: EFI space, staging, and what happens when it goes wrong

### The ESP is nearly full, and the entry limit lied about it

```console
$ df -h /boot
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p1  511M  476M   36M  93% /boot
```

511 MiB, shared with Windows, and 36 MiB free — while the bootloader was
configured to keep **eight** generations. Each NixOS entry carries a kernel, an
initrd and its boot files, so that configuration could not have been honoured;
`configurationLimit` is enforced while *activating*, and an ESP that fills up
part-way leaves a half-written entry behind that is not obviously the good one.

`configurationLimit` is now 3 — the current generation, the one it replaces, and
one spare. Recover space without touching the running system:

```console
sudo bootctl cleanup          # entries no profile references
sudo nixos-rebuild boot       # reinstall the current profile's entry
```

Do not raise the limit to get more old generations back. The recovery path that
matters is the one systemd-boot can *fall back to*, and that needs the previous
entry, not a list of them.

### Staging now checks before it writes

`ns-maint stage` preflights the ESP before `switch-to-configuration boot`
touches it, and refuses with the reclaim commands if there is not room for a
kernel, an initrd and an entry:

```console
ns-maint: stage: /boot has 35 MiB free, and this stage needs at least
ns-maint:        150 MiB for the kernel, the initrd and the boot entry.
ns-maint:        Refusing to start: a half-written ESP entry is worse than none,
```

`df` needs no privilege, so this is a plain read, and the floor and the path are
configurable (`maintenance.espMinMib`, `maintenance.espPath`) rather than
hardcoded in the tool.

### Boot counting with a LOCAL blessing

systemd-boot's Automatic Boot Assessment is available through nixpkgs: each entry
is written with a boot counter, and an entry whose counter runs out is skipped in
favour of an older one. `systemd-bless-boot.service` clears the counter when the
OS reaches `boot-complete.target`.

"Reached boot-complete.target" is a low bar for a machine you cannot reach, so
`opts.bootHealth` puts a **local** gate in front of it
(`config/system/boot/health.sh`, required by `systemd-bless-boot.service`):

```console
$ systemctl status boot-health-local
$ journalctl -u boot-health-local
```

It checks four things, all of them about this machine's own storage, units and
closure: root is mounted read-write, `/run/current-system` is the same closure as
`/run/booted-system`, a short explicit list of critical units is healthy, and
bootctl can still find the ESP. If any fails, the blessing does not happen, the
counter stays, and systemd-boot falls back on a later boot by itself — no reboot
from here, no timer, no rescue script.

Two deliberate omissions:

- **No `systemctl --failed`.** A failed unit is most often NetworkManager, a
  resolver, tailscaled or a fetch over the wire. Treating that as "this boot is
  bad" is how a machine ends up condemning the good generation it is running
  because the hotel wifi dropped, while you are on a plane. The critical list is
  `local-fs.target` and `systemd-modules-load.service` — and only local ones.
- **No network, anywhere.** There is not a single network call in the script, and
  the regression suite enforces that with tripwires: every network command on
  PATH is a stub that records being called, and the tests fail if it ever is.

**It does not recover from a hang.** A kernel freeze or a hard lock produces no
failed service and never reaches this script at all: there is no boot, so there is
no counter to decrement. Recovering from that needs a hardware watchdog, which
this machine has not been shown to have. Nothing here should be read as a promise
that it does.

### Testing the boot blessing

It is **off** (`opts.bootHealth.enable = false`) and it should stay off until
someone has watched it work, because the first observation of it is a reboot you
have to choose to take. To try it:

1. Walk the pre-departure checklist below by hand, with physical access.
2. Set `bootHealth.enable = true`, rebuild, and reboot when you are ready.
3. Confirm the healthy path: `systemctl status boot-health-local` is `active
   (exited)`, and `bootctl list` shows the entry **without** a `+N` counter —
   that is the blessing.
4. Confirm the unhealthy path with a disposable VM or a temporary change that
   makes a check fail. The suite `nixos/tests/server-foundation/boot-health.sh`
   covers all of the branches (offline, read-only root, absent generation, one
   failed critical unit, no bootloader) against fixtures, but it cannot tell you
   that systemd-boot actually fell back on your hardware.
5. Only then leave it on.

## Charge limits are hardware claims

`config/system/battery/charge-limit.sh` walks a fallback chain of kernel
interfaces and **reports what it achieved**, because the fallbacks are not
equivalent:

| Interface                       | What it actually does                                              |
| ------------------------------- | ------------------------------------------------------------------ |
| `charge_control_end_threshold`  | The number you asked for                                            |
| ideapad `conservation_mode`     | A boolean. Pins the pack at about **60%**, whatever you requested    |
| neither                         | Nothing. Firmware left alone, and the service FAILS                 |

On this Legion:

```console
$ ls /sys/class/power_supply/BAT0/charge_control_end_threshold
ls: cannot access …: No such file or directory
$ cat /sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode
1
```

So `batteryChargeLimit = 80` is honoured through conservation mode and the pack
sits at about 60%. The old script printed "charge limited to 80%" and moved on.
The new one prints the interface, the requested value, the value read back, and
exits non-zero when it achieved nothing — so `systemctl status
battery-charge-limit` can be trusted, and an unattended pack sitting at 100% is
a failed unit rather than a green one.

`60` is the right request for a machine parked on AC; `80` is what this host
carries while it is still a daily driver, and it means 60%. The GS65 has no limit
set, because that host's writable threshold has not been confirmed — **pending
hardware acceptance**; set it to 60 once `sudo battery-charge-limit 60` has told
you what it achieved.

Critical-battery behaviour is unchanged (`upower`: warn at 20%, critical at 5%,
power off at 3%). It is a graceful action on a machine that is normally on AC, and
it is the honest answer for a pack that is actually flat.

## The shared NTFS volume is not mounted

`/mnt/shared` — the Windows dual-boot volume — is off unless `mountShared = true`
in a host's options. Nothing server-critical reads or writes it: every state and
media root here is a native Linux filesystem. The reasons are about unattended
operation, not about NTFS:

- Windows Fast Startup leaves the volume **hibernated**, and ntfs3 mounted `rw` on
  a hibernated volume is a way to corrupt it. The repair needs a booted Windows
  and a keyboard; an unattended box has neither.
- `nofail` used to mean "if it does not mount, carry on", which is right, and then
  nothing noticed whether it mounted at all.
- The partition is not repartitioned, reformatted, resized or re-identified, and
  `ntfs3` stays in `boot.supportedFilesystems`, so copying a file off it by hand
  during recovery still works. Flipping it on is one boolean.

## Private overrides and the build source

`nixos/local.nix` is gitignored and machine-local, and it is now scoped **by
host**:

```nix
# nixos/local.nix — never committed
{
  # _default = { … };              # applies where no host key matches
  legion = { batteryChargeLimit = 60; };
  gs65 = {
    monitorrule = [ "name:^eDP-1$,x:0,y:0,rr:0,vrr:1" ];
  };
}
```

The old flat shape still works and is reported: it applied to *every* host in the
flake, which is rarely what was meant and made a Legion battery limit quietly
become a GS65 battery limit. A host-scoped file that names no key matching the
host being built is reported too, so a typo does not read as "no overrides".

**The part that is easy to get wrong:** nix only sees what git tells it about the
tree. A `flake:` reference evaluates *tracked* files, so a gitignored
`local.nix` is **invisible** to it — the copy nix evaluates does not contain it,
and `builtins.pathExists ./local.nix` is false. An override can therefore look
like it is doing nothing, or vanish between a local read and a build. Three ways
to handle it, in order of preference:

1. **Keep overrides in a host's checked-in options** if they are permanent. That
   is the point of `hosts/<host>/options.nix`.
2. **`git add -f nixos/local.nix`** — indexed, never committed. Files in the
   index are part of the flake source, so it works; the hazard is that any later
   `git add`/`git commit -a` will commit it. Add it to
   `.git/info/exclude`-adjacent muscle memory, or review `git status` before
   committing.
3. **Build by path**: `nixos-rebuild --flake "path:$HOME/.dotfiles/nixos#legion"`.
   Every file is included, tracked or not. Slower, and it does not record the
   revision.

Whichever you use, verify rather than assume:

```console
nix eval .#nixosConfigurations.legion.config.hostPolicy
```

## Never start the Proton VPN on it

On a `desktop` role this is advice. On a `server` role it is not a matter of
advice at all: `networking.wg-quick.interfaces.wg0` does not exist, the
kill-switch's `postUp` is not configured, and the four `NOPASSWD` sudo rules that
let the Waybar toggle write `/etc/nixos/proton-wg.conf` and start the tunnel are
not in `/etc/sudoers`. A stray `systemctl start wg-quick-wg0` finds no unit; a
Waybar click finds no rule.

The reason is the kill-switch itself, which `REJECT`s all output that is not
marked for `wg0` — the tailnet included. On a machine reached only over the
tailnet, starting it is a lockout with a five-second fuse, and on a laptop that
is somebody's desktop, a bad trade. If a server role ever genuinely needs the
tunnel, the answer is a per-host opt-in that has been thought about, not this
default quietly becoming true again.

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

The GS65 keeps its private key in `~/.ssh/nixbuilder`; its Nix daemon runs as
root and reads that file to authenticate to the Legion. Tailscale SSH on port
22 is identity-based, so the builder uses the Legion's key-only OpenSSH listener
on port 2222:

```console
# on the client (gs65)
ssh-keygen -t ed25519 -N "" -f ~/.ssh/nixbuilder -C gs65-nixbuilder
cat ~/.ssh/nixbuilder.pub
```

Before activation, replace the existing `remoteBuilder.authorizedKey` values in
both `nixos/hosts/gs65/options.nix` and `nixos/hosts/legion/options.nix` with the
output of `cat ~/.ssh/nixbuilder.pub` on the GS65. Do not add it to the operator's
`sshAuthorizedKeys`: the separate field keeps builder access independently
revocable. The GS65 config points `remoteBuilder.sshKey` at
`/home/sonny/.ssh/nixbuilder` for the Nix daemon. Pin the Legion host key in
`travel.serverHostKey` and make sure `tailnetHosts` maps `legion` to its current
Tailscale address.

After both configurations are activated, verify the key-only path:

```console
ssh -i ~/.ssh/nixbuilder -p 2222 sonny@legion true
```

`builders-use-substitutes` is on, so the Legion pulls dependencies from the
binary caches itself rather than having them fetched over a hotel connection and
pushed across the tailnet.

## Pre-departure checklist

Configuration:

- [ ] `role = "server"` and `batteryChargeLimit = 60` in `hosts/legion/options.nix`
- [ ] `sudo battery-charge-limit 60` run by hand, and the **achieved** value read
      from its output (see "Charge limits are hardware claims" — it may be a
      boolean, not a percentage)
- [ ] Rebuilt, and SSH verified from a _second_ session
- [ ] `sudo ns-maint confirm` exercised over `ssh -p 2222` at least once, so the
      phone path is known to work before you need it
- [ ] `tailnetHosts` filled in with the Legion's `100.x` address
- [ ] Exit node approved in the admin console
- [ ] Remote builder key exchanged and a test build offloaded
      (`remoteBuilder.authorizedKey` set, or the build runs as the operator)

Hardware:

- [ ] BIOS: restore on AC power loss enabled
- [ ] Verified with a real power-cycle that it boots to NixOS unattended
- [ ] Ethernet connected if at all possible
- [ ] `df -h /boot` checked — if it is above ~85%, `bootctl cleanup` and a
      `nixos-rebuild boot` **before** you leave

Before you actually go:

- [ ] Key expiry disabled on both tailnet nodes, and the date noted here:
      ____________
- [ ] Models pulled that you expect to want
- [ ] Parents shown where the power cable is, and told "unplug, wait ten
      seconds, plug back in" is the whole recovery procedure

## Refrences

- consider looking at https://github.com/Osmantic/ODS
- https://wiki.nixos.org/wiki/Jellyfin
