#!/usr/bin/env bash
# `FLAKE_DIR` is read by grep below, and the single-quoted nix expressions are
# interpolated by Nix rather than by bash.
# shellcheck disable=SC2034,SC2016
# nixos/tests/agent-operations/agent-lifetime.sh
#
# The agent boot-lifetime rule, over the full (headless × mobileAgents) matrix,
# plus the generated unit for the host this repository actually builds.
#
# Why this evaluates a pure module rather than four NixOS systems:
# config/home/agent-lifetime.nix takes no flake input and imports nothing, so
# `nix eval` over the matrix costs about a second. Evaluating four real NixOS
# configurations would cost minutes and would mostly be measuring the evaluator.
# The generated unit for the REAL host is then checked separately, so the pure
# module cannot pass while the unit it generates is wrong.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"
SUITE_NAME="agent-lifetime"

fixture_new

FLAKE_DIR="$LANE_SRC"
# `--impure` because the lifetime module is read from a path, and the flake read
# needs one. Nothing here reaches the network or substitutes anything.
#
# The expressions go through --file rather than --expr. An --expr string nested
# inside "$( … )" has to escape every quote it contains, and getting that wrong
# produces a bash PARSE error hundreds of lines away from the cause. A file has
# no such rule.
eval_lifetime() {
	local expr="$TMP/lifetime-$1-$2.nix"
	cat >"$expr" <<EOF
let a = import $LIFETIME_NIX;
in {
  lifetime = a.bootLifetime $1 $2;
  wantedBy = a.wantedBy $1 $2;
  target = a.wantedByTarget $1 $2;
  after = a.afterUnits $1 $2;
  needsGraphical = a.needsGraphicalSession $1 $2;
}
EOF
	nix --extra-experimental-features 'nix-command flakes' eval --impure --json --file "$expr" 2>"$TMP/nix-eval.err"
}

# Prints the JSON form of one field, not Python's repr. `['a','b']` and
# `["a","b"]` are the same list and comparing them produces failures that say
# "expected ['default.target'], got [\"default.target\"]" — a formatting
# difference dressed up as a behavioural one.
field() {
	printf '%s' "$1" |
		python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[sys.argv[1]], separators=(",",":")))' 			"$2" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the rule is headless OR mobileAgents — all four combinations"
for h in false true; do
	for m in false true; do
		out="$(eval_lifetime "$h" "$m")"
		want=$([ "$h" = true ] || [ "$m" = true ] && echo true || echo false)
		assert_eq "$want" "$(field "$out" lifetime)" "headless=$h mobile=$m -> lifetime=$want"
		# An empty result here means `nix eval` failed, not that the rule is
		# false. Surface the evaluator's own error rather than four confusing
		# "expected X, got ''" assertions.
		if [[ -z "$out" ]]; then
			printf '    \033[31mnix eval failed:\033[0m %s\n' "$(tr '\n' '|' <"$TMP/nix-eval.err")" >&2
		fi
	done
done

# The two combinations that matter, spelled out, because "all four" hides which
# is which:
#   desktop with no phone access  -> NO boot lifetime (it is a desktop)
#   headless server, no phone     -> boot lifetime (unattended!)
#   desktop + phone               -> boot lifetime (today's Legion)
out="$(eval_lifetime false false)"
assert_eq 'false' "$(field "$out" lifetime)" 'a plain desktop gets no boot lifetime'
assert_eq '["graphical-session.target"]' "$(field "$out" wantedBy)" '  and is WantedBy graphical-session.target'
assert_eq 'true' "$(field "$out" needsGraphical)" '  and does still need a graphical session'

out="$(eval_lifetime true false)"
assert_eq 'true' "$(field "$out" lifetime)" 'headless=true mobile=false DOES get boot lifetime'
assert_eq '["default.target"]' "$(field "$out" wantedBy)" '  WantedBy default.target'
assert_eq 'false' "$(field "$out" needsGraphical)" '  and does not need a graphical session'

