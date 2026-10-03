#!/usr/bin/env bash
# nixos/tests/server-foundation/role-policy.sh — the server/travel ROLE policy,
# asserted against the function that decides it.
#
# Why this file tests `nix/lib/host-policy.nix` directly rather than a
# configuration: the policy is a pure function over two booleans and an attrset
# (that is a deliberate constraint, see the module header), so it can be
# evaluated with `nix eval --file` in about a second with no nixpkgs, no flake,
# no network and no build. The thing being tested is therefore the REAL policy —
# the same expression the flake runs — rather than a description of it.
#
# Each case below is a configuration somebody can actually write. The ones that
# matter most are the REFUSALS, because a role that quietly resolves to
# something nobody intended is worse than one that fails to evaluate.
#
# Run directly:  bash nixos/tests/server-foundation/role-policy.sh
set -o nounset -o pipefail

# `nix eval` is a CLI subcommand and needs the nix-command feature. Inside a
# `checks` sandbox there is no nix.conf and no HOME configuration to supply it,
# so the suite sets it for itself rather than depending on the caller's
# environment. Set, not prepended: whatever the caller already enabled is kept.
export NIX_CONFIG="${NIX_CONFIG:-}experimental-features = nix-command"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The nixos/ directory itself: this suite lives at nixos/tests/server-foundation/.
ROOT="$(cd "$HERE/../.." && pwd)"

printf '\n\033[1mserver-foundation — role / headless / override policy\033[0m\n'

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

fail() {
  printf '    FAIL %s: %s\n' "${CURRENT_TEST:-<none>}" "$*" >&2
  TESTS_FAILED=$((TESTS_FAILED + 1))
}
t_start() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '  %s\n' "$1"
}
t_done() {
  [[ "$TESTS_FAILED" -gt 0 ]] && return 0
  printf '    ok   %s\n' "$CURRENT_TEST"
  CURRENT_TEST=""
}

# Evaluate one expression against the real module and print the JSON result.
#
# The expression arrives on STDIN and is written to a real file, rather than
# being interpolated into `--expr`. Nix expressions contain quotes, dollars and
# braces; getting those through two layers of shell quoting is a way to test the
# quoting instead of the policy, and a subtly mangled expression fails with an
# error about an attribute that is perfectly well defined.
policy_eval() {
  local scratch
  scratch="$(mktemp "${TMPDIR:-/tmp}/role-policy.XXXXXX.nix")"
  {
    printf 'let\n  policy = import %s;\nin\n' "${ROOT}/lib/host-policy.nix"
    cat
  } >"$scratch"
  # stderr is captured separately and only printed on failure. nix writes
  # warnings there ("you don't have Internet access; …") which are not part of
  # the answer, and merging the streams would prepend them to every value and
  # make a correct assertion fail on formatting.
  local err rc
  err="$(mktemp)"
  if nix eval --json --impure --file "$scratch" 2>"$err"; then
    rc=0
  else
    rc=$?
    cat "$err" >&2
  fi
  rm -f "$err" "$scratch"
  return "$rc"
}

# A mobile-agents shape with everything configured, so a test can turn on the
# one thing it is about without tripping an unrelated check.
MA_OK='{ enable = true; sshPort = 2222; collie = { enable = false; }; }'

# Evaluate a diagnostics expression and return BOTH the count and the text.
#
# The count is computed by Nix, which is what produced the list. Counting array
# elements in bash means either a Python interpreter in the check sandbox (for
# one `len()`) or string-counting on JSON, and both are worse than asking the
# thing that knows the answer.
#
#   { n = builtins.length d.problems; text = builtins.concatStringsSep "\n" d.problems; }
diagnostics_json() {
  local scratch err rc
  scratch="$(mktemp "${TMPDIR:-/tmp}/role-policy-diag.XXXXXX.nix")"
  err="$(mktemp)"
  {
    printf 'let\n  policy = import %s;\n  d =\n' "${ROOT}/lib/host-policy.nix"
    cat
    # The closing semicolon belongs to the diagnostics expression, so it is
    # printed here rather than left to the heredoc — a missing one is a syntax
    # error that reads as though the policy itself were malformed.
    printf ';\nin\n  {
    n = builtins.length d.problems;
    text = builtins.concatStringsSep "\\n" d.problems;
    w = builtins.length d.warnings;
    warnings = builtins.concatStringsSep "\\n" d.warnings;
  }\n'
  } >"$scratch"
  if nix eval --json --impure --file "$scratch" 2>"$err"; then
    rc=0
  else
    rc=$?
    cat "$err" >&2
  fi
  rm -f "$err" "$scratch"
  return "$rc"
}

# assert_problem_count <label> <expected> <json-from-diagnostics_json>
assert_problem_count() {
  local label="$1" want="$2" json="$3"
  if [[ "$json" == *"\"n\":$want"* ]]; then
    return 0
  fi
  fail "$label: expected $want problem(s) — got $json"
}

