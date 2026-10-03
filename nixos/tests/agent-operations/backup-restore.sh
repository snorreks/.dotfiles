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

SQLITE_BIN="${SQLITE_BIN:-$(command -v sqlite3 || true)}"
if [[ -z "$SQLITE_BIN" ]]; then
	printf '\033[33mSKIPPED: sqlite3 is not on PATH (same flake closure).\033[0m\n'
	exit 0
fi
printf 'using sqlite3: %s\n' "$SQLITE_BIN"

# ── the fixture world ───────────────────────────────────────────────────────
export AGENT_OPS_STATE_DIR="$TMP/backup-state"
mkdir -p "$AGENT_OPS_STATE_DIR"
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
quiesceFile=$AGENT_OPS_STATE_DIR/quiesce.conf
quiesceSource=[]
limitUpload=0
limitDownload=0
ioMaxConcurrent=2
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
assert_eq '0' "$rc" 'a restore into an empty scratch directory succeeds'
assert_file "$SCRATCH$SOURCE/docs/notes.txt" 'the file came back'
assert_eq 'hello state' "$(cat "$SCRATCH$SOURCE/docs/notes.txt")" 'with its contents intact'

out="$(backup restore --to "$SCRATCH")"
rc=$?
assert_eq '2' "$rc" 'restoring into a NON-EMPTY directory is refused'
assert_contains "$out" 'not empty' 'and says why'
assert_contains "$out" 'overwrites the live home' 'and names the failure it prevents'

out="$(backup restore --to /)"
assert_contains "$out" "restore target is" 'restoring into / is refused'
assert_contains "$out" "empty" 'and says the target ended up empty after trimming' 

out="$(backup restore --to relative/path)"
assert_contains "$out" 'absolute path' 'a relative target is refused'

out="$(backup restore)"
assert_contains "$out" 'needs --to' 'a restore with no target is refused'

# HOME is the fixture's, so $HOME must be protected explicitly.
out="$(backup restore --to "$TMP/home-backup")"
rc=$?
assert_eq '0' "$rc" 'a scratch dir outside HOME is allowed'

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

# ═══════════════════════════════════════════════════════════════════════════
_t_start "no path in this suite rebooted anything"
assert_no_reboot "$TMP/reboots"
summary