out="$(eval_lifetime false true)"
assert_eq 'true' "$(field "$out" lifetime)" 'headless=false mobile=true keeps working'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "graphical-session ordering is REMOVED, not merely optional"
out="$(eval_lifetime false false)"
assert_eq '["graphical-session.target","sops-nix.service"]' "$(field "$out" after)" \
	'a desktop still orders behind the graphical session'
out="$(eval_lifetime true false)"
assert_eq '["sops-nix.service"]' "$(field "$out" after)" \
	'headless=true does NOT, because that target is never pulled in'
out="$(eval_lifetime false true)"
assert_eq '["sops-nix.service"]' "$(field "$out" after)" \
	'mobileAgents=true does not either'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "credential decryption is a dependency in every case"
for h in false true; do
	for m in false true; do
		out="$(eval_lifetime "$h" "$m")"
		assert_contains "$(field "$out" after)" 'sops-nix.service' \
			"headless=$h mobile=$m orders after sops-nix.service"
	done
done

# ═══════════════════════════════════════════════════════════════════════════
_t_start "ownership / CLI / unit conflicts are distinguished, not collapsed"
cat >"$TMP/conflicts.nix" <<EOF
let a = import $LIFETIME_NIX;
in {
  ok   = a.conflicts { daemonOwnership = "systemd"; compatibility = "compatible"; unitState = "ok"; };
  man  = a.conflicts { daemonOwnership = "manual"; compatibility = "compatible"; unitState = "ok"; };
  cli  = a.conflicts { daemonOwnership = "systemd"; compatibility = "cli-newer"; unitState = "ok"; };
  fail = a.conflicts { daemonOwnership = "systemd"; compatibility = "compatible"; unitState = "failed"; };
  all  = a.conflicts { daemonOwnership = "manual"; compatibility = "cli-older"; unitState = "never-started"; };
  readyOk = a.ready { daemonOwnership = "systemd"; compatibility = "compatible"; unitState = "ok"; };
  readyMan = a.ready { daemonOwnership = "manual"; compatibility = "compatible"; unitState = "ok"; };
}
EOF
out="$(nix --extra-experimental-features 'nix-command flakes' eval --impure --json --file "$TMP/conflicts.nix" 2>"$TMP/nix-eval.err")"
assert_eq '[]' "$(field "$out" ok)" 'a systemd-owned, compatible, ok daemon has NO conflicts'
assert_eq '["daemon-owned-by-manual"]' "$(field "$out" man)" \
	'a manually started daemon is reported as a daemon conflict'
assert_eq '["client-server-cli-newer"]' "$(field "$out" cli)" \
	'a newer CLI against an older server is a SEPARATE conflict'
assert_eq '["unit-failed"]' "$(field "$out" fail)" \
	'a failed unit is a SEPARATE conflict'
assert_eq \
	'["daemon-owned-by-manual","client-server-cli-older","unit-never-started"]'  \
	"$(field "$out" all)" 'all three are reported together, not merged into one flag'