assert_eq_str() {
  if [[ "$2" == "$3" ]]; then
    return 0
  fi
  fail "$1: expected '$2', got '$3'"
}

# ─────────────────────────────────────────────────────────────────────────────
t_start "role = null inherits headless, which is the compatibility path"
out="$(policy_eval <<'NIX'
{
  plain   = policy.resolveRole { role = null; headless = false; };
  legacy  = policy.resolveRole { role = null; headless = true; };
  legacyH = policy.resolveHeadless { role = null; headless = true; };
  plainH  = policy.resolveHeadless { role = null; headless = false; };
}
NIX
)"
if [[ "$out" == *'"legacy":"server"'* && "$out" == *'"plain":"desktop"'* && \
      "$out" == *'"legacyH":true'* && "$out" == *'"plainH":false'* ]]; then
  : # a host that predates roles keeps working by flipping the boolean it had
else
  fail "a host with role = null must resolve entirely from headless — got $out"
fi
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "role = \"server\" makes headless true, whatever the boolean said"
out="$(policy_eval <<'NIX'
{
  role = policy.resolveRole { role = "server"; headless = false; };
  eff = policy.resolveHeadless { role = "server"; headless = false; };
  desktopNotAffected = policy.resolveHeadless { role = "desktop"; headless = false; };
}
NIX
)"
if [[ "$out" == *'"role":"server"'* && "$out" == *'"eff":true'* && \
      "$out" == *'"desktopNotAffected":false'* ]]; then
  : # one line of host config gets every headless behaviour, and desktop is untouched
else
  fail "role=server must resolve headless to true and role=desktop must not — got $out"
fi
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "role = \"desktop\" next to headless = true is REFUSED"
out="$(diagnostics_json <<NIX
policy.policyDiagnostics {
  role = "desktop";
  headless = true;
  batteryChargeLimit = null;
  mobileAgents = $MA_OK;
}
NIX
)"
assert_problem_count "role=desktop + headless=true" 1 "$out"
if [[ "$out" == *"headless"* && "$out" == *"server"* ]]; then
  : # the message names both switches
else
  fail "the refusal must name both role and headless — got $out"
fi
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "a misspelt role is refused rather than quietly treated as desktop"
out="$(diagnostics_json <<NIX
policy.policyDiagnostics {
  role = "servr";
  headless = false;
  batteryChargeLimit = null;
  mobileAgents = $MA_OK;
}
NIX
)"
assert_problem_count "misspelt role" 1 "$out"
if [[ "$out" == *"servr"* && "$out" == *"desktop, server"* ]]; then
  : # the message lists the valid values
else
  fail "a misspelt role must name itself and the valid set — got $out"
fi
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "every problem is reported at once, not one rebuild at a time"
out="$(diagnostics_json <<'NIX'
policy.policyDiagnostics {
  role = "desktop";
  headless = true;
  batteryChargeLimit = null;
  mobileAgents = { enable = true; sshPort = 22; collie = { enable = true; }; };
}
NIX
)"
# role/headless contradiction AND mobileAgents.sshPort = 22.
assert_problem_count "two independent contradictions" 2 "$out"
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the phone listener may not be port 22"
out="$(diagnostics_json <<'NIX'
policy.policyDiagnostics {
  role = "desktop";
  headless = false;
  batteryChargeLimit = null;
  mobileAgents = { enable = true; sshPort = 22; collie = { enable = false; }; };
}
NIX
)"
assert_problem_count "sshPort = 22" 1 "$out"
if [[ "$out" == *"2222"* ]]; then
  : # the message suggests the value every host uses
else
  fail "the refusal should suggest a workable port — got $out"
fi
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "Collie without the shared mobile infrastructure is refused"
out="$(diagnostics_json <<'NIX'
policy.policyDiagnostics {
  role = "desktop";
  headless = false;
  batteryChargeLimit = null;
  mobileAgents = { enable = false; sshPort = 2222; collie = { enable = true; }; };
}
NIX
)"
assert_problem_count "collie without mobileAgents.enable" 1 "$out"
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "a healthy server host produces no problems and no warnings"
out="$(diagnostics_json <<'NIX'
policy.policyDiagnostics {
  role = "server";
  headless = true;
  batteryChargeLimit = 60;
  mobileAgents = { enable = true; sshPort = 2222; collie = { enable = true; }; };
}
NIX
)"
if [[ "$out" == *'"n":0'* && "$out" == *'"warnings"'* && "$out" != *'batteryChargeLimit'* ]]; then
  : # the configuration this repository ships must not be its own warning
else
  fail "the shipped server configuration must be clean — got $out"
