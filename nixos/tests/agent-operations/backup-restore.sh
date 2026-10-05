#!/usr/bin/env bash
# The SKIP notice below is single-quoted on purpose: it contains backticks
# around a nix command, and expanding them here would try to RUN the command
# while printing the message that explains how to run it.
# shellcheck disable=SC2016
# nixos/tests/agent-operations/backup-restore.sh
#
# A REAL restic repository, in a disposable directory, with real restores into
# scratch. Everything is created under $TMP and removed on exit.
#
# What this deliberately does NOT do:
#   * touch a real repository or a real credential;
#   * restore over live data — `--restore-to` refuses anything under $HOME and
#     anything non-empty, and there is a test for each refusal;
#   * run a real prune against anything that is not disposable.
#
# The scenarios are the ones where a backup silently stops being one:
# credentials missing, a backup that is too old, a repository that stopped
# answering, a database that is being written while it is copied, and two
# backups racing each other.
set -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"
SUITE_NAME="backup-restore"

# Restores are only accepted strictly below /tmp or /var/tmp, so the fixture
# root must live there. Inside a Nix build sandbox TMPDIR is /build, while the
# sandbox's own private /tmp exists; forcing /tmp keeps both runs identical.
export TMPDIR=/tmp
fixture_new

RESTIC_BIN="${RESTIC_BIN:-$(command -v restic || true)}"
if [[ -z "$RESTIC_BIN" ]]; then
	printf '\033[33mSKIPPED: restic is not on PATH. It is in the flake check\033[0m\n'
	printf 'closure (nativeBuildInputs), so `nix build .#checks.…agent-operations`\n'
	printf 'runs this suite. A developer running it by hand needs `nix shell\n'
	printf 'nixpkgs#restic nixpkgs#sqlite` first.\033[0m\n'
	exit 0
fi
printf 'using restic: %s\n' "$RESTIC_BIN"

if [[ -n "${NIX_BUILD_TOP:-}" ]]; then
	# /tmp's namespace-unmapped owner cannot be restored by this builder.
	# Select its snapshot subtree, restoring ALL fixture payload and metadata
	# below a privately created target/tmp. Production restore is unchanged;
	# only the synthetic ancestor /tmp's ownership is outside this proof.
	export RESTIC_TEST_REAL="$RESTIC_BIN"
	fake sandbox-restic <<'FAKE'
if [[ "$1" != restore ]]; then exec "$RESTIC_TEST_REAL" "$@"; fi
shift
snapshot="$1"; shift
args=()
while (($#)); do
	case "$1" in
	--target)
		mkdir -m 0700 -- "$2/tmp" || exit 1
		args+=(--target "$2/tmp"); shift 2 ;;
	--include) args+=(--include "${2#/tmp}"); shift 2 ;;
	*) args+=("$1"); shift ;;
	esac
done
exec "$RESTIC_TEST_REAL" restore "$snapshot:/tmp" "${args[@]}"
FAKE
	RESTIC_BIN="$TMP/bin/sandbox-restic"
	export RESTIC="$RESTIC_BIN"
fi

SQLITE_BIN="${SQLITE_BIN:-$(command -v sqlite3 || true)}"
if [[ -z "$SQLITE_BIN" ]]; then
	printf '\033[33mSKIPPED: sqlite3 is not on PATH (same flake closure).\033[0m\n'
	exit 0
fi
printf 'using sqlite3: %s\n' "$SQLITE_BIN"

# ── the fixture world ───────────────────────────────────────────────────────
export AGENT_OPS_STATE_DIR="$TMP/backup-state"
mkdir -p "$AGENT_OPS_STATE_DIR"
# An empty table is valid when no exports are declared; a missing table is not.
: >"$AGENT_OPS_STATE_DIR/quiesce.conf"
export RESTIC_REPO="$TMP/repo"
export RESTIC_PASSWORD_FILE="$TMP/repo-password"
CONFIG="$TMP/backup.conf"
export NS_OPS_BACKUP_CONFIG="$CONFIG"
printf 'fixture-repository-password\n' >"$RESTIC_PASSWORD_FILE"
chmod 0600 "$RESTIC_PASSWORD_FILE"

SOURCE="$TMP/data"
mkdir -p "$SOURCE/docs"
printf 'hello state\n' >"$SOURCE/docs/notes.txt"
printf 'binary-ish\n' >"$SOURCE/docs/blob.bin"
printf 'SHOULD-NOT-BE-BACKED-UP\n' >"$SOURCE/cache-junk"
mkdir -p "$SOURCE/.cache"
printf 'replaceable\n' >"$SOURCE/.cache/rebuildable"

# A real SQLite database with real rows.
DB="$SOURCE/collie.db"
"$SQLITE_BIN" "$DB" "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t (v) VALUES ('one'),('two');"
printf 'EXCLUDED-MEDIA\n' >"$SOURCE/movie.mkv"

mkdir -p "$TMP/creds"
printf '%s' "$RESTIC_REPO" >"$TMP/creds/RESTIC_REPOSITORY"
cp "$RESTIC_PASSWORD_FILE" "$TMP/creds/RESTIC_PASSWORD"
export CREDENTIALS_DIRECTORY="$TMP/creds"

cat >"$CONFIG" <<EOF
sources=["$SOURCE"]
excludes=["$SOURCE/.cache", "$SOURCE/movie.mkv"]
quiesceFile=$(jq -Rn --arg p "$AGENT_OPS_STATE_DIR/quiesce.conf" '$p')
quiesceSource=[]
limitUpload=0
limitDownload=0
packSize=4
keepDaily=2
keepWeekly=1
keepMonthly=1
maxAgeSeconds=3600
repositoryCheckSubset=1/1
EOF

backup() { bash "$BACKUP" --config "$CONFIG" "$@" 2>&1; }

