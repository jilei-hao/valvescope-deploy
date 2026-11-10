#!/usr/bin/env bash
# db-init.sh — bring both ValveScope databases to the state the pinned gateway needs,
# WITHOUT ever removing data. Safe to run against a server that already holds studies,
# and safe to run twice: the second run does nothing.
#
#   install/db-init.sh --plan            print what would happen; change nothing
#   install/db-init.sh                   do it
#
#   --gateway-dir DIR   avrp-gateway checkout to read SQL from (default: $VS_HOME/src/avrp-gateway)
#   --adopt             start tracking a database that already has tables but was not
#                       created by this script (see "Rules" 3)
#   --accept-baseline-change
#                       upstream edited schemas.sql / seed.sql in place; you have checked
#                       that a migration covers the change (see "Rules" 5)
#   --allow-destructive-migration FILE
#                       apply a migration that the scan below flagged, after reading it
#   --state-from FILE   (with --plan only) take the database state from FILE instead of
#                       asking Postgres — for offline tests
#
# What it manages
#   main      $VS_DB_NAME      from <gateway>/sql/                  schemas.sql, seed.sql, migrations/, functions/
#   blobmeta  $VS_DS_DB_NAME   from <gateway>/data/db_adapters/sql/ schemas.sql, seed.sql, functions/
#
# Rules (this is requirement R1 — deploying never wipes data)
#   1. The role and each database are created only if missing.
#   2. schemas.sql + seed.sql are applied only to a database with NO tables — one this
#      run just created, or one left empty by an interrupted run. They go in as a
#      single transaction together with the tracking table, so a database is either
#      empty or fully initialised, never half.
#   3. A database that has tables but no tracking table was made by something else.
#      The script refuses it unless --adopt is given.
#   4. On a database that has data, only two things ever run:
#        - migrations not yet recorded in the tracking table, in filename order
#        - the functions/ directory, and only when its contents changed
#          (functions are code, not data; every file is CREATE OR REPLACE)
#   5. If schemas.sql or seed.sql differ from what the database was created from, the
#      script stops. Those files are only read at creation, so an in-place edit
#      upstream would otherwise be silently skipped on every existing server.
#   6. A pending migration containing DROP TABLE / DROP DATABASE / DROP SCHEMA /
#      TRUNCATE is refused on a database that has data, until allowed by name.
#   7. Nothing here drops, truncates or re-seeds, and nothing here calls the gateway's
#      reset scripts or rebuild-dev.sh. The dev database names are refused outright.
#
# Tracking table (in each database): vs_schema_migrations(key, checksum, applied_at)
#   baseline:schemas.sql · baseline:seed.sql · migration:<file> · functions
#
# Connections
#   admin (create role/database, read state): $VS_PG_ADMIN_PSQL
#          default "sudo -u postgres psql -p $VS_PG_PORT"
#   app   (everything applied to a database): the deploy role over TCP with its password,
#          so the deploy role owns every object it uses.
set -euo pipefail

PLAN=0
ADOPT=0
ACCEPT_BASELINE=0
ALLOWED_MIGRATIONS=","
STATE_FROM=""
GATEWAY_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN=1; shift ;;
    --adopt) ADOPT=1; shift ;;
    --accept-baseline-change) ACCEPT_BASELINE=1; shift ;;
    --allow-destructive-migration) ALLOWED_MIGRATIONS="$ALLOWED_MIGRATIONS$2,"; shift 2 ;;
    --state-from) STATE_FROM="$2"; shift 2 ;;
    --gateway-dir) GATEWAY_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "db-init: unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { printf 'db-init: %s\n' "$*" >&2; exit 1; }
[ -z "$STATE_FROM" ] || [ "$PLAN" -eq 1 ] || die "--state-from is only valid with --plan"

[ "$PLAN" -eq 1 ] && VS_ALLOW_EXAMPLE=1
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib.sh"

GATEWAY_DIR="${GATEWAY_DIR:-$VS_SRC_DIR/avrp-gateway}"
ADMIN_PSQL="${VS_PG_ADMIN_PSQL:-sudo -u postgres psql -p $VS_PG_PORT}"

