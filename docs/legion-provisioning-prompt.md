# Legion media provisioning — temporary agent brief

**Status: TEMPORARY.** This file is a one-shot brief handed to an LLM running
*on the Legion*. It is not documentation of how the system works, and it should
be deleted once the provisioning run is finished and reviewed. It is kept in the
repository only so the exact text sent to the agent is reviewable.

If you are an agent: read [`docs/media-travel.md`](media-travel.md) § "Turning
media on" and `docs/headless-server.md` first. This file is the task, not the
reference.

---

## Before you send this

Two things block the run and no agent can resolve either. Settle them first, or
the agent will correctly refuse to proceed.

1. **Disk.** The Legion had ~78 GiB free of 929 GiB (92 % used) at the time of
   writing. A single 4K remux is 40–80 GiB. Measure before sending this brief.
2. **Divergent checkouts.** Both machines were on `17369b3` with the Legion clean
   and the MSI carrying uncommitted work. Your own guidance in
   `docs/system-updates.md` says to synchronize first and avoid concurrent
   upgrades of one host.

---

## Copy from here down

```
You are provisioning a NixOS media server (hostname `legion`). Read this whole
brief before acting. You are on an unattended remote machine with a human
reachable only by Tailscale.

─── HARD RULES (violating any of these wastes the run) ───────────────────
1. You CANNOT run sudo unattended. `sudo -n` fails. Do not attempt privileged
   operations in a loop and do not ask for a password more than once.
   → When a step needs root, write it out verbatim as a single copy-pasteable
     command for the human, mark it [[NEEDS ROOT]], and move on. Never fake
     completion, never "temporarily" disable a guard to get past a refusal.
2. NEVER run `nix flake update`, `nh os switch --update`, or edit flake.lock.
   The nixpkgs pin is deliberate and shared with another machine.
3. NEVER reboot. NEVER run `systemctl reboot`. This box is reached remotely.
4. NEVER run `tailscale serve reset`. It erases the Collie mapping on 443 and
   silently breaks phone access. Only ever touch your own port.
5. NEVER enable `enablePersistence`. Never write to `/mnt/shared` — it is a
   Windows NTFS volume and must never be written from here.
6. Your login shell is FISH. Any remote or compound command must be
   `bash -lc '...'` or piped to `bash -s`. `ssh legion '<loop>'` WILL fail.
7. Do not reformat or resize any partition. Do not write media to /mnt/shared.
8. `linger` and Collie are the phone's only path in. Keep them working; check
   `systemctl --user status collie` after anything that touches Tailscale.
9. If reality contradicts this brief, TRUST THE MACHINE and report the
   contradiction. Do not rewrite your understanding to fit your assumptions.

─── VERIFIED STATE (checked 2026-10-09; re-verify, do not assume) ─────────
- HEAD 17369b3, working tree CLEAN. The MSI has uncommitted changes; this
  checkout does NOT. Expect drift — do not copy MSI-side changes here.
- `/srv` is EMPTY. No jellyfin, qbittorrent or syncthing installed.
- `tailscale serve` = Collie only (443 → 127.0.0.1:8787). Do not disturb it.
- `linger=yes`. You are a trusted nix user; builds run as you.
- The MSI builds through you over ssh-ng://sonny@legion on port 2222. If you
  change anything about sshd or the builder key, that path breaks silently.
- ⚠ DISK: ~78 GiB free of 929 GiB (92 % used). THIS BLOCKS EVERYTHING BELOW.

─── PHASE 0 — REPORT ONLY, DO NOT ACT ────────────────────────────────────
Produce a short briefing containing:
  a. `df -h / /nix /home`, and `du -sh` of the largest directories you can read
     WITHOUT sudo (/nix/store, ~/.local, ~/.cache). Identify reclaim candidates.
     Do NOT delete anything. Do NOT run `nix-collect-garbage`.
  b. Confirm the verified state above still holds; flag anything that changed.
  c. [[NEEDS ROOT]] Give the human `sudo ns-maint status` to run and request
     its output. Do not run it yourself during Phase 0.
  d. One paragraph on where a media library should live, given the real numbers,
     with the tradeoff of /srv versus an external disk.
STOP after Phase 0 and wait for the human. Do not proceed to Phase 1.

─── PHASE 1 — PLAN ONLY (await approval after Phase 0) ───────────────────
Write a numbered plan covering, in order:
  1. Disk reclamation. State the exact expected GiB recovered per action.
     `ns-maint gc` only — never `-d`, never `--keep`.
  2. Jellyfin. `media.jellyfin.enable = true` in hosts/legion/options.nix, plus
     the human steps that CANNOT be automated:
        - complete the first-run wizard and create the administrator
        - only then set `media.jellyfin.setupCompleted = true`
     Sequence matters: while the wizard is unfinished, publication is refused on
     purpose, because any tailnet device that reaches it can claim admin.
  3. Verify Serve port 8443 is supported by the pinned Tailscale BEFORE
     enabling. If it is not, say so and STOP — do not pick another port.
  4. Transcoding: leave OFF. NVIDIA is deliberately excluded from Jellyfin
     because that GPU is for Ollama, and sharing it stops inference mid-stream.
     State plainly that playback will software-transcode.
  5. Torrents. The network-namespace design is sound and already written, but it
     needs three things no agent may invent:
        - a WireGuard `wg-quick strip` config in sops (a private key — never
          generate one, never commit one)
        - a WebUI proxy token in sops
        - `uploadLimitKbit` SET TO A MEASURED VALUE. null = unbounded seeding on
          a box that also runs agents and builds.
     Present the measurement command; let the human choose the number.
  6. Split every step into: what you do, versus what needs [[NEEDS ROOT]].
  7. The exact verification for each step, so completion is provable.
Present the plan. Do not execute Phase 1 without explicit approval.

─── PHASE 2+ — only after the human approves Phase 1 ────────────────────
One step at a time. After each: verify it, report the evidence, then continue.
If a step fails, STOP and report. Never paper over a failure.
If earlier steps changed the machine, roll back to the prior state and verify
the rollback when safe and permitted by the hard rules. Otherwise, explicitly
hand off the partial state for human recovery: list completed changes, the
failed step, current state, and exact recovery commands (mark privileged ones
[[NEEDS ROOT]]). Do not continue provisioning or claim completion; leave no
partial configuration without a documented recovery handoff.

─── OUT OF SCOPE THIS RUN ────────────────────────────────────────────────
- Agent-to-agent task passing between this box and the MSI. Not configured, not
  a toggle, and bundling it makes this unreviewable. Defer.
- Rebooting to load a new kernel.
- Syncthing. It propagates deletions; the folder list must be chosen by a human
  first, deliberately, not defaulted.
- Touching the MSI's dotfiles checkout.

─── FINAL REPORT ─────────────────────────────────────────────────────────
Per item: DONE / FAILED / BLOCKED — with the command and its real output as
evidence. List every [[NEEDS ROOT]] command still outstanding, in run order.
If you could not verify something, say "UNVERIFIED" — never imply it passed.
```