fi
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "a server with no charge limit warns, but does not fail"
out="$(diagnostics_json <<NIX
policy.policyDiagnostics {
  role = "server";
  headless = true;
  batteryChargeLimit = null;
  mobileAgents = $MA_OK;
}
NIX
)"
if [[ "$out" == *'"n":0'* && "$out" == *'batteryChargeLimit'* ]]; then
  : # survivable: a desktop-provisioned server box may have no battery at all
else
  fail "a missing charge limit is a warning, not an error — got $out"
fi
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "a private override file is scoped to ONE host"
out="$(policy_eval <<'NIX'
let
  local = { legion = { hostname = "legion-server"; }; };
  onLegion = policy.selectHostOverrides { inherit local; hostKey = "legion"; };
  onGs65 = policy.selectHostOverrides { inherit local; hostKey = "gs65"; };
in
{
  legion = onLegion.overrides;
  legionShape = onLegion.shape;
  gs65Shape = onGs65.shape;
  gs65Warned = onGs65.warning != null;
  gs65Overrides = onGs65.overrides;
}
NIX
)"
if [[ "$out" == *'"legionShape":"host-scoped"'* && \
      "$out" == *'"gs65Shape":"host-scoped"'* && \
      "$out" == *'"gs65Warned":true'* && \
      "$out" == *'"gs65Overrides":{}'* && \
      "$out" == *'"legion":{"hostname":"legion-server"}'* ]]; then
  : # the override applies to the host it names and to no other host
else
  fail "host-scoped local.nix must not leak across hosts — got $out"
fi
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "_default applies where no host key matches, and the host key wins"
out="$(policy_eval <<'NIX'
let
  local = {
    _default = { mouse = { thumbWheelInvert = false; }; };
    gs65 = { hostname = "gs65b"; };
  };
in
{
  gs65 = (policy.selectHostOverrides { inherit local; hostKey = "gs65"; }).overrides;
  legion = (policy.selectHostOverrides { inherit local; hostKey = "legion"; }).overrides;
}
NIX
)"
if [[ "$out" == *'"gs65":{"hostname":"gs65b"}'* && \
      "$out" == *'"legion":{"mouse":{"thumbWheelInvert":false}}'* ]]; then
  : # the explicit key wins; _default is a default, not a base to extend
else
  fail "per-host key must beat _default, and _default must fill the rest — got $out"
fi
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "the legacy FLAT override shape is still accepted, and reported"
out="$(policy_eval <<'NIX'
let
  r = policy.selectHostOverrides {
    local = { hostname = "x"; headless = true; };
    hostKey = "legion";
  };
in
{
  shape = r.shape;
  overridden = r.overrides;
  warned = r.warning != null;
}
NIX
)"
if [[ "$out" == *'"shape":"flat-legacy"'* && "$out" == *'"warned":true'* && \
      "$out" == *'"headless":true'* ]]; then
  : # an existing local.nix keeps working, and is told it applies to every host
else
  fail "the flat shape must still evaluate, with a warning that it is global — got $out"
fi
t_done

# ─────────────────────────────────────────────────────────────────────────────
t_start "DNS: one owner, and a rescue list that fits inside maxnames"
out="$(policy_eval <<'NIX'
let
  server = policy.dnsPolicy { headless = true; };
  desktop = policy.dnsPolicy { headless = false; };
in
{
  serverOwner = server.owner;
  serverCount = builtins.length server.nameservers;
  serverMax = server.maxnames;
  serverNames = server.nameservers;
  desktopCount = builtins.length desktop.nameservers;
  desktopMax = desktop.maxnames;
  ownerSame = server.owner == desktop.owner;
  loopbackFirst = builtins.head server.nameservers == "127.0.0.1";
}
NIX
)"
if [[ "$out" == *'"serverCount":4'* && "$out" == *'"serverMax":4'* && \
      "$out" == *'"desktopCount":2'* && "$out" == *'"desktopMax":2'* && \
      "$out" == *'"ownerSame":true'* && "$out" == *'"loopbackFirst":true'* && \
      "$out" == *'9.9.9.9'* && "$out" == *'1.1.1.1'* ]]; then
  :
  # maxnames == length(nameservers) is the whole invariant: resolv.conf caps how
  # many nameservers are consulted and silently discards the rest, which is how
  # a rescue list becomes decoration.
else
  fail "the DNS owner/rescue contract is not satisfied — got $out"
fi
t_done

# ─────────────────────────────────────────────────────────────────────────────
if [[ "$TESTS_FAILED" -ne 0 ]]; then
  printf '\n\033[31mrole-policy: %d of %d assertions failed\033[0m\n' "$TESTS_FAILED" "$TESTS_RUN"
  exit 1
fi
printf '\n\033[32mrole-policy: all %d checks passed\033[0m\n' "$TESTS_RUN"
