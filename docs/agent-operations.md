# Agent operations — continuity, credentials, backups, health

Everything this document describes is **opt-in and off by default**. That is
deliberate and it is the single most important thing to know before you enable
any of it: an unattended machine with no backup configured is a real and common
state, and hiding it behind a host role is how you end up with a box that has
silently never been backed up.

What *is* always on, because it is a correctness fix rather than a new feature:

* the agent **boot-lifetime rule** (`config/home/agent-lifetime.nix`);
* **credential delivery** — values as data, no eval, no global import;
* the **herdr-daemon health report** and the **opt-in resume unit**.

---

## 1. Agent boot lifetime

```
AGENT BOOT LIFETIME = opts.headless  OR  opts.mobileAgents.enable
```

| `headless` | `mobileAgents.enable` | `WantedBy` | Orders behind a graphical session? |
|---|---|---|---|
| false | false | `graphical-session.target` | yes |
| false | **true** | `default.target` | no |
| **true** | false | `default.target` | no |
| true | true | `default.target` | no |

The rule used to be `mobileAgents.enable` alone, which made agent continuity a
property of owning a phone. A headless server nobody reaches from a phone is
still an unattended server.

### The half that is NOT in this PR

`WantedBy=default.target` makes the unit reachable at boot. Whether the **user
manager itself** starts without a login is `linger`, which is SYSTEM policy and
belongs to `config/system/mobile-agents.nix` (lane A).

> **PENDING until lane A merges.** The combined
> `headless = true` + `mobileAgents.enable = false` startup drill has NOT been
> run. This PR is evaluated and unit-tested for that combination; it has not been
> booted. Do not treat "the agents come up at boot" as verified until A has
> landed and the drill below has been executed.

### The drill to run after A merges

```console
# 1. headless server, no phone: agents must come up at boot, with nobody logged in.
$ sudo sed -i 's/^  headless = false;/  headless = true;/' nixos/hosts/legion/options.nix
$ sudo nix switch   # or: sudo ns-maint prepare && sudo ns-maint activate
# 2. Log out everywhere. No login. From your phone over Collie or SSH 2222:
systemctl --user status herdr.service          # expect: active (running)
systemctl --user status herdr-resume.service   # expect: either exited(0) or not-run
ls /run/user/$(id -u)/herdr                    # the socket exists
~/.config/agent-ops/secret-env --check         # expect: ready, or a named absence
# 3. Serve compatibility: the tailnet HTTPS 443 mapping must be unchanged.
tailscale serve status                         # expect: 443 still pointed at collie
```

### What is given up, on purpose

At cold boot the server has no `WAYLAND_DISPLAY` and no session `DBUS` address,
because nothing has run mango's autostart. Agents started before login cannot
`wl-copy` or `xdg-open`. That is inherent to "reachable when nobody is at the
desk".

---

## 2. Credentials

### The three delivery paths, and only these

| Path | How | Scope |
|---|---|---|
| **On demand** (default) | `ns-secrets run <cmd>` | one process |
| **Systemd credential** | `LoadCredential=NAME:path` | that service and its children |
| **Explicit session scope** | `ns-secrets` | the current interactive shell |

```console
ns-secrets check                 # readiness; names and booleans only
ns-secrets                       # load ready credentials into this shell
ns-secrets run pi                # run ONE command with them, scoped
~/.config/agent-ops/secret-env --exec curl https://api.example.com
```

### What was removed, and why it was wrong

The `secrets-env` sops **template** (`export NAME="value"`) and the
`sops-import-environment` unit are gone, along with the `$(cat /run/secrets/X)`
entries in `home.sessionVariables` and the broken fish parser.

Concretely, each of those was a way for a value to become code or to reach the
wrong process:

* **a value containing `"` ended the quoting** and the remainder was parsed as
  shell; a value containing `$(…)` or a backtick was **executed**;
* **a multiline value could not survive** — the template was line-oriented, and
  `$(cat …)` in `profile.d` was a syntax error;
* **`systemctl --user import-environment`** put every credential into the
  environment of *every* process in the user session;
* **neither ran when there was nobody logging in**, which with `linger` is the
  normal state of this machine — so the mechanism meant to supply the agents'
  credentials could not run there at all;
* the fish parser's pattern was `'^export\s+([^=]+)=(.*)\$'` — `\$` is a literal
  dollar, so it demanded that every secret line **end with a `$`** and matched
  essentially nothing.

### Newline and NUL semantics

`secret-env.sh` reads bytes and hands them to `execve`. There is no code path in
which a value is parsed.

* A value is the file's bytes with **at most one trailing newline** removed.
* **Embedded newlines are preserved.** A PEM key is three lines; it round-trips.
* A **NUL byte is rejected** (exit 4). `execve` cannot represent one, and
  truncating at it would hand a caller half a secret.
* Leading/trailing whitespace other than that one newline is **not** stripped.

### Anthropic OAuth precedence