# --- refuse anything that could be the developer's database --------------------
valid_ident() { printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_]{0,62}$'; }
for n in "$VS_DB_NAME" "$VS_DS_DB_NAME" "$VS_DB_USER"; do
  valid_ident "$n" || die "'$n' must be lower-case letters, digits and underscores"
done
for n in "$VS_DB_NAME" "$VS_DS_DB_NAME"; do
  case "$n" in avrpdb|avrpdsdb|postgres|template0|template1)
    die "database name '$n' is reserved (dev checkout or Postgres itself); refusing" ;;
  esac
done
case "$VS_DB_USER" in avrpdev|postgres) die "role '$VS_DB_USER' belongs to the dev checkout or Postgres; refusing" ;; esac
[ "$VS_DB_NAME" != "$VS_DS_DB_NAME" ] || die "VS_DB_NAME and VS_DS_DB_NAME must differ"

sqldir_for() { # LABEL
  case "$1" in
    main)     printf '%s' "$GATEWAY_DIR/sql" ;;
    blobmeta) printf '%s' "$GATEWAY_DIR/data/db_adapters/sql" ;;
  esac
}
dbname_for() { case "$1" in main) printf '%s' "$VS_DB_NAME" ;; blobmeta) printf '%s' "$VS_DS_DB_NAME" ;; esac; }
for label in main blobmeta; do
  d="$(sqldir_for "$label")"
  [ -f "$d/schemas.sql" ] && [ -f "$d/seed.sql" ] && [ -d "$d/functions" ] \
    || die "gateway SQL not found under $d (is --gateway-dir right?)"
done