assert_eq 'true' "$(field "$out" readyOk)" 'only the fully healthy case is "ready"'
assert_eq 'false' "$(field "$out" readyMan)" 'a manual daemon is not "ready" even when otherwise fine'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the REAL host's generated unit matches the rule"
#
# The facts are computed by the FLAKE, on the machine that built this check,
# and handed to the suite in host-facts.env. They are not re-derived here, and
# the unit is not re-implemented here: the assertion is that what Nix actually
# generated for the Legion satisfies the same rule the matrix above checks.
#
# Why not `nix eval` from inside the check: a nested Nix inside a build needs
# the network to resolve this flake's inputs and the host's store, and failing at
# that reads exactly like a broken lifetime rule. Computing the facts outside the
# build removes the ambiguity — and flake.nix cannot evaluate them wrongly
# without the check failing too, because it reads the same option values.
#
# Standalone runs (no flake check) generate the facts themselves with the same
# nix eval the check's flake used, and say so — rather than skipping the whole
# block, which is how a check quietly stops running on the machine where it
# would have caught something.
HOST_FACTS="${AGENT_OPS_HOST_FACTS:-}"
if [[ -z "$HOST_FACTS" || ! -r "$HOST_FACTS" ]]; then
	mk_facts() {
		local out="$TMP/host-facts.env"
		cat >"$TMP/facts.nix" <<EOF
let f = builtins.getFlake "path:$FLAKE_DIR";
    s = f.nixosConfigurations.legion.config.home-manager.users.sonny.systemd.user.services;
    v = f.nixosConfigurations.legion.config.home-manager.users.sonny.home.sessionVariables;
    asList = xs: if builtins.isList xs then xs else [ xs ];
in {
  herdrWantedBy = builtins.toJSON (asList s.herdr.Install.WantedBy);
  herdrAfter = builtins.toJSON (asList s.herdr.Unit.After);
  herdrWants = builtins.toJSON (asList s.herdr.Unit.Wants);
  herdrLoadCredential = toString (builtins.length s.herdr.Service.LoadCredential);
  resumeSuccess = s.herdr-resume.Service.SuccessExitStatus;
  resumeWantedBy = builtins.toJSON (asList s.herdr-resume.Install.WantedBy);
  hasImportEnvironment = if s ? sops-import-environment then "true" else "false";
  sessionSecretVars = builtins.toJSON (builtins.filter
    (n: builtins.match ".*(API_KEY|ACCESS_TOKEN|PASSWORD).*" n != null)
    (builtins.attrNames v));
}
EOF
		local json
		json="$(nix --extra-experimental-features 'nix-command flakes' eval --impure --json 			--file "$TMP/facts.nix" 2>"$TMP/facts.err")" || return 1
		printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k, v in d.items():
    print("HOST_FACT_%s=%s" % (k, json.dumps(v, separators=(",", ":"))))
' >"$out" || return 1
		printf '%s' "$out"
	}
	# 🔴 DO NOT CLOBBER A WORKING PATH ON FAILURE.
	#
	# `HOST_FACTS="$(mk_facts)" || HOST_FACTS=""` replaced a perfectly good
	# flake-provided path with the empty string whenever the fallback could not
	# run, and then reported "the facts are missing" for a file that was sitting
	# right there. Inside the sandboxed check the fallback CANNOT run — a nested
	# `nix eval` has no network and no host store — so this took the passing path
	# and turned it into a failure.
	generated=""
	generated="$(mk_facts)" || generated=""
	[[ -n "$generated" ]] && HOST_FACTS="$generated"
	if [[ -n "$HOST_FACTS" ]]; then
		printf '    (host facts evaluated from the live configuration)\n'
	fi
fi

if [[ ! -r "$HOST_FACTS" ]]; then
	fact() {
		printf 'no host-facts.env at %s' "$HOST_FACTS"
		printf ' Run through `nix build .#checks.x86_64-linux.agent-operations`,'
		printf ' which generates it from the real host configuration.'
		return 1
	}
	TESTS_RUN=$((TESTS_RUN + 1))
	_fail "the Legion unit facts are available (expected a store path from AGENT_OPS_HOST_FACTS; got '$HOST_FACTS')"
