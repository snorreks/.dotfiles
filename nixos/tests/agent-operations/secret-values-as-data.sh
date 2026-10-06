#!/usr/bin/env bash
# SC2016 is INFORMATIONAL, and here it IS the assertion: the values below must
# never be expanded by the shell, which is the entire property under test. Every
# single-quoted `$(…)`, backtick and `$var` in this file is meant to stay a
# literal character sequence.
# shellcheck disable=SC2016
# nixos/tests/agent-operations/secret-values-as-data.sh
#
# The credential tests. Every value here is SYNTHETIC and lives in a disposable
# $TMP; nothing reads a real secret, and no real sops key is involved.
#
# What is being proved:
#
#   1. A credential value is DATA. It arrives at a process byte-for-byte, and it
#      is never parsed, expanded, word-split or evaluated.
#   2. The specific shapes that used to break the eval template actually work
#      now: double quotes, `$(...)`, backticks, `;`, newlines, non-ASCII.
#   3. Nothing in a value can execute. The injection payloads create files and
#      remove a directory; the suite asserts the files do not exist afterwards.
#   4. Absent and DELAYED decryption are distinguishable from an empty value, and
#      both are visibly not-ready.
#   5. The one genuinely impossible case — an embedded NUL — is refused loudly
#      rather than silently truncated.
#   6. ANTHROPIC_API_KEY keeps OAuth precedence: it is named in the manifest but
#      never exported by the session path.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"
SUITE_NAME="secret-values-as-data"

fixture_new
# Never fall back to the operator's decrypted files during absent-key tests.
export HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/runtime" XDG_STATE_HOME="$TMP/xdg-state"
# --no-config still loads fish universal variables; isolate that store too.
export XDG_CONFIG_HOME="$TMP/config"
# Names only: never inspect any credentials inherited from the test runner.
unset ANTHROPIC_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY GEMINI_API_KEY
unset SUPABASE_ACCESS_TOKEN DEEPSEEK_API_KEY OPENCODE_API_KEY
unset GITHUB_ACCESS_TOKEN GH_TOKEN MOONSHOT_API_KEY KIMI_API_KEY
unset CONTEXT7_API_KEY NPM_PRIVATE_TOKEN DEEPINFRA_API_KEY
unset GOOGLE_CALENDAR_ICS_URL OPENWEATHER_API_KEY

MANIFEST="$TMP/secrets.manifest"
export CREDENTIALS_DIRECTORY="$TMP/creds"
SECRET_ENV_MANIFEST="$MANIFEST"
export SECRET_ENV_MANIFEST

# The canaries. If any of these strings appears in a variable of a child
# process we did not explicitly ask for, the test fails.
CANARY_CMD="$TMP/CANARY_COMMAND_SUBSTITUTION"
CANARY_BTICK="$TMP/CANARY_BACKTICK"
CANARY_RM="$TMP/CANARY_RM"
CANARY="CANARY-4f2b91ee-DO-NOT-LEAK"

# ── the fixture credentials ────────────────────────────────────────────────
# Every shape that broke the old `export NAME="value"` template.
printf 'sk-or-v1-plainvalue' >"$CREDENTIALS_DIRECTORY/PLAIN_KEY"
printf 'has "double" quotes and $dollar and \\backslash' >"$CREDENTIALS_DIRECTORY/QUOTED_KEY"
printf '%s ; $(touch %s); `touch %s`; rm -rf %s' "$CANARY" "$CANARY_CMD" "$CANARY_BTICK" "$CANARY_RM" \
	>"$CREDENTIALS_DIRECTORY/INJECT_KEY"
printf 'line one\nline two\nline three\n' >"$CREDENTIALS_DIRECTORY/MULTILINE_KEY"
printf 'value\n\n' >"$CREDENTIALS_DIRECTORY/TRAILING_KEY"
printf 'unicode: æøå 日本語 🙂\n' >"$CREDENTIALS_DIRECTORY/UNICODE_KEY"
printf '  padded value  ' >"$CREDENTIALS_DIRECTORY/PADDED_KEY"
printf 'aliased-value' >"$CREDENTIALS_DIRECTORY/ALIASED_KEY"
printf 'a\0b' >"$CREDENTIALS_DIRECTORY/NUL_KEY"
printf '%s\n' '-----BEGIN KEY-----' 'secret line' '-----END KEY-----' >"$CREDENTIALS_DIRECTORY/PEM_KEY"