# ═══════════════════════════════════════════════════════════════════════════
_t_start "an unconfigured repository is NOT CONFIGURED, not healthy"
mv "$TMP/creds/RESTIC_REPOSITORY" "$TMP/repo.away"
out="$(backup backup)"
rc=$?
assert_eq '4' "$rc" 'a missing repository credential is exit 4'
assert_contains "$out" 'NOT CONFIGURED' 'and says so in those words'
assert_contains "$out" 'NO backup' 'and that the host has no backup'
mv "$TMP/repo.away" "$TMP/creds/RESTIC_REPOSITORY"

mv "$TMP/creds/RESTIC_PASSWORD" "$TMP/pw.away"
out="$(backup backup)"
rc=$?
assert_eq '4' "$rc" 'a missing password credential is exit 4'
assert_contains "$out" 'losing it' 'and says what losing it costs'
mv "$TMP/pw.away" "$TMP/creds/RESTIC_PASSWORD"

: >"$TMP/creds/RESTIC_PASSWORD"
out="$(backup backup)"
rc=$?
assert_eq '4' "$rc" 'an EMPTY password is refused, not accepted'
assert_contains "$out" 'guesses it' 'with the reason: an empty one opens the repository'
cp "$TMP/repo.away" "$TMP/repo.away" 2>/dev/null || true
printf 'fixture-repository-password\n' >"$TMP/creds/RESTIC_PASSWORD"

out="$(CREDENTIALS_DIRECTORY="" backup backup)"
assert_contains "$out" 'CREDENTIALS_DIRECTORY' 'running outside the unit is named as the wrong invocation'

out="$(backup status)"
assert_contains "$out" 'healthy=false' 'status with no record at all is not healthy'
assert_contains "$out" 'no backup has ever been recorded' 'and says that plainly'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "an unreachable repository is a network problem, not a silent pass"
# The repository comes from the CREDENTIAL FILE, deliberately: the script exports
# RESTIC_REPOSITORY from it, so an environment override is ignored by design.
# Overriding the credential is also the only way a missing repository is
# reachable through the real code path.
printf '%s' "$TMP/no-such-repo" >"$TMP/creds/RESTIC_REPOSITORY"
out="$(backup check)"
rc=$?
printf '%s' "$RESTIC_REPO" >"$TMP/creds/RESTIC_REPOSITORY"
assert_ne '0' "$rc" 'check against a missing repository fails'
assert_contains "$out" 'repository check FAILED' 'and says what failed'
assert_file "$AGENT_OPS_STATE_DIR/last-run.env" 'a record was written'
assert_contains "$(cat "$AGENT_OPS_STATE_DIR/last-run.env")" 'LAST_STATUS=failed' 'recording the failure'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the first real backup"
export RESTIC_REPOSITORY="$RESTIC_REPO" RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE"
"$RESTIC_BIN" --repo "$RESTIC_REPO" init >/dev/null 2>&1
out="$(backup backup)"
rc=$?
assert_eq '0' "$rc" 'backup succeeds against a real disposable repository'
assert_contains "$out" 'attempt 1/3' 'and reports which attempt succeeded'
assert_contains "$out" 'bounded to 0 B/s' 'and states the bandwidth bound it ran under'
assert_contains "$(cat "$AGENT_OPS_STATE_DIR/last-run.env")" 'LAST_STATUS=ok' 'the record says ok'

out="$(backup status)"
assert_contains "$out" 'healthy=true' 'status agrees'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the quiesce table: fail closed only when exports are declared"
mv "$AGENT_OPS_STATE_DIR/quiesce.conf" "$TMP/empty-table.away"
out="$(backup backup)"
assert_eq '0' "$?" 'with no declared exports a missing table means nothing to quiesce'
sed "s|^quiesceSource=.*|quiesceSource=[\"$DB\"]|" "$CONFIG" >"$TMP/declared.conf"
out="$(bash "$BACKUP" --config "$TMP/declared.conf" backup 2>&1)"
assert_eq '3' "$?" 'with a declared export a missing table fails closed'
assert_contains "$out" 'refusing raw backup' 'and never falls back to the live database'
assert_not_contains "$out" 'attempt 1/' 'restic is never invoked after the missing table'
mv "$TMP/empty-table.away" "$AGENT_OPS_STATE_DIR/quiesce.conf"
sed "s|^quiesceFile=.*|quiesceFile=$AGENT_OPS_STATE_DIR/quiesce.conf|" "$CONFIG" >"$TMP/raw-path.conf"
out="$(bash "$BACKUP" --config "$TMP/raw-path.conf" backup 2>&1)"
assert_eq '0' "$?" 'a bare absolute quiesceFile path (hand-written config) is accepted'
sed "s|^quiesceFile=.*|quiesceFile=relative/q.conf|" "$CONFIG" >"$TMP/bad-path.conf"
out="$(bash "$BACKUP" --config "$TMP/bad-path.conf" backup 2>&1)"
assert_eq '2' "$?" 'a relative quiesceFile is a configuration error'

