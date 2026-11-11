#!/usr/bin/env bash
# backup.sh — copy what is needed to rebuild the deployment's data to $VS_BACKUP_DIR.
#
#   scripts/backup.sh --db-only    dump both databases (working)
#   scripts/backup.sh --db-only --must-exist
#                                  same, but fail unless BOTH were dumped (used by
#                                  upgrade.sh before a database change on a server
#                                  that already has data)
#   scripts/backup.sh              full backup — STUB (WS-4), exits 3
#
# The full backup set is:
#   1. pg_dump of $VS_DB_NAME     (users, cases, studies, task queue, module status)
#   2. pg_dump of $VS_DS_DB_NAME  (blob metadata — useless without the files, and vice versa)
#   3. the blob root $VS_DATA_ROOT (rsync; large)
#   4. config/deploy.env, versions.lock and deployed.lock (so the same versions can read the data)
# Not backed up: $VS_WORK_DIR (scratch), sources and conda envs (rebuilt from the lock).
#
# --db-only writes $VS_BACKUP_DIR/db/<UTC timestamp>/<database>.dump (pg_dump custom
# format; restore with pg_restore). It only reads the databases. A database that does
# not exist yet (first install) is skipped.
#
# Open points for the full backup: dump the two DBs at one consistent moment; retention;
# a restore.sh and one restore rehearsal.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
MUST_EXIST=0
[ "${2:-}" = "--must-exist" ] && MUST_EXIST=1
case "${1:-}" in
  --db-only) ;;
  "") not_implemented "only --db-only works today; see the plan in this file's header" ;;
  *) echo "backup: unknown argument: $1" >&2; exit 2 ;;
esac
export PGPASSWORD="$VS_DB_PASSWORD"
conn="-h $VS_PG_HOST -p $VS_PG_PORT -U $VS_DB_USER"
out="$VS_BACKUP_DIR/db/$(date -u +%Y%m%dT%H%M%SZ)"
made=0
for n in "$VS_DB_NAME" "$VS_DS_DB_NAME"; do
  # shellcheck disable=SC2086
  if ! psql -X -At $conn -d "$n" -c "select 1" >/dev/null 2>&1; then
    echo "backup: $n is not reachable as $VS_DB_USER (not created yet?) — skipped"
    continue
  fi
  # The backup directory belongs to the deploy user; the dump is made by the operator
  # (who holds the database password) and written through that user.
  vs_as_user mkdir -p "$out"
  # shellcheck disable=SC2086
  pg_dump $conn -Fc "$n" | vs_as_user tee "$out/$n.dump" >/dev/null
  echo "backup: $n -> $out/$n.dump ($(vs_as_user du -h "$out/$n.dump" | cut -f1))"
  made=$((made + 1))
done
echo "backup: $made database dump(s) written"
if [ "$MUST_EXIST" -eq 1 ] && [ "$made" -ne 2 ]; then
  echo "backup: expected 2 dumps, got $made — stopping so nothing is migrated without a backup" >&2
  exit 1
fi