`ANTHROPIC_API_KEY` is `sessionVariable = false` and stays that way. When a
Claude Agent SDK client finds it in its environment it bills a $0-credit console
account **instead of** using the Pro OAuth token — silently: the requests
succeed, the console balance does not move. It is excluded from every ambient
path and reachable only by asking for it by name.

### `herdr.agentCredentials.enable` — leave it off unless you test it

Hands the session credentials to `herdr.service` via `LoadCredential=`.
**Default: false.** `LoadCredential` is mandatory: if sops-nix has not decrypted,
the herdr unit fails to start and the machine loses every agent it has. Trading
"the agents start blind" for "the agents do not start" on an unattended box is
the worse of the two. Turn it on only after
`systemctl --user status sops-nix` has been observed to succeed on every boot.

---

## 3. The herdr daemon closure

`herdr.service` resolves its binary through `/etc/profiles/per-user/%u` rather
than a pinned store path, **on purpose**: pinning it would change the unit text
on every version bump, home-manager would restart the service, and restarting
the server kills every live agent pane.

The cost is that the store path the live server is executing is referenced by
nothing a garbage collector can see — not `/run/current-system`, not the booted
closure, not any generation. **`ns-maint`'s running-system roots therefore prove
nothing about it.**

```console
ns-agent-daemon-roots list      # what is pinned, and where it points
ns-agent-daemon-roots verify    # every pinned closure still resolves
ns-agent-daemon-roots pin       # re-pin from the RUNNING /proc/PID/exe
ns-agent-daemon-roots gc-check  # collector dry run, then verify
```

> **Known gap.** `ns-maint roots` globs `ns-maint-*` and therefore will **not**
> list these. `ns-agent-daemon-roots.sh list` is the complete answer. Widening
> that glob is a one-word change in a file lane A owns; this lane does not touch
> it.

The roots go in the **same** gcroots directory with an `ns-ops-` prefix, so
`nix-store --gc` — including the one `ns-maint gc` runs — honours them with no
cooperation. They exist whether or not a maintenance transaction does.

---

## 4. Resume

herdr restores panes but **not their commands** (`session.json` has no command
field), so after a restart every pane is a bare shell.

```console
~/.config/agent-ops/herdr-resume --dry-run      # what would be launched
~/.config/agent-ops/herdr-daemon-check          # who owns the server; CLI vs server
systemctl --user status herdr-resume.service
```

**Nothing happens until you opt in.** Put one repository root per line in
`~/.config/agent-ops/resume-roots`, and in each root a `.agent-ops-resume`:

```
NAME|RUNNER|HEARTBEAT_FILE
```

`RUNNER` must be an **absolute path** and is executed directly — never through a
shell. `HEARTBEAT_FILE`'s mtime is the liveness signal.

It will not launch anything when:

* the herdr server is not running (exit 5);
* the runner is not executable or is relative (exit 3 / 2);
* another resume holds the lock for that root (exit 4 — refusal, not duplicate);
* a recorded pid is alive but its **start time** differs (pid reuse);
* a fresh heartbeat exists with no recorded pid (someone else owns it);
* a task exits, or writes no heartbeat, inside the start window (it is stopped
  again rather than left orphaned).

Exit 1 means a task failed. It is **not** success, and the unit says so.

---

## 5. What is worth keeping

`nixos/config/system/agent-ops/state-manifest.nix` is the reviewed inventory,
also rendered to `/etc/agent-ops/state-manifest.txt` on the host. Paths you would
not have thought of, and why they matter:

| Path | Why |
|---|---|
| `~/.config/herdr` | without `session.json` a restore has no workspaces at all |
| `~/.local/state/collie` | the pairing a phone is trusted by |
| `~/.config/collie/.env` | the VAPID keypair; lose it and push notifications stop |
| `~/.config/sops/age/keys.txt` | **the identity that decrypts every other secret**, and not itself a sops secret |
| `~/Development/Projects` | restic archives what is on disk; a dirty index is not recoverable from git objects |
| `/var/lib/nixos/maintenance` | **excluded**: an armed record carried onto another host would arm a deadline for a change that never happened |

`environment.persistence` is still **off**, and this lane does not turn it on.
The manifest is the corrected list that decision should be made against later.

---

## 6. Backup

```console
sudo agent-ops-backup.service       # or: sudo ns-agent-backup backup
ns-agent-backup check                # repository integrity + snapshot age
ns-agent-backup status               # last run, and whether it counts as healthy
sudo ns-agent-backup restore --to /var/tmp/restore-test
sudo ns-agent-backup prune           # forget only; `--prune` is manual and separate
```

Enabling (`agentOps.backup.enable`) requires two sops secrets that do not exist
in this repository yet:

```console
sops secrets set RESTIC_REPOSITORY --name nixos/secrets.yaml   # e.g. s3:https://… or rest:https://…
sops secrets set RESTIC_PASSWORD   --name nixos/secrets.yaml
```

Properties:

* **Runtime credentials only.** The repository and password arrive as systemd
  credentials when the timer fires. Nothing is in the Nix store.
