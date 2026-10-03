---
name: nixos-kernel-bump
description: Fix NVIDIA driver/library version mismatch after a kernel bump on NixOS. Triggers when an OS activation fails with "Driver/library version mismatch", when nvidia-smi fails after a system update, or when uname -r does not match the closure you just activated. On an unattended server this routes through the staged boot maintenance in ns-maint and never reboots implicitly.
---

# NixOS Kernel Bump — NVIDIA Driver Mismatch Fix

## Read this first: a live switch cannot load a new kernel

The single fact this skill is organised around:

> `switch-to-configuration switch` reconfigures services and writes a
> bootloader entry. It does **not** change the running kernel. The kernel is
> whatever the machine booted with, and nothing short of a reboot changes it.

Everything below follows from that. In particular:

- An activation that "succeeded" may still be running the old kernel.
- An activation that "failed" may still have reconfigured live units — the
  profile is set *after* activation, so a failure can leave changed services
  behind an unchanged profile. **Do not read an unchanged profile as "nothing
  happened".**
- `nixos-rebuild boot` writes the bootloader entry and stops there. It does not
  activate, and it does not reboot.
- **A live rollback cannot fix a kernel/driver mismatch.** Restoring the previous
  closure restores the previous *userspace*; the running kernel is untouched.

## Desktop vs unattended server — pick the right path

| | Desktop (in front of the machine) | Unattended server (`opts.headless = true`) |
|---|---|---|
| build | `ns-maint prepare` | `ns-maint prepare` |
| apply now | `ns-maint activate` | `ns-maint activate` |
| confirm | `ns-maint confirm <txid>` from a second terminal | `ns-maint confirm <txid>` **from a NEW connection** |
| write the boot entry | `ns-maint stage` | `ns-maint stage` |
| reboot | your call, at the keyboard | `ns-maint reboot --yes`, and only in a window where you have console or a second path back |

On a server, nothing reboots by itself. If something claims otherwise, that
claim is wrong — see `docs/headless-server.md`.

## Problem

When `nixos-unstable` bumps the Linux kernel AND the NVIDIA driver in the same
update, `nh os switch` can fail partway: `nvidia-container-toolkit-cdi-generator`
fails because the userspace library is newer than the still-loaded kernel
module, and the bootloader entry for the new generation is never written. Every
subsequent boot then loads the old kernel with new userspace libraries, and:

```
nvidia-smi: Failed to initialize NVML: Driver/library version mismatch
```

## Diagnosis

Read-only. Safe to run on the server.

```fish
# Which kernel is actually running
uname -r

# Three different things people confuse with each other
readlink -f /run/booted-system     # what the machine BOOTED — the kernel is this one
readlink -f /run/current-system   # what was last ACTIVATED (may differ)
readlink /nix/var/nix/profiles/system  # the intended profile (may differ again)

# The driver actually loaded
modinfo nvidia | grep version

# Symptom
nvidia-smi                        # "Driver/library version mismatch"

# Boot entries — is the new generation present at all?
sudo bootctl list

# What does the machine think is pending?
sudo ns-maint status
```

If `/run/booted-system` differs from `/run/current-system`, you are mid-
something. Read `ns-maint status` before changing anything.

## Fix

### 1. Stage the new generation — write the bootloader entry

```fish
sudo ns-maint prepare      # build only; arms nothing, activates nothing
sudo ns-maint stage        # writes the boot entry; switches nothing live
```

`stage` is `switch-to-configuration boot` plus GC pinning. It cannot disturb the
running system, and it is a separate command precisely so it can be done on a
machine you cannot afford to interrupt.

### 2. Activate the candidate without switching

Activating the new closure while the OLD kernel runs is what produces the
mismatch in the first place. On a server, **do not do this as a matter of
routine** — `ns-maint activate` refuses a candidate whose kernel differs from
the running closure, precisely because of this failure. If you have a reason to
force it:

```fish
sudo ns-maint activate --allow-unknown-kernel --timeout 20m
```

That flag exists for the case where the kernel check could not *compare* the
closures, not for overriding a difference it found.

### 3. Reboot — only when you have chosen to

```fish
sudo bootctl list                 # confirm the new entry exists, FIRST
sudo ns-maint reboot --yes
```

On a server: only do this in a window where you have physical or out-of-band
access. A reboot is the only thing that resolves a kernel/driver mismatch, and it
is also the only thing in this whole workflow that can strand the machine. If you
do not have a second way in, do not reboot — apply updates, stage the kernel, and
defer.

### 4. Verify after the reboot

```fish
uname -r                          # must now be the NEW kernel
nvidia-smi                        # must work
systemctl status nvidia-container-toolkit-cdi-generator.service
readlink -f /run/booted-system    # now matches /run/current-system
```

## If the activation failed and the transaction rolled back

`ns-maint` restores automatically, **without rebooting**:

- the old closure is re-activated (`switch-to-configuration switch`),
- the profile and boot entry are pointed back,
- the record says so: `ns-maint status` will show `phase=restored`.

If it shows `phase=restore-failed`, the restoration itself did not work. That is
reported plainly, with the reason, and you must treat it as an outage rather than
a warning: the runtime may be a mixture of the old and new closures.

```fish
sudo ns-maint status
sudo journalctl -u ns-maint-verify.service -u ns-maint-reconcile.service --since -1h
sudo bootctl list       # is the boot entry for the old generation still there?
```

A failed live restore still writes the OLD closure's bootloader entry, so the
next ordinary boot lands somewhere known-good — that is why the tool attempts
`boot` after `switch` fails.

## What this skill must not do

- **Never reboot the unattended server as a side effect of a fix.** Not as a
  fallback, not "to make the driver match", not at the end of a run.
- **Never treat an unchanged profile as evidence that nothing was applied.**
- **Never `nix-collect-garbage -d` before a reboot you may still need.** The
  recovery closure is pinned with a GC root, but generations you delete by hand
  are gone. Use `ns-maint gc` (which never passes `-d`).
- **Never run `ns-maint activate --update-all`.** It is refused on purpose;
  name the input you mean.

## Why this happens

`nh os switch` runs `nixos-rebuild switch`, which activates before installing
the bootloader entry. If activation fails partway — for instance because
`nvidia-container-toolkit-cdi-generator` cannot start against the mismatched
driver — `installBootLoader` never runs. The new kernel is never written to the
EFI partition, so every reboot loads the old kernel again, and the failure
repeats forever.