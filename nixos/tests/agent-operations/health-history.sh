#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016
# nixos/tests/agent-operations/health-history.sh
#
# The health history is one private, immutable file per run, aged by
# systemd-tmpfiles on its own mtime. This suite evaluates health.nix with stub
# pkgs (public metadata only — no secrets, no heartbeat), extracts the two
# GENERATED wrappers (timer and boot), and executes them against a fake
# collector in a temp history directory. Nothing touches /var, /proc, a real
# unit, a real credential or a real endpoint.
#
# Nested `nix eval` needs <nixpkgs> (or AGENT_OPS_NIXPKGS=/path/to/nixpkgs).
# Inside a sandboxed flake check that may be unavailable; the flake can instead
# hand over precomputed metadata via AGENT_OPS_HEALTH_METADATA (the JSON this
# file's metadata.nix produces). Missing both is a FAILURE, not a skip.
set -o nounset -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"
SUITE_NAME=health-history
fixture_new

if [[ -n "${AGENT_OPS_NIXPKGS:-}" ]]; then
	NIXPKGS_LIB="import $AGENT_OPS_NIXPKGS/lib"
else
	NIXPKGS_LIB='import <nixpkgs/lib>'
fi

# Unquoted heredoc: only $LANE_SRC and $NIXPKGS_LIB are shell-expanded; every
# Nix interpolation is escaped as \${...}.
cat >"$TMP/metadata.nix" <<EOF
let
  lib = $NIXPKGS_LIB;
  package = { type = "derivation"; outPath = "/fixture"; name = "ns-agent-health"; meta.mainProgram = "ns-agent-health"; };
  pkgs = builtins.listToAttrs (map (name: { inherit name; value = "/fixture"; })
    [ "bash" "coreutils" "findutils" "gawk" "gnugrep" "systemd" "util-linux" "curl" "hostname" "jq" ]) // {
    writeShellScript = name: text: text;
    writeShellApplication = args: package;
  };
  evaluate = stateDir: retentionHours: (lib.evalModules {
    specialArgs = { inherit pkgs; opts.username = "fixture-owner"; };
    modules = [
      $LANE_SRC/config/system/agent-ops/health.nix
      ({ lib, ... }: {
        options = {
          agentOps.backup.stateDir = lib.mkOption { type = lib.types.str; };
          users.users = lib.mkOption { type = lib.types.attrs; };
          environment = lib.mkOption { type = lib.types.attrs; };
          systemd = lib.mkOption { type = lib.types.attrs; };
          sops = lib.mkOption { type = lib.types.attrs; };
          assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
        };
        config = {
          agentOps.health = { enable = true; inherit retentionHours; };
          agentOps.backup = { inherit stateDir; };
          users.users.fixture-owner.home = "/fixture-home";
        };
      })
    ];
  }).config;
  metadata = config: {
    rules = config.systemd.tmpfiles.rules;
    globalRecord = config.environment.variables.AGENT_OPS_BACKUP_RECORD;
    services = lib.genAttrs [ "agent-ops-health" "agent-ops-health-record" ] (name: {
      inherit (config.systemd.services.\${name}.serviceConfig) ExecStart MemoryMax User SuccessExitStatus;
      record = config.systemd.services.\${name}.environment.AGENT_OPS_BACKUP_RECORD;
    });
    heartbeat = config.agentOps.health.heartbeat.enable;
    secrets = builtins.attrNames config.sops.secrets;
  };
in { default = metadata (evaluate "/var/lib/agent-ops/backup" 24);
     custom = metadata (evaluate "/fixture-custom-backup" 2); }
EOF

META="$TMP/metadata.json"
_t_start "module metadata is available"
if [[ -n "${AGENT_OPS_HEALTH_METADATA:-}" && -r "${AGENT_OPS_HEALTH_METADATA}" ]]; then
	cp "$AGENT_OPS_HEALTH_METADATA" "$META"
	printf '    (metadata provided by AGENT_OPS_HEALTH_METADATA)\n'
elif ! nix --extra-experimental-features 'nix-command flakes' eval --impure --json \
	--file "$TMP/metadata.nix" >"$META" 2>"$TMP/eval.err"; then
	printf '    nix eval failed: %s\n' "$(tr '\n' '|' <"$TMP/eval.err")" >&2
	: >"$META"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if jq -e '.default and .custom' "$META" >/dev/null 2>&1; then
	_ok 'health.nix evaluated with stub pkgs'