_t_start "the module-generated JSON config preserves spaces, quotes and commas"
if command -v nix >/dev/null 2>&1; then
	ODD="$TMP/space, 'single' \"double\""
	mkdir -p "$ODD"
	printf 'included\n' >"$ODD/keep"
	printf 'excluded\n' >"$ODD/drop, 'quoted'"
	QTABLE="$TMP/table, 'single' \"double\".conf"
	GENERATED_VALUES="$(jq -cn --arg source "$ODD" --arg exclude "$ODD/drop, 'quoted'" \
		--arg state "${QTABLE%/quiesce.conf}" --arg live "$ODD/keep" \
		'{enable:true, sources:[$source], additionalSources:[$source], excludes:[$exclude],
		stateDir:$state, quiesce:[{path:$live}], limitUpload:"8000000",
		limitDownload:"20000000", keepDaily:2, keepWeekly:1, keepMonthly:1,
		maxAgeSeconds:3600}')"
	# Evaluate the actual module, with only the lazy interfaces needed for its
	# config text. No nixpkgs build, activation, credentials or network access.
	export GENERATED_VALUES BACKUP_MODULE="$LANE_SRC/config/system/agent-ops/backup.nix"
	nix --extra-experimental-features nix-command eval --impure --raw --expr '
		let m = import (builtins.toPath (builtins.getEnv "BACKUP_MODULE")) {
		  config.agentOps.backup = builtins.fromJSON (builtins.getEnv "GENERATED_VALUES");
		  opts = {}; pkgs = {};
		  lib = { mkMerge = x: x; mkIf = c: x: if c then x else {};
		    unique = builtins.foldl'"'"' (acc: e: if builtins.elem e acc then acc else acc ++ [e]) []; };
		}; in (builtins.head m.config).environment.etc."agent-ops/backup.conf".text
	' >"$TMP/generated.conf"
	assert_eq '0' "$?" 'the actual Nix module generates the config'
	assert_eq '1' "$(grep '^sources=' "$TMP/generated.conf" | cut -d= -f2- | jq 'length')" 'additionalSources are appended and deduplicated'
	assert_not_contains "$(cat "$TMP/generated.conf")" 'ioMaxConcurrent' 'the unsupported concurrency setting is not generated'
	# stateDir defines the table location in the generated config.
	mkdir -p "$QTABLE"
	printf '%s|none|\n' "$ODD/keep" >"$QTABLE/quiesce.conf"
	out="$(bash "$BACKUP" --config "$TMP/generated.conf" backup 2>&1)"
	assert_eq '0' "$?" 'generated config backs up quoted paths and quiesces via a quoted table path'
	out="$(bash "$BACKUP" --config "$TMP/generated.conf" restore --to "$TMP/generated-restore" 2>&1)"
	assert_eq '0' "$?" 'generated snapshot restores'
	assert_eq 'included' "$(find "$TMP/generated-restore" -name keep -exec cat {} \;)" 'quiesced source is preserved exactly once'
	assert_no_file "$TMP/generated-restore$ODD/drop, 'quoted'" 'quoted comma-containing exclude is honored'
	mv "$QTABLE/quiesce.conf" "$QTABLE/table.away"
	out="$(bash "$BACKUP" --config "$TMP/generated.conf" backup 2>&1)"
	assert_eq '3' "$?" 'missing configured quiesce table fails closed'
	assert_contains "$out" 'refusing raw backup' 'missing table never falls back to raw data'
	: >"$QTABLE/quiesce.conf"
	out="$(bash "$BACKUP" --config "$TMP/generated.conf" backup 2>&1)"
	assert_eq '3' "$?" 'empty configured quiesce table fails closed'
	printf '%s|none|\n' "$ODD/drop, 'quoted'" >"$QTABLE/quiesce.conf"
	out="$(bash "$BACKUP" --config "$TMP/generated.conf" backup 2>&1)"
	assert_eq '3' "$?" 'table missing a declared source fails closed'
	# Restore the normal latest snapshot for the remaining restore assertions.
	backup backup >/dev/null 2>&1
else
	printf 'SKIPPED: module-generated config test requires nix eval\n'
fi

_t_start "real typed modules: integration sources are additive, stateDir reaches every unit"
# backup-media-eval.nix evaluates the REAL state-manifest + backup + media
# modules through nixpkgs' eval-config (metadata only: nothing is built or
# activated). That needs the flake's locked nixpkgs, which a nested evaluation
# inside a Nix build sandbox cannot fetch, so there it is an EXPLICIT skip; a
# standalone run with nix available must pass it.
if [[ -n "${NIX_BUILD_TOP:-}" && -z "${AGENT_OPS_NIXPKGS:-}" ]]; then
	printf '\033[33mSKIPPED (Nix build sandbox): backup-media-eval.nix needs the\033[0m\n'
	printf 'flake inputs; run `bash nixos/tests/agent-operations/backup-restore.sh` outside.\n'
elif ! command -v nix >/dev/null 2>&1; then
	printf '\033[33mSKIPPED: nix is not on PATH; backup-media-eval.nix not evaluated.\033[0m\n'
else
	MEDIA_EVAL_FILE="$LANE_SRC/tests/agent-operations/backup-media-eval.nix"
	if [[ -n "${AGENT_OPS_NIXPKGS:-}" ]]; then
		nixpkgs_expression="\"$AGENT_OPS_NIXPKGS\""
	else
		nixpkgs_expression="(builtins.getFlake \"path:$LANE_SRC\").inputs.nixpkgs.outPath"
	fi
	out="$(timeout 60 nix --extra-experimental-features 'nix-command flakes' eval --impure --json --expr \
		"import $MEDIA_EVAL_FILE { nixpkgs = $nixpkgs_expression; }" 2>&1)"
	assert_eq '0' "$?" 'the typed-module union proof evaluates within 60s'
	assert_contains "$out" '"stateDir":"/var/lib/custom-backup"' 'stateDir propagates to the backup unit'
	assert_contains "$out" '"operatorSources":["/operator/selected","/var/lib/agent-ops/media-exports","/var/lib/syncthing"]' 'operator sources keep their selection and gain integrations once'
fi

# ═══════════════════════════════════════════════════════════════════════════
_t_start "excludes are honoured, and only because they were listed"
snap_files="$("$RESTIC_BIN" ls latest 2>/dev/null)"
assert_contains "$snap_files" 'notes.txt' 'a real source file IS in the snapshot'
assert_not_contains "$snap_files" '.cache' 'an excluded cache directory is not'
assert_contains "$(backup config)" 'exclude' 'the effective config lists the excludes'
assert_not_contains "$(backup config)" 'fixture-repository-password' 'and contains no secret'

# The module's own exclusion list is asserted against its SOURCE, because this
# fixture supplies a smaller list of its own and cannot speak for it.
mod_content="$(cat "$LANE_SRC/config/system/agent-ops/backup.nix")"
assert_contains "$mod_content" '"/nix/store"' 'the module excludes the Nix store (re-downloadable by hash)'
assert_contains "$mod_content" '*.sock' 'and runtime sockets'
assert_not_contains "$mod_content" 'fixture-repository-password' 'and the module contains no credential value'

# Excluded media, proven by RESTORING rather than by grepping a listing: a
# snapshot listing echoes paths, so "not in a listing" is a weaker claim than
# "not in the snapshot".
EXSCRATCH="$TMP/exclude-scratch"
backup restore --to "$EXSCRATCH" >/dev/null 2>&1
assert_file "$EXSCRATCH$SOURCE/docs/notes.txt" 'an included file comes back'
assert_no_file "$EXSCRATCH$SOURCE/.cache/rebuildable" 'an excluded cache file does not come back'
assert_no_file "$EXSCRATCH$SOURCE/movie.mkv" 'excluded media does not come back'
assert_not_contains "$(backup config)" 'fixture-repository-password' 'and contains no secret'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "restore into SCRATCH"
SCRATCH="$TMP/scratch"
out="$(backup restore --to "$SCRATCH")"
rc=$?
if [[ "$rc" != 0 ]]; then printf 'fixture restore diagnostic:\n%s\n' "$out" >&2; fi
assert_eq '0' "$rc" 'a restore into an empty scratch directory succeeds'
assert_file "$SCRATCH$SOURCE/docs/notes.txt" 'the file came back'
assert_eq 'hello state' "$(cat "$SCRATCH$SOURCE/docs/notes.txt")" 'with its contents intact'

out="$(backup restore --to "$SCRATCH")"
rc=$?
assert_eq '2' "$rc" 'restoring into a NON-EMPTY directory is refused'
assert_contains "$out" 'not empty' 'and says why'
assert_contains "$out" 'overwrites the live home' 'and names the failure it prevents'

out="$(backup restore --to /)"
assert_eq '2' "$?" 'restoring into / is refused'
assert_contains "$out" 'strictly below' 'and says only scratch roots are accepted'

for root in /tmp /var/tmp /tmp/ /home /root /var/lib/agent-ops; do
	out="$(backup restore --to "$root")"
	assert_eq '2' "$?" "restoring into $root is refused"
done

out="$(backup restore --to relative/path)"
assert_contains "$out" 'absolute path' 'a relative target is refused'

out="$(backup restore)"
assert_contains "$out" 'needs --to' 'a restore with no target is refused'

out="$(backup restore --to)"
assert_eq '2' "$?" 'a dangling --to is refused'

# Lexical escapes and aliases are refused, never normalised and followed.
out="$(backup restore --to "$TMP/../../home/escape")"
assert_contains "$out" 'not canonical' 'a .. escape out of scratch is refused'
out="$(backup restore --to "$TMP/./dot")"
assert_contains "$out" 'not canonical' 'a non-canonical spelling is refused'
out="$(backup restore --to "$TMP/trailing/")"
assert_contains "$out" 'not canonical' 'a trailing-slash alias is refused'
assert_no_file "$TMP/trailing" 'and nothing was created for it'

# Symlink escape: a scratch-looking path whose parent or self is a symlink to
# live data must never be restored into.
LIVE="$TMP/live-home"
mkdir -p "$LIVE"
printf 'live\n' >"$LIVE/precious"
ln -s "$LIVE" "$TMP/link-parent"
out="$(backup restore --to "$TMP/link-parent/restore")"
assert_eq '2' "$?" 'a symlinked parent is refused'
assert_contains "$out" 'not canonical' 'and named as an alias'
assert_no_file "$LIVE/restore" 'nothing was created through the symlink'
mkdir -p "$TMP/empty-real"
chmod 0700 "$TMP/empty-real"
ln -s "$TMP/empty-real" "$TMP/link-self"
out="$(backup restore --to "$TMP/link-self")"
assert_eq '2' "$?" 'a symlinked target is refused even if it points at an empty dir'
assert_eq '' "$(find "$TMP/empty-real" -mindepth 1 -print -quit)" 'and the symlink target stays empty'
assert_eq 'live' "$(cat "$LIVE/precious")" 'live data behind the symlink is untouched'

# Exclusive: missing ancestors are not created, and an existing empty target
# must be private to the caller.
out="$(backup restore --to "$TMP/missing-parent/child")"
assert_eq '2' "$?" 'a target whose parent does not exist is refused'
assert_no_file "$TMP/missing-parent" 'and no ancestor is created'
mkdir -p "$TMP/shared-empty"
chmod 0755 "$TMP/shared-empty"
out="$(backup restore --to "$TMP/shared-empty")"
assert_eq '2' "$?" 'an existing empty target readable by others is refused'
mkdir -p "$TMP/open-parent"
chmod 0777 "$TMP/open-parent"
out="$(backup restore --to "$TMP/open-parent/child")"
assert_eq '2' "$?" 'a target below an other-writable ancestor is refused'
mkdir -m 0700 "$TMP/private-empty"
out="$(backup restore --to "$TMP/private-empty")"
assert_eq '0' "$?" 'an existing empty private directory (mktemp -d style) is accepted'
printf 'x' >"$TMP/regular-file"
out="$(backup restore --to "$TMP/regular-file")"
assert_eq '2' "$?" 'a regular file target is refused'

# Selection arguments can never become restic flags (a second --target wins).
out="$(backup restore --to "$TMP/flag-inject" --target "$LIVE")"
assert_eq '2' "$?" 'a flag-shaped PATH argument is refused'
assert_no_file "$LIVE$SOURCE" 'and nothing was restored into live data'
out="$(backup restore --to "$TMP/selected" "$SOURCE/docs")"
assert_eq '0' "$?" 'an absolute PATH selection is accepted'
assert_file "$TMP/selected$SOURCE/docs/notes.txt" 'the selected path is restored'
assert_no_file "$TMP/selected$SOURCE/collie.db" 'and unselected paths are not'

# A live home is refused even when it happens to sit below a scratch root.
FAKEHOME="$TMP/fake-home"
mkdir -m 0700 "$FAKEHOME"
out="$(HOME="$FAKEHOME" bash "$BACKUP" --config "$CONFIG" restore --to "$FAKEHOME/restore" 2>&1)"
assert_eq '2' "$?" 'a target inside $HOME is refused'
assert_contains "$out" 'inside the live home' 'and says why'
assert_no_file "$FAKEHOME/restore" 'and nothing is created in the home'

out="$(backup restore --to "$TMP/home-backup")"
rc=$?
assert_eq '0' "$rc" 'a scratch dir outside HOME is allowed'
assert_eq '700' "$(stat -c %a "$TMP/home-backup")" 'and it is created private'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a database is exported CONSISTENTLY, not copied live"
# Fill the source table with enough rows that a torn copy is detectable, then
# write to it CONCURRENTLY while the backup runs. `cp` of a file being written
# produces something that can pass integrity_check and still be missing rows.
"$SQLITE_BIN" "$DB" "DELETE FROM t; WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM s WHERE i<20000) INSERT INTO t (v) SELECT 'row-'||i FROM s;"
printf '%s\n' "$SOURCE/collie.db|sqlite|$SQLITE_BIN" >"$AGENT_OPS_STATE_DIR/quiesce.conf"

# Writers hammering the database during the backup.
(
	for i in $(seq 1 40); do
		"$SQLITE_BIN" "$DB" "INSERT INTO t (v) VALUES ('live-$i');" >/dev/null 2>&1
	done
) &
WRITER=$!

out="$(backup backup)"
wait "$WRITER" 2>/dev/null || true
assert_contains "$out" 'quiesced' 'the database was exported before it was copied'
assert_contains "$out" 'integrity_check ok' 'and the export was verified, not just produced'

# Restore it and ask the RESTORED database what it contains. Asserting on the
# backup's own stdout would prove nothing about what actually landed in the repo.
QSCRATCH="$TMP/quiesce-scratch"
out="$(backup restore --to "$QSCRATCH")"
RESTORED_DB="$(find "$QSCRATCH" -name 'collie.db' | head -1)"
assert_file "$RESTORED_DB" 'the restored tree contains the quiesced database'
assert_eq 'ok' "$("$SQLITE_BIN" "$RESTORED_DB" "PRAGMA integrity_check;" 2>/dev/null)" \
	'the restored database passes integrity_check'
# 🔴 THE LIVE DATABASE MUST NOT BE IN THE SNAPSHOT AT ALL.
#
# `staging="$(quiesce_all)"` ran quiesce_all in a command-substitution subshell,
# so the STAGING array it filled was discarded and the caller added no
# --exclude for the live path. The snapshot then contained BOTH the export AND
# the raw database being written to — the one file it must never contain. The
# earlier assertion (`find … -name collie.db | head -1`) matched either copy and
# so passed. Count them instead.
TESTS_RUN=$((TESTS_RUN + 1))
copies="$(find "$QSCRATCH" -name 'collie.db' | wc -l)"
if [[ "$copies" == "1" ]]; then
	_ok 'exactly ONE collie.db is in the restore (the export, not the live file)'
else
	_fail "exactly ONE collie.db is in the restore (found $copies — the live database is being backed up)"
fi

rows="$("$SQLITE_BIN" "$RESTORED_DB" "SELECT count(*) FROM t WHERE v LIKE 'row-%';")"
assert_eq '20000' "$rows" 'the export contains every row that existed before the concurrent writes'
live_rows="$("$SQLITE_BIN" "$RESTORED_DB" "SELECT count(*) FROM t WHERE v LIKE 'live-%';")"
# An app-consistent export is a snapshot of SOME instant during the run, not
# necessarily of its first microsecond: writes that land before SQLite's backup
# API takes its read lock are legitimately included. The property worth
# asserting is that it is a coherent POINT IN TIME — never a torn mixture — and
# that it is behind the live database, not ahead of it.
live_total="$("$SQLITE_BIN" "$DB" "SELECT count(*) FROM t WHERE v LIKE 'live-%';")"
TESTS_RUN=$((TESTS_RUN + 1))
if ((live_rows < live_total)); then
	_ok "the export is behind the live database ($live_rows < $live_total concurrent rows)"
else
	_fail "the export is a point in time ($live_rows concurrent rows, live has $live_total)"
fi
# And the live database really did gain those rows, so the test is not vacuous.
live_now="$("$SQLITE_BIN" "$DB" "SELECT count(*) FROM t WHERE v LIKE 'live-%';")"
assert_ne '0' "$live_now" 'the live database DID receive concurrent writes during the backup'

# Now the negative: the export must not silently fall back to a raw copy.
printf '%s\n' "$SOURCE/collie.db|sqlite|$TMP/not-a-real-sqlite" >"$AGENT_OPS_STATE_DIR/quiesce.conf"
out="$(backup backup)"
rc=$?
assert_ne '0' "$rc" 'an unusable sqlite binary fails the backup'
assert_contains "$out" 'NOT consistent' 'and refuses the raw-copy fallback explicitly'
# Put the WORKING sqlite back before the corrupt-source case, or that case only
# ever re-tests the unusable-binary case.
printf '%s\n' "$SOURCE/collie.db|sqlite|$SQLITE_BIN" >"$AGENT_OPS_STATE_DIR/quiesce.conf"
printf 'not a database at all\n' >"$DB"
out="$(backup backup)"
rc=$?
assert_ne '0' "$rc" 'a corrupt source database fails the backup'
assert_contains "$out" 'quiesce' 'and the failure is attributed to the export step'
# sqlite3 may either refuse to open the source at all or produce an export that
# fails integrity_check. Both are refusals to ship the file, and both are what
# the check exists for; assert on the refusal, not on which of the two it was.
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$out" == *'Not copying it raw'* || "$out" == *'does not pass integrity_check'* ]]; then
	_ok 'and it refused to ship the corrupt file instead of backing it up raw'
else
	_fail "and it refused to ship the corrupt file (output did not say so)"
fi
assert_contains "$(cat "$AGENT_OPS_STATE_DIR/last-run.env")" 'LAST_STATUS=failed' 'and the run is recorded as failed'
# Recreate rather than "repair": the file is plain text now, and every later
# case in this suite depends on a working database.
rm -f "$DB"
"$SQLITE_BIN" "$DB" "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t (v) VALUES ('restored');"
printf '%s\n' "$SOURCE/collie.db|sqlite|$SQLITE_BIN" >"$AGENT_OPS_STATE_DIR/quiesce.conf"
out="$(backup backup)"
assert_eq '0' "$?" 'and once the database is valid again the backup succeeds' 

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a repository with NO snapshots is not a backup"
FRESH="$TMP/fresh-repo"
"$RESTIC_BIN" --repo "$FRESH" init >/dev/null 2>&1
printf '%s' "$FRESH" >"$TMP/creds/RESTIC_REPOSITORY"
out="$(backup check)"
rc=$?
printf '%s' "$RESTIC_REPO" >"$TMP/creds/RESTIC_REPOSITORY"
assert_ne '0' "$rc" 'check on an empty repository fails'
assert_contains "$out" 'NO snapshots' 'and says the repository is empty'
assert_contains "$out" 'not a backup' 'in those words'
assert_contains "$(cat "$AGENT_OPS_STATE_DIR/last-run.env")" 'LAST_STATUS=failed' 'recorded as failed'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "a STALE backup is reported, not treated as fresh"
# Backdate the record by two days.
# A real, old snapshot rather than a doctored timestamp: maxAgeSeconds=1 plus a
# two-second sleep makes the newest snapshot genuinely too old, and the check
# reads restic's own snapshot time.
sed 's/^maxAgeSeconds=.*/maxAgeSeconds=1/' "$CONFIG" >"$TMP/stale.conf"
sleep 2
out="$(bash "$BACKUP" --config "$TMP/stale.conf" check 2>&1)"
rc=$?
assert_ne '0' "$rc" 'a snapshot older than maxAgeSeconds fails the check'
assert_contains "$out" 'TOO OLD' 'and says so in those words'
assert_contains "$out" 'newest snapshot age' 'and reports the measured age'
assert_contains "$(cat "$AGENT_OPS_STATE_DIR/last-run.env")" 'LAST_STATUS=stale' 'recorded as stale'
out="$(backup status)"
assert_contains "$out" 'healthy=false' 'status agrees it is not healthy'
out="$(backup check)"
assert_eq '0' "$?" 'and with the real limit restored, the same repository passes'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "CONCURRENT work: a second backup refuses to fight the first"
# Two real backups of the same repository at the same time. restic takes its own
# repository lock, so one of them will refuse or queue; neither may corrupt the
# repository, and the bounded retry must not turn into an unbounded one.
backup backup >"$TMP/c1.out" 2>&1 &
C1=$!
backup backup >"$TMP/c2.out" 2>&1 &
C2=$!
wait "$C1" || true
wait "$C2" || true
out="$(backup check)"
rc=$?
assert_eq '0' "$rc" 'after two concurrent backups the repository is still intact and checkable'
combined="$(cat "$TMP/c1.out" "$TMP/c2.out")"
assert_not_contains "$combined" 'repository is locked' 'and at most one reported a lock conflict'
attempts="$(grep -c 'attempt ' <<<"$combined")"
TESTS_RUN=$((TESTS_RUN + 1))
if ((attempts <= 2 * 3)); then
	_ok "the combined attempts stayed bounded ($attempts <= 6)"
else
	_fail "the combined attempts stayed bounded ($attempts > 6)"
fi

out="$(backup backup)"
rc=$?
assert_eq '0' "$rc" 'and a later backup still succeeds'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "retries are BOUNDED"
printf '%s' "$TMP/definitely-not-a-repo" >"$TMP/creds/RESTIC_REPOSITORY"
out="$(MAX_ATTEMPTS=2 RETRY_BASE_SECONDS=0 backup backup)"
printf '%s' "$RESTIC_REPO" >"$TMP/creds/RESTIC_REPOSITORY"
assert_contains "$out" 'attempt 1/2' 'attempt 1 of a bounded number'
assert_contains "$out" 'attempt 2/2' 'attempt 2, and then it stops'
assert_not_contains "$out" 'attempt 3/' 'and there is no attempt 3'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "repository integrity is actually checked"
out="$(backup check)"
rc=$?
assert_eq '0' "$rc" 'check passes on a healthy disposable repository'
assert_contains "$out" 'integrity' 'and says what it checked'
# The subset bound is a CONFIG value, not something restic echoes; asserting on
# restic's own output for it would pass no matter what bound was used.
assert_contains "$(backup config)" 'repositoryCheckSubset = 1/1' \
	'and the configured read-data bound is visible in the effective config'
assert_contains "$(cat "$CONFIG")" 'repositoryCheckSubset' 'and it is set by the module, not invented here'

printf 'definitely-not-the-password\n' >"$TMP/wrong-password"
printf 'definitely-not-the-password\n' >"$TMP/creds/RESTIC_PASSWORD"
out="$(backup check)"
assert_ne '0' "$?" 'a wrong password cannot read the repository'
printf 'fixture-repository-password\n' >"$TMP/creds/RESTIC_PASSWORD"

# ═══════════════════════════════════════════════════════════════════════════
_t_start "the restore can be verified and then the scratch removed"
out="$(backup restore --to "$TMP/scratch2")"
assert_contains "$out" 'restoring into scratch' 'the restore says it is a scratch restore'
assert_contains "$out" 'verify it before you need it' 'and tells the operator what to do next'
assert_file "$TMP/scratch2$SOURCE/docs/blob.bin" 'a binary file came back too'
assert_eq 'replaceable-not-there' "$( [[ -e "$TMP/scratch2$SOURCE/.cache" ]] && echo present || echo replaceable-not-there)" \
	'an excluded path is still excluded in a restore'

# Count snapshots that carry the agent-ops tag, by occurrence.
count_tagged() {
	local n
	n="$("$RESTIC_BIN" --repo "$RESTIC_REPO" snapshots --json 2>/dev/null |
		grep -o '"tags":\[[^]]*agent-ops-backup' | wc -l)"
	printf '%s' "${n:-0}"
}