else
	# NOT `source`d: bash would strip the double quotes out of
	# HOST_FACT_herdrWantedBy=["default.target"] while reading it, and the
	# comparison would then be against `[default.target]`. Read the lines
	# instead, which keeps the value exactly as Nix wrote it.
	fact() {
		local key="$1" v
		v="$(grep -m1 "^${key}=" "$HOST_FACTS" | cut -d= -f2-)"
		# ONE level of JSON encoding, so ONE decode: strip a wrapping pair of
		# quotes if present, then unescape the inner quotes.
		#
		# Order matters and spaces must not be stripped first: `tr -d ' '` before
		# the quote test leaves the value starting with an ESCAPED quote, so the
		# outer-quote test never matches and every comparison runs against the
		# still-escaped text.
		if [[ "$v" == \"*\" ]]; then
			v="${v:1:${#v}-2}"
		fi
		# Parameter expansion, not sed: `sed 's/\\\\"/"/g'` in a shell file
		# goes through two more layers of escaping, and getting it wrong leaves
		# the backslashes in place with no error at all.
		v="${v//\\\"/\"}"
		v="${v//\\\\/\\}"
		printf '%s' "$v"
	}

	assert_eq '["default.target"]' "$(fact "HOST_FACT_herdrWantedBy")" \
		'legion (mobile on) starts the server at boot, not at login'
	assert_eq '["sops-nix.service"]' "$(fact "HOST_FACT_herdrAfter")" \
		'and does not order behind a graphical session that may never exist'
	assert_eq '["sops-nix.service"]' "$(fact "HOST_FACT_herdrWants")" \
		'and pulls sops-nix in'
	assert_eq '0' "$(fact "HOST_FACT_herdrLoadCredential")" \
		'LoadCredential is empty by default (a mandatory credential must not be able to strand the server)'
	assert_eq '0' "$(fact "HOST_FACT_resumeSuccess")" \
		'the resume unit no longer declares exit 1 as success'
	assert_eq '["herdr.service"]' "$(fact "HOST_FACT_resumeWantedBy")" \
		'and fires on every herdr start'
	assert_eq 'false' "$(fact "HOST_FACT_hasImportEnvironment")" \
		'the sops-import-environment unit is gone'
	assert_eq '[]' "$(fact "HOST_FACT_sessionSecretVars")" \
		'no credential is in home.sessionVariables any more'

	# And the generated unit agrees with the RULE, not merely with itself.
	lifetime="$(eval_lifetime false true)"
	assert_eq "$(field "$lifetime" wantedBy)" "$(fact "HOST_FACT_herdrWantedBy")" \
		'the generated WantedBy is exactly what the rule says for headless=false mobile=true'
	assert_eq "$(field "$lifetime" after)" "$(fact "HOST_FACT_herdrAfter")" \
		'the generated After is exactly what the rule says'
fi

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the aikami hardcoding is gone"
# Strip comments first. The words appear in the prose that explains what was
# removed, which is exactly where they SHOULD be; what must not exist is the
# same string in a live expression.
live_code() { grep -vE '^[[:space:]]*#' "$1"; }
assert_file "$RESUME" 'the resume script exists'
out="$(grep -c 'aikami' "$LANE_SRC/config/home/herdr.nix" || true)"
# herdr.nix no longer names the project at all: the unit now delegates entirely
# to the script, which has no default. So the assertion is that NOTHING in the
# generated unit chain hard-codes it.
assert_eq '0' "$(live_code "$LANE_SRC/config/home/herdr.nix" | grep -c 'aikami' || true)" \
	'no live herdr.nix line names any project'
if live_code "$LANE_SRC/config/home/herdr.nix" | grep -qE 'aikami|repoRoot|contract:resume-orphaned|bun run contract'; then
	_fail 'no project, root or task is hard-coded in live herdr.nix code'
else
	_ok 'live herdr.nix code hard-codes no project, root or task'
fi
if grep -qE 'aikami|contract:resume-orphaned' "$RESUME"; then
	_fail 'the resume script has no hard-coded default project'
else
	_ok 'the resume script has no hard-coded default project'
fi
# And the exit-code contract is back: 0 only.
assert_not_contains "$(cat "$RESUME")" 'exit1-as-success' 'the resume script has no exit-1-as-success path'
assert_contains "$(live_code "$LANE_SRC/config/home/herdr.nix")" 'SuccessExitStatus = "0"' \
	'the resume unit treats only exit 0 as success' 

assert_no_reboot "$TMP/reboots"
summary