else
	_fail 'health.nix metadata could not be evaluated (set AGENT_OPS_NIXPKGS or AGENT_OPS_HEALTH_METADATA)'
	summary
	exit 1
fi

_t_start "backup record follows agentOps.backup.stateDir"
# ns-agent-backup.sh: RECORD="$STATE_DIR/last-run.env" — no extra /backup.
assert_eq /var/lib/agent-ops/backup/last-run.env "$(jq -r '.default.globalRecord' "$META")" 'default record layout matches backup script'
assert_eq /fixture-custom-backup/last-run.env "$(jq -r '.custom.globalRecord' "$META")" 'custom state directory controls the global record'
assert_eq false "$(jq -r '.custom.heartbeat' "$META")" 'heartbeat stays disabled'
assert_eq '[]' "$(jq -c '.custom.secrets' "$META")" 'no credentials requested'

# ── fake collector ──────────────────────────────────────────────────────────
# FAKE_HEALTH_MODE: healthy | degraded | malformed | empty | two
cat >"$TMP/collector" <<EOF
#!$(command -v bash)
printf 'call %s\n' "\$*" >>"$TMP/calls"
case "\${FAKE_HEALTH_MODE:-healthy}" in
healthy) printf '%s\n' '{"overall":"healthy","at":"fixture"}' ;;
degraded) printf '%s\n' '{"overall":"degraded","at":"fixture"}' ;;
malformed) printf '%s\n' '{"overall":"healthy",' ;;
empty) : ;;
two) printf '%s\n' '{"overall":"healthy"}' '{"overall":"healthy"}' ;;
esac
exit "\${FAKE_HEALTH_STATUS:-0}"
EOF
chmod +x "$TMP/collector"
export FAKE_HEALTH_MODE FAKE_HEALTH_STATUS

# extract_wrapper UNIT DEST — the generated ExecStart, with only executable
# store paths and the history directory re-pointed into the fixture.
extract_wrapper() {
	jq -r --arg unit "$1" '.custom.services[$unit].ExecStart' "$META" >"$2"
	python3 - "$2" "$TMP" <<'PY'
import pathlib, re, shutil, sys
path, temporary = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text().replace('/fixture/bin/ns-agent-health', temporary + '/collector')
def tool(match):
    found = shutil.which(match.group(1))
    if not found:
        sys.exit('missing tool: ' + match.group(1))
    return found
text = re.sub(r'/fixture/bin/([A-Za-z0-9_.-]+)', tool, text)
path.write_text(text.replace('/var/lib/agent-ops/health/history', temporary + '/history'))
PY
}

# run_wrapper WRAPPER MODE STATUS — sets RC, writes stdout/stderr files.
run_wrapper() {
	FAKE_HEALTH_MODE=$2 FAKE_HEALTH_STATUS=$3
	RC=0
	bash "$1" >"$TMP/stdout" 2>"$TMP/stderr" || RC=$?
}

count_reports() { find "$TMP/history" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' '; }