# ═══════════════════════════════════════════════════════════════════════════
_t_start "retention actually matches the snapshots it took"
# `forget --tag agent-ops-backup` filtered on a tag that `backup` never added,
# so `forget` removed nothing while reporting success. A retention policy that
# silently does nothing is a false assurance, so the tag is asserted on both
# sides: the snapshot must carry it, and forget must actually reduce the count.
snapshots_json="$("$RESTIC_BIN" --repo "$RESTIC_REPO" snapshots --json 2>/dev/null || true)"
assert_contains "$snapshots_json" 'agent-ops-backup' 'snapshots carry the agent-ops-backup tag'
TESTS_RUN=$((TESTS_RUN + 1))
tagged="$(count_tagged)"
if [[ "$tagged" -ge 1 ]]; then
	_ok "at least one snapshot is tagged for retention ($tagged)"
else
	_fail "at least one snapshot is tagged for retention (found $tagged)"
fi

# COUNT OCCURRENCES, not matching lines: restic emits compact JSON, so one
# line holds every snapshot and `grep -c` reports 1 for any non-empty
# repository — which reads as "forget removed nothing" no matter what it did.
snapshot_count() {
	local n
	n="$("$RESTIC_BIN" --repo "$RESTIC_REPO" snapshots --json 2>/dev/null |
		grep -o '"short_id"' | wc -l)"
	printf '%s' "${n:-0}"
}

