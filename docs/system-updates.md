# Updating Stealth and Legion

`nupdate` updates the `nixpkgs` input, builds the selected machine, then applies
the result. This upgrades NixOS, Nix, and packages supplied by that input.
Other inputs, such as herdr, remain at their current lock-file revisions.

Run these from a terminal on Stealth:

| Command | Result |
| --- | --- |
| `nupdate` | Update Stealth (`gs65`). |
| `nupdate legion` | Update Legion remotely over Tailscale SSH. |
| `nupdate both` | Update Legion, confirm that exact transaction through a fresh connection, then update Stealth. |
| `nconfirm legion` | Confirm Legion's pending live update through a fresh connection. |

In a shell connected to Legion, bare `nupdate` updates Legion. The shell's
host determines the local target. Run `nupdate both` from Stealth's own terminal.

Legion keeps the build-before-activation workflow, detached activation, and
20-minute rollback deadline. A single-host update leaves confirmation to you:
check access from another session, then run `nconfirm legion`. `nupdate both`
does that connection check and confirmation before starting the laptop's build.
If the remote update or confirmation fails, the laptop update does not start.

Kernel or NVIDIA module changes are staged as a boot generation on either
machine. The running system stays in place. Choose a reboot window when ready;
on Legion use `sudo ns-maint reboot --yes`, and on Stealth reboot normally.
If Legion's update is staged, `nupdate both` proceeds with Stealth and reports
that Legion still needs its planned reboot.

Each machine uses its own `/home/sonny/.dotfiles/nixos` checkout. Synchronize
the intended configuration changes to both machines first; each upgrade writes
that machine's `nixos/flake.lock`. Review and commit the resulting lock changes
when ready. Avoid concurrent upgrades of the same host.

The remote helper uses the existing `legion-tailscale` alias (port 22), which
authenticates with your Tailscale identity. Confirmation disables SSH connection
sharing so it opens a fresh transport. Sudo passwords are requested in the
terminal, as with the existing update commands.

To install these helpers initially, bring this configuration to each checkout
and rebuild once. On Stealth use `nswitcho`. On Legion use `nswitcho`, check access
from a new session, then confirm the printed transaction with
`sudo ns-maint confirm <txid>`. After that the four commands above are available
in new terminals.

For another flake input on Legion, the existing explicit command remains:
`nswitchu herdr` (substitute the intended input name).