* **Missing credentials is exit 4, `NOT CONFIGURED`.** `ns-agent-health`
  reports backup as `unconfigured`, which is a **PROBLEM**. "Backup is off" must
  never look like "backup is fine".
* **Bounded**: niced, idle IO, `--limit-upload` (8 MB/s by default, because this
  host's uplink is the tailnet it is reachable over), `--limit-download`,
  `--pack-size`, and a bounded number of retries with backoff.
* **Databases are exported, not copied.** Anything in `quiesce` is exported with
  SQLite's own online backup API and the export is verified with
  `integrity_check`. `cp` of a file being written produces something that can
  pass `integrity_check` and still be torn. A busy database is retried; if it
  still cannot be exported the backup **fails** rather than shipping the raw file.
* **Excludes are named decisions**: `/nix/store` (re-downloadable by hash),
  runtime sockets, caches, agent logs. No blanket patterns.
* **Restore is scratch-only.** `--restore-to` refuses `/`, any relative path, a
  non-empty directory, and anything under `$HOME`.
* `forget` and `prune` are separate: the timer runs `forget` only.

### Offline recovery procedure

A restic repository cannot be read without its password, and this host cannot be
reached without a network. **Before you leave**, confirm:

1. **You can reach the restic password without this machine.** It lives in
   `nixos/secrets.yaml`, which is encrypted to your age identity. That identity's
   private key lives at `~/.config/sops/age/keys.txt` **on this machine only**.
   If that file exists nowhere else, a dead host means a dead repository.
   Copy the age identity (or the `secrets.yaml` file) to a second machine, and
   store the restic password with it.
2. **You have the repository URL**, not just a habit of knowing it.
3. **You have restored from it at least once, from a different machine.**

```console
# On any other machine with the password:
export RESTIC_REPOSITORY='<url>' RESTIC_PASSWORD='<password>'
restic snapshots
restic check --read-data-subset=1/100
restic restore latest --target /tmp/verify
```

The `agent-ops-backup-verify` timer restores into `/var/tmp` monthly so the
repository is not a hypothesis — but it runs on this machine, which is exactly
the machine that may be gone.

---

## 7. Health

```console
ns-agent-health            # human
ns-agent-health --json     # machine
```

Reports: stateful service states, **credential readiness booleans** (never
values), backup age, disk and inodes, thermals/AC, failed units, the ns-maint
phase and txid, and herdr daemon ownership/CLI compatibility.

* **Redaction is asserted, not promised.** The test suite plants a recognisable
  canary in every credential store and greps every output for it.
* **Bounded**: every collector has its own deadline, and a hung one costs its
  own field and nothing else.
* **No recipient is inferred.** The outside heartbeat fires only when you
  configure `AGENT_OPS_HEARTBEAT_URL` **and** `AGENT_OPS_HEARTBEAT_TOKEN` in
  `secrets.yaml`. There is no default endpoint and no signup of anything; with
  none configured the field reads `unconfigured`, which is a true answer and not
  a warning. A non-`https` endpoint is refused.
* **No automatic reboot, ever.** An ISP outage makes every network check fail at
  once; rebooting is always wrong. There is no reboot path in the script or in
  any `agent-ops` module, and `health-redaction.sh` asserts that.

---

## 8. Calibrating the resource policy

`agentOps.resources` applies per-workload cgroup weights: `agent`, `build`,
`inference`, `transcode`, `download`, and `management` — which is **not**
limited and is never a kill target. Bounded, never killed; `ns-maint`'s
kill-switch remains a separate, kill-shaped tool.

> **The numbers in `resources.nix` are DEFAULTS, NOT MEASUREMENTS.** They have
> not been calibrated against a load test on this hardware. They are chosen so
> that a mistake costs throughput rather than availability.

Before raising or lowering any of them:

```console
# 1. Baseline with nothing else running.
systemd-cgtop --batch --iterations=10
# 2. Start the workload you care about bounding (a nix build, an ollama load,
#    a transcode) and watch whether management latency moves.
# 3. Record what you measured, change ONE weight, repeat.
```

Adjust `agentOps.resources.policy.<class>.{cpuWeight,ioWeight,ioLatencyTargetSec}`
and `agentOps.resources.admission.*` — per class, not globally. A single cap on
every agent would throttle the one urgent build in the same slice as the idle
inference, and neither would get what it needed.

---

## 9. What is NOT done here

* **`environment.persistence` is still off.** The manifest is ready; the
  decision is not made.
* **Backup and health default to off.** Enable them deliberately.
* **No media-state backup hook.** `agentOps.backup.heartbeatHook` is a declared
  seam for lane C and it **fails the build** if enabled: C owns the media state
  layout and this lane will not guess at it.
* **`ns-maint` is untouched** — not its transaction format, not its phases, not
  its roots globbing.
* **No lane A, C or D files were edited** beyond the shared import list in
  `config/system/default.nix` and the additive check registration in
  `flake.nix`.