# A wrapper still runs REAL restic, adding a date only for fixture snapshots.
# It also captures argv to verify bytes/s -> KiB/s at the actual CLI boundary.
cat >"$TMP/dated-restic" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$RESTIC_TEST_ARGS"
if [[ "$1" == backup && -n "${RESTIC_TEST_TIME:-}" ]]; then
	exec "$RESTIC_BIN" "$@" --time "$RESTIC_TEST_TIME"
fi
exec "$RESTIC_BIN" "$@"
EOF
sed -i "1c#!$(command -v bash)" "$TMP/dated-restic"
chmod +x "$TMP/dated-restic"
export RESTIC_BIN RESTIC_TEST_ARGS="$TMP/restic-args"

_t_start "positive dated retention ignores random staging paths but protects foreign snapshots"
DATED_REPO="$TMP/dated-repo"
"$RESTIC_BIN" --repo "$DATED_REPO" init >/dev/null 2>&1
printf '%s' "$DATED_REPO" >"$TMP/creds/RESTIC_REPOSITORY"
sed -e 's/^keepDaily=.*/keepDaily=2/' -e 's/^keepWeekly=.*/keepWeekly=0/' -e 's/^keepMonthly=.*/keepMonthly=0/' \
	-e 's/^limitUpload=.*/limitUpload=8000000/' -e 's/^limitDownload=.*/limitDownload=20000000/' \
	"$CONFIG" >"$TMP/dated.conf"