sha_of() { # FILE... -> one sha256 over the files' contents, in the order given
  if command -v sha256sum >/dev/null 2>&1; then cat "$@" | sha256sum | cut -d' ' -f1
  else cat "$@" | shasum -a 256 | cut -d' ' -f1; fi
}
functions_sha() { # SQLDIR
  # shellcheck disable=SC2046
  sha_of $(ls "$1"/functions/*.sql | LC_ALL=C sort)
}
migrations_of() { # SQLDIR -> basenames, sorted; nothing if the directory is absent
  [ -d "$1/migrations" ] || return 0
  ls "$1/migrations" | grep -E '\.sql$' | LC_ALL=C sort || true
}

# --- reading state (admin connection, read-only) --------------------------------
admin_q() { # DB SQL -> rows
  # shellcheck disable=SC2086
  $ADMIN_PSQL -X -At -v ON_ERROR_STOP=1 -d "$1" -c "$2"
}
role_exists() {
  if [ -n "$STATE_FROM" ]; then awk '$1 == "role" { print $2 }' "$STATE_FROM" | grep -qx yes; return; fi
  [ "$(admin_q postgres "select count(*) from pg_roles where rolname = '$VS_DB_USER'")" = "1" ]
}
db_state() { # DBNAME -> missing | empty | populated
  if [ -n "$STATE_FROM" ]; then
    local s; s="$(awk -v n="$1" '$1 == "db" && $2 == n { print $3 }' "$STATE_FROM")"
    printf '%s' "${s:-missing}"; return
  fi
  if [ "$(admin_q postgres "select count(*) from pg_database where datname = '$1'")" != "1" ]; then
    printf missing; return
  fi
  if [ "$(admin_q "$1" "select count(*) from pg_tables where schemaname = 'public'")" = "0" ]; then
    printf empty
  else
    printf populated
  fi
}
recorded() { # DBNAME KEY -> checksum, or empty if not recorded / no tracking table
  if [ -n "$STATE_FROM" ]; then
    awk -v n="$1" -v k="$2" '$1 == "applied" && $2 == n && $3 == k { print $4 }' "$STATE_FROM"; return
  fi
  admin_q "$1" "select checksum from vs_schema_migrations where key = '$2'" 2>/dev/null || true
}
has_tracking() { # DBNAME
  if [ -n "$STATE_FROM" ]; then
    awk -v n="$1" '$1 == "tracking" && $2 == n { print $3 }' "$STATE_FROM" | grep -qx yes; return
  fi
  [ "$(admin_q "$1" "select count(*) from pg_tables where schemaname = 'public' and tablename = 'vs_schema_migrations'")" = "1" ]
}

# Comments stripped, then looked at for statements that remove whole objects.
scan_migration() { # FILE -> prints "destructive" and/or "delete"
  local body; body="$(sed -e 's/--.*$//' "$1")"
  printf '%s' "$body" | grep -Eiq '(drop[[:space:]]+(table|database|schema)|truncate)' && printf 'destructive '   # lint:detect-only
  printf '%s' "$body" | grep -Eiq 'delete[[:space:]]+from' && printf 'delete'                                   # lint:detect-only
  return 0
}

# --- the plan -------------------------------------------------------------------
# label <TAB> action <TAB> argument
PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/vs-dbplan.XXXXXX")"
trap 'rm -f "$PLAN_FILE"' EXIT
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$PLAN_FILE"; }
NOTES=""
note() { NOTES="$NOTES
  note: $*"; }

role_exists || emit cluster create-role "$VS_DB_USER"

for label in main blobmeta; do
  db="$(dbname_for "$label")"
  dir="$(sqldir_for "$label")"
  state="$(db_state "$db")"
  fresh=0
  case "$state" in
    missing)
      emit "$label" create-database "$db"
      emit "$label" apply-schema "schemas.sql + seed.sql + tracking table, one transaction"
      fresh=1 ;;
    empty)
      emit "$label" apply-schema "schemas.sql + seed.sql + tracking table, one transaction"
      fresh=1 ;;
    populated)
      if ! has_tracking "$db"; then
        [ "$ADOPT" -eq 1 ] || die "database '$db' has tables but no vs_schema_migrations table — it was not created by db-init.
  Nothing was changed. If this really is the ValveScope database, re-run with --adopt:
  that records today's schemas.sql/seed.sql as its baseline and then runs every migration
  (upstream states they are safe to re-run)."
        emit "$label" adopt "record baseline; all migrations pending"
        fresh=2
      else
        for f in schemas.sql seed.sql; do
          want="$(sha_of "$dir/$f")"
          have="$(recorded "$db" "baseline:$f")"
          if [ "$want" != "$have" ]; then
            [ "$ACCEPT_BASELINE" -eq 1 ] || die "'$db': $f changed since this database was created from it.
  That file is only applied to a brand-new database, so the change has NOT reached this one.
  Nothing was changed. Check that a migration in the same release carries the change, then
  re-run with --accept-baseline-change. If no migration does, that is an upstream bug."
            emit "$label" accept-baseline "$f"
          fi
        done
      fi ;;
    *) die "unexpected state '$state' for $db" ;;
  esac

  for m in $(migrations_of "$dir"); do
    printf '%s' "$m" | grep -Eq '^[A-Za-z0-9._-]+$' || die "migration file name not allowed: $m"
    if [ "$fresh" -eq 0 ]; then
      have="$(recorded "$db" "migration:$m")"
      if [ -n "$have" ]; then
        [ "$have" = "$(sha_of "$dir/migrations/$m")" ] \
          || note "$label: applied migration $m was edited upstream afterwards; it will not be re-run"
        continue
      fi
    fi
    flags="$(scan_migration "$dir/migrations/$m")"
    if [ "$fresh" -ne 1 ]; then
      case "$flags" in *destructive*)
        case "$ALLOWED_MIGRATIONS" in *",$m,"*) note "$label: $m removes whole tables/objects — allowed by flag" ;;
          *) die "'$db': pending migration $m removes whole tables or objects (rule 6) and this database has data.
  Nothing was changed. Read the file; if it is intended, re-run with --allow-destructive-migration $m" ;;
        esac ;;
      esac
      case "$flags" in *delete*) note "$label: $m contains DELETE FROM — read it before applying to a database with studies" ;; esac
    fi
    emit "$label" apply-migration "$m"
  done

  fsha="$(functions_sha "$dir")"
  if [ "$fresh" -ne 0 ] || [ "$(recorded "$db" functions)" != "$fsha" ]; then
    n="$(ls "$dir"/functions/*.sql | wc -l | tr -d ' ')"
    emit "$label" apply-functions "$n files, one transaction (code only, no data)"
  fi
done

if [ ! -s "$PLAN_FILE" ]; then
  echo "db-init: nothing to do — role, both databases, migrations and functions are current"
  exit 0
fi

echo "db-init plan (gateway SQL from $GATEWAY_DIR):"
[ "$VS_USING_EXAMPLE" -eq 1 ] && echo "  note: no config/deploy.env here; names come from deploy.env.example"
while IFS="$(printf '\t')" read -r l a x; do
  case "$l" in cluster) where="cluster" ;; *) where="$l ($(dbname_for "$l"))" ;; esac
  printf '  %-22s %-16s %s\n' "$where" "$a" "$x"
done < "$PLAN_FILE"
[ -z "$NOTES" ] || printf '%s\n' "$NOTES"

if [ "$PLAN" -eq 1 ]; then
  echo "plan only — nothing was changed"
  exit 0
fi

# --- the executor ---------------------------------------------------------------
printf '%s' "$VS_DB_PASSWORD" | grep -Eq '^[A-Za-z0-9._~+=-]+$' \
  || die "VS_DB_PASSWORD may only contain letters, digits and . _ ~ + = -  (install/gen-secrets.sh makes a valid one)"
[ "$VS_DB_PASSWORD" != "CHANGE_ME" ] || die "VS_DB_PASSWORD is still CHANGE_ME — run install/gen-secrets.sh"

app_psql() { # DBNAME psql-args...
  local db="$1"; shift
  PGPASSWORD="$VS_DB_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 \
    -h "$VS_PG_HOST" -p "$VS_PG_PORT" -U "$VS_DB_USER" -d "$db" "$@"
}
TRACKING_DDL="create table if not exists vs_schema_migrations (key text primary key, checksum text not null, applied_at timestamptz not null default now())"
record_sql() { # KEY CHECKSUM -> upsert statement
  printf "insert into vs_schema_migrations(key, checksum) values ('%s', '%s') on conflict (key) do update set checksum = excluded.checksum, applied_at = now()" "$1" "$2"
}

while IFS="$(printf '\t')" read -r l a x <&3; do
  db="$(dbname_for "$l")"; dir="$(sqldir_for "$l")"
  printf '== %s: %s %s\n' "$l" "$a" "$x"
  case "$a" in
    create-role)
      # The password travels on stdin, not on a command line other users could read.
      # shellcheck disable=SC2086
      printf "create role \"%s\" login password '%s';\n" "$VS_DB_USER" "$VS_DB_PASSWORD" \
        | $ADMIN_PSQL -X -q -v ON_ERROR_STOP=1 -d postgres ;;
    create-database)
      # shellcheck disable=SC2086
      $ADMIN_PSQL -X -q -v ON_ERROR_STOP=1 -d postgres \
        -c "create database \"$db\" owner \"$VS_DB_USER\"" ;;
    apply-schema)
      app_psql "$db" -1 \
        -f "$dir/schemas.sql" -f "$dir/seed.sql" \
        -c "$TRACKING_DDL" \
        -c "$(record_sql baseline:schemas.sql "$(sha_of "$dir/schemas.sql")")" \
        -c "$(record_sql baseline:seed.sql "$(sha_of "$dir/seed.sql")")" ;;
    adopt)
      app_psql "$db" -1 \
        -c "$TRACKING_DDL" \
        -c "$(record_sql baseline:schemas.sql "$(sha_of "$dir/schemas.sql")")" \
        -c "$(record_sql baseline:seed.sql "$(sha_of "$dir/seed.sql")")" ;;
    accept-baseline)
      app_psql "$db" -c "$(record_sql "baseline:$x" "$(sha_of "$dir/$x")")" ;;
    apply-migration)
      # Upstream migrations carry their own begin/commit, so the file and its record
      # cannot share a transaction. If the run dies between the two lines, the next
      # run applies the file again — which upstream promises is a no-op.
      app_psql "$db" -f "$dir/migrations/$x"
      app_psql "$db" -c "$(record_sql "migration:$x" "$(sha_of "$dir/migrations/$x")")" ;;
    apply-functions)
      args=""
      for f in $(ls "$dir"/functions/*.sql | LC_ALL=C sort); do args="$args -f $f"; done
      # shellcheck disable=SC2086
      app_psql "$db" -1 $args -c "$(record_sql functions "$(functions_sha "$dir")")" ;;
    *) die "internal: unknown action $a" ;;
  esac
done 3< "$PLAN_FILE"

echo "db-init: done"