mkdir -m 700 "$TMP/history"
for unit in agent-ops-health agent-ops-health-record; do
	_t_start "$unit: generated wrapper"
	assert_eq 128M "$(jq -r --arg u "$unit" '.custom.services[$u].MemoryMax' "$META")" 'memory bounded to 128M'
	assert_eq root "$(jq -r --arg u "$unit" '.custom.services[$u].User' "$META")" 'runs as root'
	assert_eq '0 1' "$(jq -r --arg u "$unit" '.custom.services[$u].SuccessExitStatus' "$META")" 'health verdicts are not unit failures'
	assert_eq /fixture-custom-backup/last-run.env "$(jq -r --arg u "$unit" '.custom.services[$u].record' "$META")" 'service env uses the custom backup record'
	exec_start="$(jq -r --arg u "$unit" '.custom.services[$u].ExecStart' "$META")"
	assert_not_contains "$exec_start" '>>' 'no append-only history file'
	assert_not_contains "$exec_start" 'history.jsonl' 'no perpetual jsonl log'
	wrapper="$TMP/$unit.wrapper"
	extract_wrapper "$unit" "$wrapper" || _fail 'wrapper tools resolvable'
	TESTS_RUN=$((TESTS_RUN + 1))
	if bash -n "$wrapper"; then _ok 'wrapper is valid bash'; else _fail 'wrapper is valid bash'; fi
	if [[ "$unit" == agent-ops-health-record ]]; then
		assert_contains "$exec_start" '--json --no-heartbeat' 'boot record never sends a heartbeat'
	fi

	for case_ in healthy:0 degraded:1; do
		mode=${case_%%:*} status=${case_#*:}
		before=$(count_reports)
		: >"$TMP/calls"
		run_wrapper "$wrapper" "$mode" "$status"
		assert_eq "$status" "$RC" "$mode: collector status $status preserved"
		assert_eq '' "$(<"$TMP/stdout")" "$mode: report never goes to stdout/journal"
		assert_eq 1 "$(grep -c . "$TMP/calls")" "$mode: collector called exactly once"
		assert_eq "$((before + 1))" "$(count_reports)" "$mode: exactly one new report"
		newest="$(find "$TMP/history" -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)"
		assert_eq "$mode" "$(jq -r .overall "$newest")" "$mode: report is the collector's JSON"
		sleep 0.01
	done

	# Same-second runs must never collide or overwrite.
	before=$(count_reports)
	for _ in 1 2 3; do run_wrapper "$wrapper" healthy 0; done
	assert_eq "$((before + 3))" "$(count_reports)" 'same-second runs produce distinct files'

	for case_ in malformed:0 malformed:1 empty:0 two:1; do
		mode=${case_%%:*} status=${case_#*:}
		before=$(count_reports)
		run_wrapper "$wrapper" "$mode" "$status"
		assert_eq 65 "$RC" "$mode (exit $status): malformed output is a unit failure"
		assert_eq "$before" "$(count_reports)" "$mode (exit $status): nothing recorded"
		assert_not_contains "$(<"$TMP/stderr")" '"overall"' "$mode: malformed output is not echoed"
	done
	before=$(count_reports)
	run_wrapper "$wrapper" empty 4
	assert_eq 4 "$RC" 'collector failure status (>1) propagated'
	assert_eq "$before" "$(count_reports)" 'failed collector without JSON records nothing'
	assert_eq 0 "$(find "$TMP/history" -maxdepth 1 -name '.*' -type f | wc -l | tr -d ' ')" 'no partial files left behind'
done

_t_start "reports are private, uniquely named and valid JSON"
for report in "$TMP/history"/*.json; do
	name=${report##*/}
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z\.[A-Za-z0-9]{8}\.json$ ]]; then
		_ok "name $name is <UTC timestamp>.<random>.json"
	else
		_fail "unexpected report name $name"
	fi
	assert_eq 600 "$(stat -c %a "$report")" 'report is mode 0600'
	TESTS_RUN=$((TESTS_RUN + 1))
	if jq -e 'type == "object"' "$report" >/dev/null 2>&1; then _ok 'report is one JSON object'; else _fail "$name is not valid JSON"; fi
done

_t_start "tmpfiles ages snapshots individually by configured retention"
assert_contains "$(jq -r '.custom.rules[]' "$META")" '/var/lib/agent-ops/health/history 0700 root root m:2h' 'custom retention applies to the history directory'
assert_contains "$(jq -r '.default.rules[]' "$META")" '/var/lib/agent-ops/health/history 0700 root root m:24h' 'default retention is 24 hours'
assert_contains "$(jq -r '.default.rules[]' "$META")" '/var/lib/agent-ops/health 0700 root root -' 'parent directory itself is never aged'
if command -v systemd-tmpfiles >/dev/null 2>&1; then
	root="$TMP/root/var/lib/agent-ops/health/history"
	mkdir -p "$root"
	cp -p "$TMP/history/"*.json "$root/"
	total=$(find "$root" -type f | wc -l | tr -d ' ')
	old="$(find "$root" -type f | head -1)"
	touch -d '3 hours ago' "$old"
	jq -r '.custom.rules[] | select(contains("/history "))' "$META" >"$TMP/tmpfiles.conf"
	systemd-tmpfiles --clean --root="$TMP/root" "$TMP/tmpfiles.conf" 2>"$TMP/tmpfiles.err"
	assert_no_file "$old" 'a report older than retention expires despite fresh siblings'
	assert_eq "$((total - 1))" "$(find "$root" -type f | wc -l | tr -d ' ')" 'fresh reports survive cleanup'
else
	TESTS_RUN=$((TESTS_RUN + 1))
	_fail 'systemd-tmpfiles is not on PATH (add systemd to the check inputs)'
fi
summary