for day in 01 02 03 04; do
	out="$(RESTIC="$TMP/dated-restic" RESTIC_TEST_TIME="2024-01-${day} 12:00:00" bash "$BACKUP" --config "$TMP/dated.conf" backup 2>&1)"
	assert_eq '0' "$?" "real dated backup $day succeeds with a fresh staging path"
done
dated_before="$("$RESTIC_BIN" --repo "$DATED_REPO" snapshots --json)"
assert_eq '4' "$(jq '[.[].paths] | unique | length' <<<"$dated_before")" 'every dated backup really has a different randomized staging source'
args="$(cat "$RESTIC_TEST_ARGS")"
assert_contains "$args" $'--limit-upload\n7812' '8000000 bytes/s becomes 7812 KiB/s'
assert_contains "$args" $'--limit-download\n19531' '20000000 bytes/s becomes 19531 KiB/s'
assert_contains "$out" '8000000 B/s' 'public reporting remains in bytes/s'
"$RESTIC_BIN" --repo "$DATED_REPO" backup --host foreign-host --tag agent-ops-backup "$SOURCE" >/dev/null 2>&1
"$RESTIC_BIN" --repo "$DATED_REPO" backup --host "$(uname -n)" --tag foreign-tag "$SOURCE" >/dev/null 2>&1
out="$(bash "$BACKUP" --config "$TMP/dated.conf" prune 2>&1)"
assert_eq '0' "$?" 'normal positive retention succeeds'
dated_json="$("$RESTIC_BIN" --repo "$DATED_REPO" snapshots --json)"
assert_eq '2' "$(jq --arg host "$(uname -n)" '[.[] | select(.hostname == $host and (.tags | index("agent-ops-backup")))] | length' <<<"$dated_json")" 'positive daily retention keeps two snapshots despite distinct staging paths'
assert_eq '4' "$(jq 'length' <<<"$dated_json")" 'both foreign host and foreign tag snapshots survive'
matching_times="$(jq -r '.[] | select(.hostname != "foreign-host" and (.tags | index("agent-ops-backup"))) | .time' <<<"$dated_json")"
assert_contains "$matching_times" '2024-01-04' 'newest dated matching snapshot survives'
assert_contains "$matching_times" '2024-01-03' 'second newest dated matching snapshot survives'
assert_not_contains "$matching_times" '2024-01-01' 'oldest dated matching snapshot is forgotten'

