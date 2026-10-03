# nixos/tests — checks that run without a machine

Everything here runs against a disposable root, a fake `ps`, fake podman, or a
throwaway VM. **Nothing here touches the real home directory, the real Nix
store, the real container runtime, or any running service**, and none of it
reboots anything.

## Running

```console
nix build ./nixos#checks.x86_64-linux.maintenance-contracts   # fast, seconds
nix build ./nixos#maintenanceVm                             # VM, needs KVM
nix flake check ./nixos                                      # runs the fast one
```

Or, while editing, without nix:

```console
bash nixos/tests/run.sh                       # lint + every shell suite
bash nixos/tests/ns-maint-transaction.sh      # one suite, standalone
```

## What each suite is for

| File | What it proves |
|---|---|
| `lib/harness.sh` | The shared foundation: disposable fixtures, fake `nix`/`nix-store`/`nix-env`/`systemctl`/`systemd-run`/`journalctl`, and assertions. |
| `ns-maint-transaction.sh` | The maintenance transaction's phases, under injected failure. |
| `kill-switch-targets.sh` | What a kill sweep is allowed to target, and what it must never target. |
| `disk-cleanup-safety.sh` | What the cleanup script refuses to delete. |
| `run.sh` | The single entry point the flake check runs. |
| `maintenance-vm.nix` | That the above holds on a real, booted, systemd-managed NixOS system. |

## The failure-injection scenarios

Each one is a case where the OLD implementation was wrong, so each has a test
that fails if the old behaviour comes back.

| Scenario | What is injected | What must happen |
|---|---|---|
| Build longer than the timeout | `nix build` sleeps past `--build-timeout` | Nonzero exit, phase stays `idle`, **no deadline, no activation, no rollback, no reboot** |
| Build of any length | slow build, no timeout | Still `prepared`, still nothing armed |
| **Partial activation, unchanged profile** | activation exits 1 without moving the profile | Restore happens anyway, `restore_result=restored-live`, and the operator is told partial application is possible |
| **Caller disconnect** | `systemd-run` detaches, activation takes 2s | `activate` returns first; the detached unit finishes and advances the record by itself |
| **Concurrent request** | a second `activate`, and separately a held lock | Refused, with the phase named; the held-lock case exits **75** (retryable), not 1 |
| **Stale confirmation** | confirm with a previous transaction's txid | Refused as a mismatch, naming the transaction actually pending; the newer one is untouched |
| **Timeout vs confirm** | confirm before the deadline / after it / after it but before the watchdog | Confirm wins before the deadline; refused after it; refused again once restored |
| **Recovery failure** | both the live `switch` and the `boot` fallback fail | `phase=restore-failed`, both failures recorded, "RESTORATION DID NOT COMPLETE" in plain words, still no reboot |
| Boot intent only | live restore fails, `boot` succeeds | `restore-failed` recorded, **and** the old bootloader entry written |
| **Restart with a pending record** | a real record left by a crash, then `reconcile` | Classified `reconciled-booted` / `reconciled-not-applied` / `restored` / `restore-failed`; deadline always cleared; nothing retried; converges over repeated cold boots |
| **Protected GC** | a full pending transaction | candidate, running and booted closures all pinned; released on confirm except the booted one; `gc` never passes `--delete` |
| **Dirty worktree preservation** | real git worktrees with unstaged changes | Survives `--prune-worktrees`, named in the output |
| **Untracked worktree preservation** | real git worktree with an untracked file | Survives, named in the output |
| Age is not authority | a clean, 1-day-old worktree | Survives |
| Only the abandoned go | a clean, 30-day-old, unowned worktree | Removed **only** with `--prune-worktrees --yes` |
| Report, never delete | a dirty worktree under `--deep` | Reported with counts, no removal command at all |
| Service-aware cleanup | the bun cache reported as held open | Skipped, and not scheduled for clearing |
| No consent, no deletion | destructive flags without `--yes` | Aborts, having collected nothing |
| **Server kill sweeps** | fake `ps` with management processes, their descendants, bare shared runtimes and real workloads | Management and descendants are never targets, in `--light` and `--full`; bare `node`/`bun`/`python` survive without `--include-runtimes`; identified workloads (`vite`, `pytest`, `cargo`) do not |
| A real sweep | each persona mapped onto a real disposable process | The workload actually dies; herdr, the agent under it, Collie and sshd are actually alive afterwards |
| **No implicit reboot** | *every scenario above* | A single assertion, applied to every path, that nothing recorded a reboot |
| Kernel-dirty refusal | candidate with a different kernel | `activate` refuses, nothing armed, directs the operator to `stage` |
| Staging | the same candidate | `boot` on the candidate, no `switch`, nothing live changed |
| Reboot | no `--yes`; then with a pending transaction | Refused both times, with the reason |
| All-input update | `--update-all`, then `--update-input nixpkgs` | The first is refused; the second updates exactly one input |
| **Record validation** | a record with a path-traversal candidate; another host's record; an unknown phase | All three are hard errors with an actionable message |
| Privileges | `NM_TEST_MODE` unset | Every mutating command refuses |
| Installation invariants | a world-writable state directory | `verify-installation` fails and names the mode |

