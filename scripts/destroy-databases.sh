#!/usr/bin/env bash
# destroy-databases.sh — DESTRUCTIVE. Permanently deletes a ValveScope database.
#
#   scripts/destroy-databases.sh                              show what exists; delete nothing
#   scripts/destroy-databases.sh --yes-destroy-database NAME  delete that one database
#
# The flag must be given once per database, with the database's exact name. NAME must
# be VS_DB_NAME or VS_DS_DB_NAME from config/deploy.env — this script cannot be pointed
# at any other database, and it refuses the developer checkout's names.
#
# It never touches the blob root, the role, or backups. The two databases only make
# sense together: studies in one refer to files recorded in the other.
#
# This is the ONLY script in the repository allowed to remove data (see
# tests/run.sh, "destructive commands live only in destroy-*.sh").
set -euo pipefail
. "$(dirname "$0")/lib.sh"
CONFIRMED=","
while [ $# -gt 0 ]; do
  case "$1" in
    --yes-destroy-database) CONFIRMED="$CONFIRMED$2,"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "destroy-databases: unknown argument: $1" >&2; exit 2 ;;
  esac
done
ADMIN_PSQL="${VS_PG_ADMIN_PSQL:-sudo -u postgres psql -p $VS_PG_PORT}"
q() { # DB SQL
  # shellcheck disable=SC2086
  $ADMIN_PSQL -X -At -v ON_ERROR_STOP=1 -d "$1" -c "$2"
}
for n in $(printf '%s' "$CONFIRMED" | tr ',' ' '); do
  [ "$n" = "$VS_DB_NAME" ] || [ "$n" = "$VS_DS_DB_NAME" ] \
    || { echo "destroy-databases: '$n' is not one of this deployment's databases ($VS_DB_NAME, $VS_DS_DB_NAME)" >&2; exit 2; }
done
todo=0
echo "ValveScope databases on port $VS_PG_PORT:"
for n in "$VS_DB_NAME" "$VS_DS_DB_NAME"; do
  case "$n" in avrpdb|avrpdsdb|postgres|template0|template1)
    echo "destroy-databases: '$n' is reserved (dev checkout or Postgres itself); refusing" >&2; exit 1 ;;
  esac
  printf '%s' "$n" | grep -Eq '^[a-z_][a-z0-9_]{0,62}$' || { echo "destroy-databases: bad name '$n'" >&2; exit 1; }
  if [ "$(q postgres "select count(*) from pg_database where datname = '$n'")" != "1" ]; then
    echo "  $n: does not exist"; continue
  fi
  size="$(q postgres "select pg_size_pretty(pg_database_size('$n'))")"
  tables="$(q "$n" "select count(*) from pg_tables where schemaname = 'public'")"
  rows="$(q "$n" "select coalesce(sum(n_live_tup), 0) from pg_stat_user_tables")"
  case "$CONFIRMED" in
    *",$n,"*) echo "  $n: $size, $tables tables, ~$rows rows  -> WILL BE DELETED"; todo=$((todo + 1)) ;;
    *)        echo "  $n: $size, $tables tables, ~$rows rows  (kept)" ;;
  esac
done
if [ "$todo" -eq 0 ]; then
  echo "Nothing deleted. To delete one, pass --yes-destroy-database <name> (once per database)."
  exit 2
fi
for n in "$VS_DB_NAME" "$VS_DS_DB_NAME"; do
  case "$CONFIRMED" in *",$n,"*) ;; *) continue ;; esac
  [ "$(q postgres "select count(*) from pg_database where datname = '$n'")" = "1" ] || continue
  echo "deleting database $n …"
  q postgres "drop database \"$n\""
done
echo "done. The blob root ($VS_DATA_ROOT) was not touched."