# sessionVariable=false is how ANTHROPIC_API_KEY is declared in env-secrets.nix.
cat >"$MANIFEST" <<EOF
# synthetic manifest — names only, like the generated one
PLAIN_KEY||true
QUOTED_KEY||true
INJECT_KEY||true
MULTILINE_KEY||true
TRAILING_KEY|TRAILING_ALIAS|true
UNICODE_KEY||true
PADDED_KEY||true
ALIASED_KEY|GH_TOKEN SECRET_ALIAS_THIRD|true
NUL_KEY||true
PEM_KEY||true
ANTHROPIC_API_KEY||false
MISSING_KEY||true
# A credential that is session-visible, used to prove an ambient copy of it is
# stripped from a child that did not ask for it.
OPENROUTER_API_KEY||true
EOF
# ANTHROPIC_API_KEY is sessionVariable=false, which does NOT mean "decryption
# failed" — it means "never put it in a session". To prove it is still reachable
# on request, its decrypted file must exist.
printf 'console-key-value' >"$CREDENTIALS_DIRECTORY/ANTHROPIC_API_KEY"

# ── helper: run a command with ONE credential and capture its environment ──
# `env -i` inside secret-env.sh means whatever we capture is exactly what the
# credential contributed — nothing from this shell leaks in.
env_of() {
	# `$TMP/bin/showenv`, not /usr/bin/env — see the fixture for why.
	bash "$SECRET_ENV" --name "$1" --exec "$TMP/bin/showenv" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a value is delivered byte-for-byte, not parsed"
out="$(env_of QUOTED_KEY | grep -a '^QUOTED_KEY=')"
assert_eq 'QUOTED_KEY=has "double" quotes and $dollar and \backslash' "$out" \
	'a value with quotes, \$dollar and a backslash arrives intact'

out="$(env_of PADDED_KEY | grep -a '^PADDED_KEY=')"
assert_eq 'PADDED_KEY=  padded value  ' "$out" \
	'leading/trailing spaces are preserved (only one trailing newline is stripped)'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a multiline value round-trips"
# `env` prints the value followed by the next entry; sed isolates the block.
out="$(env_of MULTILINE_KEY | sed -n '/^MULTILINE_KEY=/,/^$/p' | head -4)"
assert_contains "$out" 'line one
line two
line three' 'embedded newlines survive to the child process'
 assert_eq '1' "$(env_of MULTILINE_KEY | grep -ac '^MULTILINE_KEY=')" \
	'and the whole value arrives as ONE environment entry, not three'

out="$(env_of PEM_KEY | grep -ac 'BEGIN KEY')"
assert_eq '1' "$out" 'a PEM-shaped value is not cut at the first line'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "exact trailing-newline bytes survive exec and NUL records"
printf 'value\n' >"$TMP/expected-value"
bash "$SECRET_ENV" --name TRAILING_KEY --exec bash -c 'printf "%s" "$TRAILING_KEY"' >"$TMP/actual-value"
cmp -s "$TMP/expected-value" "$TMP/actual-value"
assert_eq '0' "$?" '--exec removes exactly one of two trailing newlines'
printf 'TRAILING_KEY=value\n\0TRAILING_ALIAS=value\n\0' >"$TMP/expected-nul"
bash "$SECRET_ENV" --name TRAILING_KEY --format=nul >"$TMP/actual-nul"
cmp -s "$TMP/expected-nul" "$TMP/actual-nul"
assert_eq '0' "$?" 'NUL records and aliases retain the remaining newline'

_t_start "explicit fish loading uses loader lookup and aliases without ambient auto-loading"
# Extract the actual function, not a reimplementation of the Nix string.
python3 - "$LANE_SRC/config/home/fish/default.nix" "$TMP/ns-secrets.fish" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
start = text.index('      function ns-secrets ')
end = text.index('\n      # Readiness only', start)
pathlib.Path(sys.argv[2]).write_text(text[start:end])
PY
# A hard-coded interpreter wrapper also works in the Nix test sandbox.
# Exercise more than one lookup directory: the old string-collect path joined
# these into a single newline-bearing pathname and could find neither.
mkdir -p "$XDG_RUNTIME_DIR/sops-nix/secrets"
mv "$CREDENTIALS_DIRECTORY/ALIASED_KEY" "$XDG_RUNTIME_DIR/sops-nix/secrets/ALIASED_KEY"
fake loader <<'FAKE'
exec bash "$SECRET_ENV_SOURCE" "$@"
FAKE
export SECRET_ENV_SOURCE="$SECRET_ENV"
SECRET_ENV="$TMP/bin/loader" fish --no-config -c '
    source "$TMP/ns-secrets.fish"
    set -q TRAILING_KEY; and exit 8
    ns-secrets
    printf "%s" "$TRAILING_KEY" > "$TMP/fish-value"
    printf "%s" "$TRAILING_ALIAS" > "$TMP/fish-alias"
    test "$GH_TOKEN" = aliased-value; or exit 9
    set -q ANTHROPIC_API_KEY; and exit 10
    set -q NUL_KEY; and exit 11
    exit 0
'
assert_eq '0' "$?" 'fish loads ready aliases only, explicitly, retaining OAuth precedence'
cmp -s "$TMP/expected-value" "$TMP/fish-value"
assert_eq '0' "$?" 'fish preserves the remaining trailing newline'
cmp -s "$TMP/expected-value" "$TMP/fish-alias"
assert_eq '0' "$?" 'fish aliases preserve identical bytes'

_t_start "interactive fish automatically exports ready credentials to arbitrary CLI children"
python3 - "$LANE_SRC/config/home/fish/default.nix" "$TMP/cli-init.fish" <<'PYTHON'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
start = text.index('      function ns-secrets ')
end = text.index('      set fish_greeting', start)
pathlib.Path(sys.argv[2]).write_text(text[start:end])
PYTHON
cat >"$TMP/cli-child.sh" <<'CHILD'
test "$GH_TOKEN" = aliased-value && test -n "$QUOTED_KEY" && test -n "$INJECT_KEY" && test -z "${ANTHROPIC_API_KEY+x}" && test -z "${NUL_KEY+x}"
CHILD
SECRET_ENV="$TMP/bin/loader" fish --no-config --interactive -c '
    source "$TMP/cli-init.fish"
    command bash "$TMP/cli-child.sh"
' >"$TMP/cli-init.out" 2>&1
assert_eq '0' "$?" 'ordinary CLI children inherit ready keys and aliases without ns-secrets'
assert_no_file "$CANARY_CMD" 'automatic loading never executes command substitutions'
assert_no_file "$CANARY_BTICK" 'automatic loading never executes backticks'

_t_start "the sops-nix home-manager symlink path is searched"
# This is the layout on a real host: sops-nix decrypts into
# $XDG_RUNTIME_DIR/secrets.d/<id> and symlinks the CURRENT generation at
# $XDG_CONFIG_HOME/sops-nix/secrets. A credential found ONLY there must be
# found — the loader missed this path entirely and reported every credential
# ABSENT on a correctly-decrypted machine.
mkdir -p "$XDG_CONFIG_HOME/sops-nix/secrets"
printf 'config-dir-value' >"$XDG_CONFIG_HOME/sops-nix/secrets/CONFIG_DIR_KEY"
printf 'CONFIG_DIR_KEY||true\n' >>"$MANIFEST"
out="$(bash "$SECRET_ENV" --name CONFIG_DIR_KEY --exec "$TMP/bin/showenv" 2>/dev/null | grep -a '^CONFIG_DIR_KEY=')"
assert_eq 'CONFIG_DIR_KEY=config-dir-value' "$out" \
	'a credential only in the sops-nix symlink dir is found'
out="$(bash "$SECRET_ENV" --name CONFIG_DIR_KEY --check 2>/dev/null)"
assert_contains "$out" 'ready' 'and --check reports it ready'

_t_start "actual managed fish children load ready keys, not server/client/pane shells"
python3 - "$LANE_SRC/config/home/fish/default.nix" "$TMP/__ns_agent_exec.fish" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
start = text.index('function __ns_agent_exec ')
end = text.index("'';", start)
pathlib.Path(sys.argv[2]).write_text(text[start:end])
PY
export MANAGED_FUNCTIONS="$LANE_SRC/config/home/fish/functions"
cat >"$TMP/managed.manifest" <<'EOF'
QUOTED_KEY||true
TRAILING_KEY|TRAILING_ALIAS|true
OPENROUTER_API_KEY||true
ANTHROPIC_API_KEY||false
EOF
fake pi <<'FAKE'
printf '%s' "$QUOTED_KEY" >"$TMP/child-quotes"
printf '%s' "$TRAILING_KEY" >"$TMP/child-trailing"
printf '%s' "$TRAILING_ALIAS" >"$TMP/child-alias"
printf '%s\0' "$@" >"$TMP/child-argv"
if [[ -v ANTHROPIC_API_KEY ]]; then exit 18; fi
if [[ -v OPENROUTER_API_KEY ]]; then
    [[ ${ALLOW_READY_API:-} == 1 ]] || exit 18
    printf '%s' "$OPENROUTER_API_KEY" >"$TMP/child-api"
fi
printf child >"$TMP/child-started"
FAKE
cp "$TMP/bin/pi" "$TMP/bin/claude"
fake herdr <<'FAKE'
printf unexpected-client >"$TMP/client-called"
exit 19
FAKE
# Simulates the plain fish pane of a server that already exists, using the
# exact shell-submitted executable words (not command/exec builtins).
cat >"$TMP/managed.fish" <<'FISH'
set -p fish_function_path "$TMP"
source "$MANAGED_FUNCTIONS/pi.fish"
source "$MANAGED_FUNCTIONS/claude.fish"
set -gx HERDR_ENV 1
set -q QUOTED_KEY; and exit 21
set -q TRAILING_KEY; and exit 22
'pi' --resume 'argument with spaces' 'quote" $literal'; or exit $status
'claude' --resume 'argument with spaces' 'quote" $literal'; or exit $status
set -q QUOTED_KEY; and exit 23
set -q TRAILING_KEY; and exit 24
set -q ANTHROPIC_API_KEY; and exit 25
set -q OPENROUTER_API_KEY; and exit 26
exit 0
FISH
SECRET_ENV="$TMP/bin/loader" SECRET_ENV_MANIFEST="$TMP/managed.manifest" \
    fish --no-config "$TMP/managed.fish"
assert_eq '0' "$?" 'plain existing-server fish runs pi and claude with absent optional API key'
printf '%s' 'has "double" quotes and $dollar and \backslash' >"$TMP/expected-quotes"
printf '%s\0' --resume 'argument with spaces' 'quote" $literal' >"$TMP/expected-argv"
for part in quotes trailing alias argv; do
    expected="$TMP/expected-value"
    [[ "$part" == quotes ]] && expected="$TMP/expected-quotes"
    [[ "$part" == argv ]] && expected="$TMP/expected-argv"
    cmp -s "$expected" "$TMP/child-$part"
    assert_eq '0' "$?" "managed child exact $part bytes, including aliases/quotes/trailing LF"
done
assert_no_file "$TMP/client-called" 'no herdr client or restart is used for child credentials'
# A selected malformed optional credential fails rather than starting a child.
printf 'bad\0value' >"$CREDENTIALS_DIRECTORY/OPENROUTER_API_KEY"
rm -f "$TMP/child-started"
SECRET_ENV="$TMP/bin/loader" SECRET_ENV_MANIFEST="$TMP/managed.manifest" \
    fish --no-config "$TMP/managed.fish" >"$TMP/managed-error" 2>&1
assert_eq '4' "$?" 'malformed selected key prevents managed consumer spawn'
assert_no_file "$TMP/child-started" 'malformed values do not reach either consumer'
assert_contains "$(<"$TMP/managed-error")" 'NUL byte' 'failure names malformed credential without its value'
SECRET_ENV="$TMP/bin/loader" SECRET_ENV_MANIFEST="$TMP/managed.manifest" \
    fish --no-config -c 'set -p fish_function_path "$TMP"; source "$MANAGED_FUNCTIONS/claude.fish"; set -gx HERDR_ENV 1; claude --resume' \
    >"$TMP/managed-error" 2>&1
assert_eq '4' "$?" 'Claude actual branch also refuses selected malformed keys'
assert_no_file "$TMP/child-started" 'Claude failure does not spawn a consumer'
# Files arriving after the server already started are discovered per spawn.
printf 'ready "API" $literal\n\n' >"$CREDENTIALS_DIRECTORY/OPENROUTER_API_KEY"
printf 'ready "API" $literal\n' >"$TMP/expected-api"
ALLOW_READY_API=1 SECRET_ENV="$TMP/bin/loader" SECRET_ENV_MANIFEST="$TMP/managed.manifest" \
    fish --no-config "$TMP/managed.fish"
assert_eq '0' "$?" 'newly ready API key reaches both children without server restart or parent keys'
cmp -s "$TMP/expected-api" "$TMP/child-api"
assert_eq '0' "$?" 'ready provider API key preserves exact bytes'
rm -f "$CREDENTIALS_DIRECTORY/OPENROUTER_API_KEY"
# No ready values is valid for OAuth/auth-store/local; explicit API intent is strict.
printf 'OPENROUTER_API_KEY||true\nANTHROPIC_API_KEY||false\n' >"$TMP/empty-ready.manifest"
out="$(ANTHROPIC_API_KEY=ambient OPENROUTER_API_KEY=ambient bash "$SECRET_ENV" \
    --manifest "$TMP/empty-ready.manifest" --ready --exec "$TMP/bin/showenv")"
assert_eq '0' "$?" 'zero ready keys still permits a local/OAuth consumer'
assert_not_contains "$out" 'ambient' 'all manifest keys cleared even with no ready values'
bash "$SECRET_ENV" --manifest "$TMP/empty-ready.manifest" --ready \
    --name OPENROUTER_API_KEY --exec "$TMP/bin/showenv" >"$TMP/strict-out" 2>"$TMP/strict-error"
assert_eq '3' "$?" 'explicit API credential remains required in ready mode'
assert_eq '' "$(<"$TMP/strict-out")" 'strict missing key never starts a consumer'
bash "$SECRET_ENV" --ready --name UNKNOWN_KEY --exec "$TMP/bin/showenv" >/dev/null 2>&1
assert_eq '2' "$?" 'unknown explicit name is rejected before value lookup'

_t_start "Unicode survives"
out="$(env_of UNICODE_KEY | grep -a '^UNICODE_KEY=')"
assert_contains "$out" 'æøå 日本語 🙂' 'non-ASCII bytes are preserved'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "NO CODE EXECUTION: a value cannot become code"
out="$(env_of INJECT_KEY | grep -a '^INJECT_KEY=')"
assert_contains "$out" "\$(touch $CANARY_CMD)" 'the \$(...) payload arrived as literal text'
assert_contains "$out" "$CANARY" 'and the canary prefix is part of the literal value'
assert_contains "$out" "\`touch $CANARY_BTICK\`" 'the backtick payload arrived as literal text'
assert_no_file "$CANARY_CMD" 'command substitution did NOT run'
assert_no_file "$CANARY_BTICK" 'backtick substitution did NOT run'
assert_no_file "$CANARY_RM" 'a trailing `rm -rf` in a value did NOT run'
assert_file "$TMP" 'the directory the rm targeted still exists'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "aliases are exported under every name they answer to"
out="$(env_of ALIASED_KEY)"
assert_contains "$out" 'ALIASED_KEY=aliased-value' 'the primary name is exported'
assert_contains "$out" 'GH_TOKEN=aliased-value' 'alias 1 is exported'
assert_contains "$out" 'SECRET_ALIAS_THIRD=aliased-value' 'alias 2 is exported'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "Anthropic OAuth precedence is preserved"
list="$(bash "$SECRET_ENV" --list)"
assert_not_contains "$list" 'ANTHROPIC_API_KEY' \
	'a sessionVariable=false credential is never in the session list'
envs="$(bash "$SECRET_ENV" --exec "$TMP/bin/showenv" 2>/dev/null)"
assert_not_contains "$envs" 'ANTHROPIC_API_KEY' \
	'and never reaches a process that did not ask for it by name'

# Asking for it BY NAME must still work — the exclusion is about ambient
# environment, not about making the credential unreachable.
out="$(bash "$SECRET_ENV" --name ANTHROPIC_API_KEY --exec "$TMP/bin/showenv" 2>/dev/null)"
assert_ne '' "$out" 'the credential is still available when asked for explicitly'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "absent credentials are NOT empty credentials"
printf '' >"$CREDENTIALS_DIRECTORY/EMPTY_KEY"
printf 'EMPTY_KEY||true\n' >>"$MANIFEST"
out="$(bash "$SECRET_ENV" --name EMPTY_KEY --check 2>&1)"
rc=$?
assert_eq '0' "$rc" 'an existing but empty credential file IS ready (empty is a value)'
assert_contains "$out" 'ready' 'and is reported as ready'

out="$(bash "$SECRET_ENV" --name MISSING_KEY --exec "$TMP/bin/showenv" 2>&1 >/dev/null)"
rc=$?
assert_eq '3' "$rc" 'a missing credential exits 3, not 0'
assert_contains "$out" 'absent' 'and says "absent", not "empty"'
assert_not_contains "$out" 'MISSING_KEY=' 'and exports nothing at all for it'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "delayed decryption is recoverable, not cached as a failure"
rm -f "$CREDENTIALS_DIRECTORY/DELAYED_KEY"
printf 'DELAYED_KEY||true\n' >>"$MANIFEST"
out="$(bash "$SECRET_ENV" --name DELAYED_KEY --check 2>&1)"
assert_contains "$out" 'ABSENT' 'before sops-nix runs, it reports ABSENT'
# sops-nix finishes a moment later
printf 'delayed-value' >"$CREDENTIALS_DIRECTORY/DELAYED_KEY"
out="$(bash "$SECRET_ENV" --name DELAYED_KEY --exec "$TMP/bin/showenv" 2>/dev/null | grep -a '^DELAYED_KEY=')"
assert_eq 'DELAYED_KEY=delayed-value' "$out" 'once the file appears, the same call succeeds'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "an embedded NUL is refused, never truncated"
out="$(bash "$SECRET_ENV" --name NUL_KEY --exec "$TMP/bin/showenv" 2>&1)"
rc=$?
assert_eq '4' "$rc" 'a NUL byte exits 4 (distinct from absent and from ok)'
assert_contains "$out" 'NUL byte' 'and says why'
assert_not_contains "$out" 'NUL_KEY=a' 'no truncated value was handed over'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "names are validated before anything is read"
for bad in 'BAD-NAME' '1LEADING_DIGIT' 'HAS SPACE' '$(id)' '../escape' ''; do
	out="$(bash "$SECRET_ENV" --name "$bad" --check 2>&1)"
	rc=$?
	assert_eq '2' "$rc" "name '$bad' is rejected with a usage exit"
done

# A malformed manifest must fail loudly rather than silently dropping
# credentials — the field count is checked, not trusted.
printf 'ONLY|TWO\n' >"$TMP/bad.manifest"
out="$(bash "$SECRET_ENV" --manifest "$TMP/bad.manifest" --check 2>&1)"
rc=$?
assert_eq '2' "$rc" 'a malformed manifest line is a hard error'
assert_contains "$out" 'expected 3' 'and names the shape it expected'

printf 'NAME||maybe\n' >"$TMP/bad2.manifest"
out="$(bash "$SECRET_ENV" --manifest "$TMP/bad2.manifest" --check 2>&1)"
assert_contains "$out" "SESSION must be" 'a non-boolean session flag is a hard error'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "secrets never appear in a process argument list"
# `env -i NAME=VALUE` puts every secret in the argv of the `env` process, which
# any other local user can read from /proc/<pid>/cmdline or ps. The header
# claimed otherwise; this is the test that makes it true.
_argv_capture() {
	# `exec -a` is not needed: /proc/self/cmdline of the child is what leaks, so
	# read the child's own view of its argv.
	printf '%s\0' "$@" | tr '\0' ' '
}
ARGV_PROBE="$TMP/bin/argv-probe"
{
	printf '#!%s\n' "$(command -v bash)"
	printf 'for a in "$@"; do printf "%%s\\n" "$a"; done\n'
	printf 'printf -- "---CMDLINE---\\n"\n'
	printf 'tr "\\0" "\\n" < /proc/self/cmdline\n'
} >"$ARGV_PROBE"
chmod +x "$ARGV_PROBE"

out="$(bash "$SECRET_ENV" --name INJECT_KEY --exec "$ARGV_PROBE" "arg-one" "arg-two" 2>/dev/null)"
assert_not_contains "$out" 'CANARY' 'no secret value appears in the child argv'
assert_contains "$out" 'arg-one' 'and the child did receive its real arguments'
assert_contains "$out" '---CMDLINE---' 'the /proc/self/cmdline view was captured'
cmdline_part="$(sed -n '/---CMDLINE---/,$p' <<<"$out")"
assert_not_contains "$cmdline_part" 'CANARY' 'nor in /proc/self/cmdline'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the caller's environment survives; only credentials are scoped"
# `env -i` also cleared TERM, LANG, USER, SSH_AUTH_SOCK and XDG_RUNTIME_DIR, so
# `ns-secrets run pi` started a terminal program with no terminal and git over
# SSH with no agent. Scoping means "these credentials", not "no environment".
out="$(TERM=xterm-256color LANG=en_US.UTF-8 SSH_AUTH_SOCK=/tmp/agent.sock \
	bash "$SECRET_ENV" --name PLAIN_KEY --exec "$TMP/bin/showenv" 2>/dev/null)"
assert_contains "$out" 'TERM=xterm-256color' 'TERM survives (a terminal program still has a terminal)'
assert_contains "$out" 'LANG=en_US.UTF-8' 'LANG survives'
assert_contains "$out" 'SSH_AUTH_SOCK=/tmp/agent.sock' 'SSH_AUTH_SOCK survives'
assert_contains "$out" 'PLAIN_KEY=sk-or-v1-plainvalue' 'and the requested credential is present'

# ...while a DIFFERENT credential already in the environment is NOT inherited.
out="$(OPENROUTER_API_KEY=inherited-secret \
	bash "$SECRET_ENV" --name PLAIN_KEY --exec "$TMP/bin/showenv" 2>/dev/null)"
assert_not_contains "$out" 'inherited-secret' \
	'a credential that was not requested is removed from the environment'
assert_contains "$out" 'PLAIN_KEY=sk-or-v1-plainvalue' 'and the requested one is still there'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the readiness report carries names and booleans, never values"
report="$(bash "$SECRET_ENV" --format=json 2>/dev/null)"
assert_contains "$report" '"ready":true' 'ready credentials are reported as true'
assert_contains "$report" 'ANTHROPIC_API_KEY' 'every credential is named'
for canary in 'sk-or-v1-plainvalue' 'aliased-value' 'delayed-value' 'line one' 'æøå'; do
	assert_not_contains "$report" "$canary" "the readiness report does not contain the value '$canary'"
done
assert_not_contains "$report" "$(printf 'a\0b')" 'and not the NUL-bearing value'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "no plaintext value reaches any log or listing"
lists="$(
	bash "$SECRET_ENV" --list
	bash "$SECRET_ENV" --check
	bash "$SECRET_ENV" --format=json
	bash "$SECRET_ENV" --exec /bin/echo hello
)"
for canary in 'sk-or-v1-plainvalue' 'aliased-value' 'delayed-value' 'line one'; do
	assert_not_contains "$lists" "$canary" "listing/check output does not leak '$canary'"
done

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the loader is idempotent under repeated invocation"
first="$(env_of PLAIN_KEY)"
second="$(env_of PLAIN_KEY)"
assert_eq "$first" "$second" 'two runs produce the same environment'

assert_no_reboot "$TMP/reboots"
summary