# PRs 1–8: corrective audit

This follow-up fixes the consolidated prompts' implementation, not just their
wording. Optional media, backup, health and resource features remain opt-in.
No deployment, real credentials, live backup, real garbage collection or reboot
is part of the source audit.

## Corrected boundaries

- Maintenance uses the real configured flake output, trusted compiled defaults,
  explicit privilege gates, and validated duration/environment fields. Runtime
  recovery A, selected-profile/boot intent B, and previously booted C remain
  distinct. B is derived from constrained immutable generation references and
  transaction anchors, not added to the version-1 wire schema. Unknown or
  conflicting intent cannot become a successful rollback. Inconclusive ESP
  capacity refuses staging; interrupted staging remains explicit. GC collects
  only: all generation links stay and `--keep` is rejected.
- Role, DNS, SSH, boot-health and daemon-root checks distinguish package/profile
  configuration from loaded kernel and running process identity. A failed
  collector dry run cannot claim retention verification.
- Agent credentials are data, loaded only into selected consuming children.
  Existing herdr server/client/pane environments are not refilled or restarted.
  Absent optional API keys permit native stored-auth/local flows; malformed
  selected values fail before spawning. Resume requires current-boot, non-zombie
  PID/start-time identity, not a heartbeat alone.
- Backups parse module JSON rather than CSV, preserve core/operator inventory
  when media adds export sources, and quiesce the application before publishing
  a recoverable export tree. Retention identifies this host's dated snapshots;
  restic rate limits use the correct units. Restore targets are canonical empty
  scratch locations, never live home paths. Unsupported IO-concurrency claims
  are removed.
- Health runs owner-context checks without executing user-writable helpers as
  root. Redacted reports are separate private, atomically published files with
  effective age retention. Workload weights are assigned to real services;
  admission targets and interactive-agent calibration remain explicitly
  **unapplied**, not a claimed concurrency or protection mechanism.
- Torrent WireGuard sockets are host-born; the client resides in a default-DROP
  namespace. There is no host NAT, forwarding or global OUTPUT-policy change.
  A dedicated-UID loopback token proxy authenticates before connecting, direct
  backend access by other host UIDs is rejected, and tunnel WebUI ingress is
  rejected. These are filter/unit/source assertions, not kernel packet proof.
- Jellyfin pins native loopback/HTTP-port fields while preserving unrelated XML.
  Publication requires both operator opt-in and actual native setup completion;
  helpers do not change users or authentication/setup state. Selective sync
  excludes private identities and actual live herdr roots, their ancestors and
  descendants. Offline preparation refuses source/destination traversal.

## Validation contract

The required gates for this follow-up are the full `nixos/tests/run.sh` registry,
all four named check closures (`maintenance-contracts`, `agent-operations`,
`media-travel`, `repo-contracts`), enabled feature/module fixtures, and derivation
evaluation of `legion`, `gs65` and both fast variants. Exact results are recorded
in the PR after the final integrated run, rather than treating an earlier run
or an interrupted worker as current validation.

The Git-less Nix sandbox checks the legacy maintenance wire contract; the direct
repository suite additionally exercises the actual pre-fix HEAD reader without
activation. Full host evaluations run outside the nested build sandbox. Pure
fixtures use temporary data, fake management/network commands and disposable
restic repositories only. In the Nix user namespace, restic restores the `/tmp`
snapshot subtree through a test-only shim: all fixture payload and its metadata
are restored, but the synthetic ancestor `/tmp` has an unmapped owner and its
ownership is outside that sandbox proof. Production restore is not altered or
allowed to ignore ownership errors.

## Verified final results

- Full registry: all nine registered groups passed, including ShellCheck baseline,
  Bash/fish syntax, Nix parsing, enabled fixtures and 65 Rust tests.
- All four named Nix check outputs built successfully in the sandbox.
- All four public-source host toplevel derivation paths evaluated successfully.
- Targeted totals: maintenance 66 fixture groups; scoped credential data 85;
  daemon roots 45; resume 93; health redaction 105; history retention 107;
  backup/restore 169; media state 21; selective sync 26; travel transport 12;
  host isolation/privacy 24.

These results include the final integrated fixes, not just worker baselines.

## Before unattended enablement

Source tests and derivation evaluation do **not** establish deployment safety.
Still require disposable cross-generation/systemd rollback testing, actual
qBittorrent/Qt and Jellyfin listener checks, kernel packet-flow and tunnel-loss
acceptance, boot-entry/default/counting and ESP checks, storage/backup restore
rehearsal, and calibrated contention/load tests. Provision credentials, trusted
peer IDs, SSH host-key pins, administrator setup and external heartbeat endpoints
separately. Keep features disabled until these operator acceptance gates pass.

Only pi/Claude managed launch paths currently use the scoped child loader; other
agent kinds require explicit opt-in. Reload already-loaded fish functions after
deploying their definitions. Existing legacy health JSONL history is not migrated
or deleted automatically.
