# nixos/tests — checks that run without a machine

Everything here runs against a disposable root, a fake `ps`, fake podman, or a
throwaway VM. **Nothing here touches the real home directory, the real Nix
store, the real container runtime, or any running service**, and none of it
reboots anything.

## Running

```console
nix build ./nixos#checks.x86_64-linux.maintenance-contracts   # fast, seconds
nix build ./nixos#checks.x86_64-linux.agent-operations        # credentials, lifetime, daemon roots, health, backup
nix build ./nixos#checks.x86_64-linux.media-travel            # media namespace/travel state
nix build ./nixos#checks.x86_64-linux.repo-contracts-shells   # registry tests, update_dotfiles scope, repo-wide lint
nix build ./nixos#checks.x86_64-linux.repo-contracts          # sys-daemon HTTP admission + process-kill tests
nix build ./nixos#maintenanceVm                               # VM, needs KVM
nix flake check ./nixos                                        # runs the fast ones
```

Or, while editing, without nix:

```console
bash nixos/tests/run.sh                            # lint + every registered suite
bash nixos/tests/ns-maint-transaction.sh           # one suite, standalone
bash nixos/tests/agent-operations/run.sh           # the agent-operations lane
bash nixos/tests/agent-operations/daemon-roots.sh  # one lane suite, standalone
```

## The registry, and why it exists

`tests/run.sh` does not keep its own list of suites. It reads
`tests/registry.tsv`, which declares every suite as
`lane | path | scope | kind`.

The reason is a specific, already-happened failure. The `agent-operations`
lane landed with its own `run.sh`, that runner was never added to the
top-level list, and so its suites did not run — while the runner still
printed **all checks passed**. A check registered nowhere cannot report that
it was skipped.

So discovery is inverted. Every suite under `tests/` must be reachable — either
registered directly, or inside a directory owned by a registered lane
entry point. One that is not is a **failure**, not an omission. Adding a suite
and forgetting to register it cannot produce a green run.

`tests/check-registry.sh` tests this claim rather than asserting it: it adds a
fixture suite and watches the failure propagate, adds an unregistered suite and
watches the run go red, and asserts that a suite which was skipped is never
reported as one that passed.

### Scopes

| Scope | Meaning | Skippable? |
|---|---|---|
| `fast` | Pure bash/cargo. No nix, no privileges. Seconds. | No |
| `eval` | Evaluates configurations with `nix`. | Only in a sandbox |
| `kvm` | Builds a NixOS system and boots it. | Never in `run.sh` |

**A check that did not run is never reported as a check that passed.**
`NM_REQUIRE_ALL` defaults to `1`: a suite that cannot run fails the run. Set
`NM_REQUIRE_ALL=0` to allow a skip — the skip stays loud and is counted in the
summary, and the summary then says "passed with N declared skip(s)" rather than
claiming an unqualified pass.

## Known failures on master (not introduced by this work)

Both of these fail on a pristine `master` checkout and are **not** fixed here,
because both live in lanes owned by other PRs:

1. **`media-travel`** — `state-restore.sh` cannot find `sqlite3`. The flake
   input is `sqlite`, but in the pinned nixpkgs its `outPath` resolves to the
   main output rather than the `-bin` split, so the binary is neither on PATH
   nor visible to the suite's store scan.
2. **`server-foundation/host-eval.sh`** — 24 assertions fail. `hostPolicy.role`
   evaluates correctly, but `networking.networkmanager.wifi.macAddress` and
   `nix.settings.trusted-users` do not evaluate on this nixpkgs revision.

Both stay registered, so they fail loudly rather than disappearing.

## What is not automated

Manual hardware drills. These are real procedures with no automated form, and
they are listed here so their absence is on the record rather than assumed:

- kernel bump after an NVIDIA driver/library mismatch, and the reboot-free
  staged-boot path in `ns-maint`
- GPU hang recovery (`kill-switch`, kernel-log triage)
- rollback of a bad activation on real hardware