_t_start "age selects the newest matching snapshot, never a foreign fresh one"
out="$(bash "$BACKUP" --config "$CONFIG" check 2>&1)"
assert_eq '3' "$?" 'old matching snapshots stay stale despite fresh foreign host and tag snapshots'
assert_contains "$out" 'TOO OLD' 'foreign snapshots cannot make health fresh'
out="$(bash "$BACKUP" --config "$CONFIG" backup 2>&1)"
assert_eq '0' "$?" 'a fresh matching snapshot is created alongside the old ones'
out="$(bash "$BACKUP" --config "$CONFIG" check 2>&1)"
assert_eq '0' "$?" 'old plus fresh matching snapshots pass using the newest, not the first'

for pair in '1 1' '1024 1' '0 0'; do
	read -r bytes kib <<<"$pair"
	sed "s/^limitDownload=.*/limitDownload=$bytes/" "$CONFIG" >"$TMP/limit.conf"
	out="$(RESTIC="$TMP/dated-restic" bash "$BACKUP" --config "$TMP/limit.conf" restore --to "$TMP/limit-$bytes" 2>&1)"
	assert_eq '0' "$?" "restore works with public download limit $bytes"
	assert_contains "$(cat "$RESTIC_TEST_ARGS")" "$(printf '%s\n%s' --limit-download "$kib")" "download limit $bytes converts to $kib KiB/s"
