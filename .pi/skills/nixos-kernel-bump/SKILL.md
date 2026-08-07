---
name: nixos-kernel-bump
description: Fix NVIDIA driver/library version mismatch after kernel bump on NixOS. Triggers when nswitchu/nixos-rebuild switch fails with "Driver/library version mismatch" or when nvidia-smi fails after a system update. The fix is to run nixos-rebuild boot --flake then reboot.
---

# NixOS Kernel Bump — NVIDIA Driver Mismatch Fix

## Problem

When `nixos-unstable` bumps the Linux kernel AND the NVIDIA driver in the same update, running `nswitchu` (or `nixos-rebuild switch`) may fail to install the new bootloader entries. After reboot, the old kernel + old NVIDIA kernel module remain loaded, while the userspace has new NVIDIA libraries — causing:

```
nvidia-smi: Failed to initialize NVML: Driver/library version mismatch
```

And `nvidia-container-toolkit-cdi-generator.service` fails to start, blocking future activations.

## Diagnosis

```fish
# Check if you're running the old kernel despite having activated the new config
uname -r                    # Shows old kernel version (e.g. 7.1.0 instead of 7.1.1)
modinfo nvidia | grep version  # Shows old driver (e.g. 595.80 instead of 595.84)
nvidia-smi                  # Fails with "Driver/library version mismatch"
readlink /run/booted-system   # Points to old generation
readlink /run/current-system  # Points to new generation — MISMATCH

# Confirm missing boot entry
sudo bootctl list | grep "Generation NNN"  # No entry for the new generation with the new kernel
```

## Fix

The bootloader entries need to be regenerated to point to the new kernel:

```fish
sudo nixos-rebuild boot --flake ~/.dotfiles/nixos#sonny-laptop
```

Verify the new entry was created:

```fish
sudo bootctl list | grep -E "Linux $(uname -r | cut -d. -f1-2)\."  # Should show new kernel
```

Then reboot:

```fish
systemctl reboot
```

After reboot, verify:

```fish
uname -r    # Should be the new kernel
nvidia-smi  # Should work
systemctl status nvidia-container-toolkit-cdi-generator.service  # Should be active
```

## Why This Happens

`nh os switch` calls `nixos-rebuild switch`, which runs activation before bootloader installation. If activation fails partway (e.g. a service like `nvidia-container-toolkit-cdi-generator` fails due to the very mismatch we're fixing), the `installBootLoader` step may not complete. The new kernel and driver are never written to `/boot/EFI/nixos/`, so every reboot loads the old kernel.