Run these on the machine. CI is not a substitute.

## Continuous integration

`.github/workflows/fast-checks.yml` runs the fast lane on every push and pull
request. Actions are enabled on this repository, so it does run — the earlier
"no CI, because a workflow that never runs is worse than none" note applied to
a repository where that was true, and no longer is.

Every action is pinned to a commit SHA, and every tool comes from the flake's
own locked nixpkgs through `nix build`, so a run today and a run in six months
use the same shellcheck, fish and cargo. `permissions: contents: read`. No
secrets are used or needed.

Host evaluation and the VM test are **excluded from CI on purpose**, and the
workflow says so in its own header: wiring a known-failing suite into CI
produces a permanently red badge, which gets ignored. Those two exclusions are
the ones listed above.

## Per-lane directories

Each in-flight lane owns a directory with its own harness and its own runner, so
every lane is runnable on its own before any of them are merged:

| Directory | Lane | Runner |
|---|---|---|
| `agent-operations/` | agent continuity, credentials, backups, health | `bash nixos/tests/agent-operations/run.sh` |

The `backup-restore.sh` suite creates a REAL disposable restic repository and
restores from it. It needs `restic` and `sqlite3`, which are in the flake
check's closure; a bare developer shell without them gets a clear SKIP rather
than a silent pass.

`agent-lifetime.sh` evaluates Nix. `nix build .#checks.x86_64-linux.agent-operations`
supplies the Legion unit facts as a file; a standalone run evaluates them
itself, and fails loudly if it cannot.

## What each suite is for

| File | What it proves |
|---|---|
| `lib/harness.sh` | The shared foundation: disposable fixtures, fake `nix`/`nix-store`/`nix-env`/`systemctl`/`systemd-run`/`journalctl`, and assertions. |
| `ns-maint-transaction.sh` | The maintenance transaction's phases, under injected failure. |
| `kill-switch-targets.sh` | What a kill sweep is allowed to target, and what it must never target. |
| `disk-cleanup-safety.sh` | What the cleanup script refuses to delete. |
| `run.sh` | The single entry point the flake check runs. |
| `agent-operations/` | The agent-operations lane: its own harness (`lib/fixture.sh`), five suites and its own runner. See above. |
| `maintenance-vm.nix` | That the above holds on a real, booted, systemd-managed NixOS system. |

### The server-foundation lane

`tests/server-foundation/` is one lane's own scope: the server/travel role, the
local boot-health gate, tailscale convergence, and the maintenance
new-connection check. Each suite also runs standalone, which is the point — none
of them needs this runner, and none of them needs another lane's future files.

| File                             | What it proves                                                                    | Needs `nix` |
| -------------------------------- | --------------------------------------------------------------------------------- | ----------- |
| `role-policy.sh`                 | Role resolution, the refusals, host-scoped private overrides, the DNS owner/cap    | yes (`nix eval --file`, no store, no network) |
| `boot-health.sh`                 | The local boot gate passes offline, and refuses for each local reason               | no          |
| `tailscale-reconcile.sh`         | Offline boot → later internet return, with no login, no reset, no reboot            | no          |
| `ssh-confirm.sh`                 | The NEW-session check over both 22 and 2222, and the tailnet-peer explanation      | no          |
| `host-eval.sh`                   | The real flake outputs for both hosts and both variants, plus role combinations      | yes, and a store with the inputs |

`host-eval.sh` is the one that cannot run inside a `checks` sandbox: it evaluates
four real flake configurations, and an evaluation inside a build cannot reach the
flake's inputs. The flake check therefore sets `NM_SKIP_HOST_EVAL=1` and
`NM_REQUIRE_ALL=0`, which makes `run.sh` print the skip loudly instead of
pretending the suite passed. Outside a sandbox it runs, and it fails the run if it
fails.

```console
bash nixos/tests/server-foundation/host-eval.sh    # ~15s
```

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