## The VM test

`maintenance-vm.nix` boots a real NixOS system with the real units and proves
the things a shell suite with fakes cannot:

- `ns-maint-verify` passes **as a unit**, with the environment the module
  configures — not with one hand-built in the test.
- The three units are actually enabled.
- `/run/current-system` and `/run/booted-system` are store paths, which is an
  arm-time precondition.
- `reconcile` is a clean no-op with no transaction, and correctly classifies a
  real `armed` record left behind by a simulated crash — clearing the deadline,
  which is what prevents a restore/reboot/restore loop.
- A **real systemd timer** fires a real `ns-maint tick`, which takes the real
  lock, reads the real record and performs a real restore. The record's own
  `note` (`restoring (deadline-expired)`) is the evidence; a test VM's journald
  is volatile and would say nothing.
- A refused activation restores, and the outcome is `restored-live`.
- The VM's uptime at the end proves nothing rebooted.

The activation itself is substituted through `maintenance.activationCommand` —
a real, documented option, not test-only plumbing. That is what makes the
restore deterministic: the alternative is re-activating a running machine during
a test that is about the transaction's logic.

## What is deliberately NOT here

- **Any test that touches the real machine.** No test here activates NixOS, runs
  a real `nix-collect-garbage`, prunes a real container volume, deletes a real
  worktree, or reboots anything. The cleanup suite's `sudo` is a fake that
  dispatches to other fakes by absolute path, precisely so a fall-through to a
  real tool is impossible.
- **A repository-wide lint or secret scan.** A whole-repo shellcheck and a CI
  workflow belong to the repository-contracts PR; carrying them here would make
  every sequential PR noisy.
- **A test that mirrors the implementation.** The suites drive the real scripts
  and assert on the record, the state left behind and the calls made. There is
  no re-implementation of the state machine to drift out of sync with.

## Notes for anyone extending this

- Fakes are written with a **hardcoded interpreter path**, not
  `#!/usr/bin/env bash`: a nix build sandbox has a coreutils-only root where
  `/usr/bin/env` does not exist, and a fake that cannot find its interpreter
  fails with "bad interpreter", which reads like a bug in the tool under test.
- Every `FAKE_*` knob is **reset by the fixture**, not only the ones it happens
  to use. They are exported, so a leftover value silently changes the meaning of
  a later test. (This bit once: a failing activation in one test was still
  failing in every test after it.)
- The test VM's driver script is **Python**. A bare shell line like
  `ns-maint status` does not parse, and the type checker reports it as an
  unrelated storm of "name not defined" errors.