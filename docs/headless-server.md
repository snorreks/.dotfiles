# Headless server mode

Turning a host into an always-on box that is only ever reached remotely — the
Legion parked in a basement while its owner is abroad, in the case this was
written for.

The guiding constraint behind every choice here: once the machine is on another
continent, the only recovery path that does not involve talking a relative
through a boot menu is *"it came back up on its own."* So the design favours
coming back over being clever.

## What the flag does

Set `headless = true;` in `hosts/<host>/options.nix` and rebuild. That single
flag:

| Area        | Change                                                                     | Why                                                                                   |
| ----------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Desktop     | greetd stops autologging into mango                                        | Nothing should run a compositor for an empty room                                     |
| Sleep       | `sleep`/`suspend`/`hibernate` targets masked; lid + power key ignored      | Resume is known-broken on this NVIDIA + mango combo (`config/home/idle.nix`)          |
| Wi-Fi       | MAC pinned to `permanent` instead of randomised                            | A new MAC per reconnect means a new DHCP lease, possibly a new IP                     |
| DNS         | Public resolvers appended behind dnscrypt-proxy                            | dnscrypt failing to start would otherwise leave the box with no name resolution at all |
| Firewall    | Ports 11434 (ollama) / 8188 (ComfyUI) closed to the LAN                    | Unauthenticated HTTP; a family LAN is not a trust boundary                             |
| Tailnet     | Advertises itself as an exit node                                          | A Norwegian IP for banking and geo-locked services from abroad                          |
| SSH         | Password and keyboard-interactive auth off, root login off                 | Keys and Tailscale SSH are the two ways in                                             |
| Nix         | `${username}` added to `trusted-users`                                     | Lets the travel laptop offload builds here                                             |
| Battery     | `batteryChargeLimit = 60` (set separately)                                 | A pack held at 100% for months is a pack you replace                                    |

Crucially, **nothing is uninstalled**. Mango, waybar, Zed, Steam and the rest
stay in the closure. Walk up to the machine, log in at tuigreet, and the normal
desktop is there. The flag only stops anything from starting one unattended.

That was a deliberate call. Stripping the GUI would save disk and nothing else —
the desktop renders on the Intel iGPU (see `config/system/services.nix`), so it
never competed with ollama for VRAM in the first place, and the daemons that
*did* cost something only ever start inside a session. Ripping packages out
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
  for. MagicDNS is therefore *off*, and peers are named through
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
  the manual Windows entry `sort-key aa`, which places it at the *top of the
  menu*; systemd-boot's `default` directive should still win, but this is worth
  proving with a real power-cycle rather than trusting.

### 4. Prefer ethernet

If a cable can reach it, use one. Basement + Wi-Fi + six months unattended is
the kind of bet that only has to lose once.

### 5. Physical placement

Off carpet, with clearance around the intakes. The lid can be shut — logind
ignores it in headless mode — but a stand that keeps the vents clear is better
than a laptop lying flat on a shelf collecting basement dust for half a year.

## Rebuilding it remotely

`nixos-rebuild switch` does **not** drop an existing SSH session, so ordinary
updates are unremarkable. Two rules make them safe anyway.

### Always work inside a multiplexer

A rebuild killed halfway by a dropped connection is its own failure mode, and
the one most likely to happen on hotel Wi-Fi. `tmux` is installed on headless
hosts for exactly this, and `nswitch-safe` refuses to run outside one.

### Use `nswitch-safe` for anything that touches networking

```console
ssh legion
tmux new -s rebuild
nswitch-safe
```

This arms a dead man's switch before rebuilding: if `nswitch-confirm` has not
run within 20 minutes (`ROLLBACK_TIMEOUT` to change), the machine reverts to the
generation it was on and reboots into it. The timer is a transient *system*
unit, so it outlives the SSH session that armed it — which is the whole point.

After the rebuild returns, **open a second SSH session** to verify you can still
get in. Do not trust the one you are holding: an already-established TCP
connection survives plenty of configurations that would refuse a new one.

```console
nswitch-confirm    # disarms; this generation is now permanent
```

If the rebuild itself fails, no new generation was created, so `nswitch-safe`
disarms automatically — there is nothing to revert.

An autonomous "is the internet up?" watchdog was considered and rejected. It
cannot tell a config mistake from the parents' ISP having a bad afternoon, so it
reboots the machine for problems a rollback will not fix. The dead man's switch
arms only across the window where *you* changed something, which is when the
risk actually exists.

### Manual rollback

`nixos-rollback-to <generation>` does the same thing on demand — switch the
profile, write the bootloader entry with `switch-to-configuration boot` (not
`switch`, since the running generation may be the one with broken networking),
and reboot.

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
- [ ] Rebuilt, and verified SSH still works from a *second* session
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