## media-travel (this lane)

`bash nixos/tests/media-travel/run.sh` — or
`nix build .#checks.x86_64-linux.media-travel`.

Five suites, each runnable on its own:

| Suite | Needs | Covers |
|---|---|---|
| `netns-failclosed.sh` | nothing | the shipped `netns-up.sh`, via stubbed `ip`/`iptables` |
| `state-restore.sh` | sqlite3 | export, corrupt-database refusal, restore verification |
| `selective-sync.sh` | nothing | the shipped ignore rules against a fixture tree |
| `travel-builder.sh` | nothing | `herdr-travel` against a fake herdr |
| `host-isolation.sh` | `nix` | both hosts evaluated |

`NM_SKIP_MEDIA_HOST_EVAL=1` skips `host-isolation.sh` (which cannot evaluate
flake inputs inside a build sandbox) and says so loudly; `NM_REQUIRE_ALL=0`
allows that skip. Outside a sandbox the skip is an error, so "the suite that
evaluates the hosts did not run" cannot be a green result.

### Two things worth knowing before extending it

- **`fake_root_bin` must be called, not captured.** It exports `FAKE_LOG`, and
  `STUBS="$(fake_root_bin …)"` runs in a subshell where the export is lost —
  which then fails under `set -u` and reads as a broken suite rather than a
  fixture mistake.
- **`netns-failclosed.sh` tests the shipped script, not a copy.** It asserts on
  the netfilter calls `netns-up.sh` actually makes. Grepping the source for
  `DROP` would prove a word is in a file, not that the rules are right.

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
## The dev-ports dashboard (`sys-daemon serve`)

Binds `127.0.0.1:3333` and exposes one mutating endpoint, `POST /api/kill`.

A loopback bind stops other *machines* connecting. It stops nothing on this
one: every local process can reach it, and so can the user's browser, because a
page the browser loads runs with the user's privileges and can issue requests
to loopback addresses. Two shapes turn that into "any page the user visits can
terminate processes":

- **DNS rebinding.** Attacker DNS returns `127.0.0.1` for `evil.example`. The
  browser now believes it is talking to `evil.example`, sends
  `Host: evil.example`, and nothing about the request looks cross-origin — so
  browser-side protections do not engage. The defence is validating `Host`
  against the authorities actually served. This is the load-bearing check.
- **CSRF.** A page on any origin can POST to the dashboard. Defended by an
  exact-match `Origin` check and a per-run token minted from `/dev/urandom`,
  delivered only over a request that already passed the `Host` check.

Reads (`/`, `/api/status`, `/api/stream`) are held to the `Host` rule alone —
they expose the project and port map, but cannot change anything, and requiring
a token for them would break `curl` on the command line.

`POST /api/kill` additionally validates, in `killsafe.rs`:

- **UID** — only processes owned by the daemon's own user are signalled.
- **Identity** — a pidfd opened at *discovery* time, so PID reuse cannot
  redirect the signal. Opening it at signal time would look like the same
  protection and would not be: a pidfd opened after a reuse pins whatever now
  holds the number. Where the kernel has no pidfd, a start-time comparison is
  the fallback, and the result reports which path was used rather than
  presenting them as equivalent.
- **Protected targets** — the dashboard's own port (tracked by identity, so it
  stays protected if moved), sshd, tailscaled's ports, and the herdr / collie /
  moshi-hook / sys-daemon process names. A refusal is all-or-nothing: if one
  process on a port is protected, nothing on that port is killed.

`tests/api_negative.rs`, `tests/kill_safety.rs` and `tests/config_metadata.rs`
cover this. They drive the pure decision functions and disposable child
processes, so they never bind a port, never signal a process they did not
spawn, and never talk to a running daemon. The kill-safety suite is
deliberately single-threaded and capped with `ulimit -v`, so that a runaway
allocation in test code aborts one process instead of triggering the kernel OOM
killer on the host.