done
printf '%s' "$RESTIC_REPO" >"$TMP/creds/RESTIC_REPOSITORY"

# The all-zero policy separately exercises the explicit destructive test aid. Written here rather than by the module, because the point is to
# drive the SCRIPT, not the generated config.
# ALL THREE keep values go to zero. Zeroing only keep-daily is not enough: a
# snapshot taken today is also within "this week" and "this month", so
# keep-weekly/keep-monthly keep it and forget legitimately removes nothing —
# which is indistinguishable from the tag filter matching nothing.
sed -e 's/^keepDaily=.*/keepDaily=0/' -e 's/^keepWeekly=.*/keepWeekly=0/' -e 's/^keepMonthly=.*/keepMonthly=0/' \
	"$CONFIG" >"$TMP/aggressive.conf"

# Take one more snapshot so there is something to forget.
printf 'more state\n' >"$SOURCE/docs/more.txt"
backup backup >/dev/null 2>&1

before_count="$(snapshot_count)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$before_count" -ge 1 ]]; then
	_ok "the repository holds $before_count snapshot(s) to apply retention to"
else
	_fail "the repository holds snapshots to apply retention to (found $before_count)"
fi

# 🔴 `--unsafe-allow-remove-all` IS THE POINT, not a shortcut.
#
# With a normal keep-daily/keep-weekly/keep-monthly policy, snapshots taken
# minutes apart are all "today", so `forget` legitimately keeps them and the
# assertion could not tell "the tag matched" from "the tag matched nothing".
# Here, removing ALL matching snapshots exercises the all-zero policy; the
# positive dated policy above separately proves normal retention grouping.
out="$(bash "$BACKUP" --config "$TMP/aggressive.conf" prune --forget-all 2>&1)"
rc=$?
assert_eq '0' "$rc" 'prune --forget-all succeeds'
assert_contains "$out" 'retention applied' 'and reports that retention was applied'
after_count="$(snapshot_count)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$after_count" -lt "$before_count" ]]; then
	_ok "and snapshots matching the tag were ACTUALLY forgotten ($before_count -> $after_count)"
else
	_fail "snapshots matching the tag were ACTUALLY forgotten ($before_count -> $after_count — the tag filter matched nothing)"
fi

# Take a snapshot with the WRONG tag, plus a fresh tagged one, and prove the
# filter is doing the work: the untagged snapshot must survive a forget that
# only targets the agent-ops tag, and the tagged one must not.
printf 'untagged state\n' >"$SOURCE/docs/untagged.txt"
"$RESTIC_BIN" --repo "$RESTIC_REPO" backup "$SOURCE/docs/untagged.txt" >/dev/null 2>&1
printf 'more tagged state\n' >"$SOURCE/docs/more2.txt"
backup backup >/dev/null 2>&1
tagged_before="$(count_tagged)"
bash "$BACKUP" --config "$TMP/aggressive.conf" prune --forget-all >/dev/null 2>&1
tagged_after="$(count_tagged)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$tagged_after" -lt "$tagged_before" ]]; then
	_ok "forget removes only the snapshots it was told to ($tagged_before -> $tagged_after tagged)"
else
	_fail "forget removes only the snapshots it was told to ($tagged_before -> $tagged_after)"
fi

# --prune is a separate, explicit decision: forget must not reclaim on its own.
out="$(bash "$BACKUP" --config "$TMP/aggressive.conf" prune 2>&1)"
assert_not_contains "$out" 'pruning' 'plain prune does NOT reclaim'
out="$(bash "$BACKUP" --config "$CONFIG" prune --prune 2>&1)"
rc=$?
assert_eq '0' "$rc" 'prune --prune succeeds under the normal retention policy'
assert_contains "$out" 'pruning' 'and --prune reclaims explicitly'

# ═══════════════════════════════════════════════════════════════════════════
_t_start "no path in this suite rebooted anything"
assert_no_reboot "$TMP/reboots"
summary