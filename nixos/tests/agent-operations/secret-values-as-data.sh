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