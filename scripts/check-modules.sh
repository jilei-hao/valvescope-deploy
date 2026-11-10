#!/usr/bin/env bash
# check-modules.sh — is every module in VS_MODULE_LIST something this deployment can run?
# Read-only.
#
#   scripts/check-modules.sh [--list-only | --source-only | --db-only] [--handler-dir DIR]
#
# VS_MODULE_LIST (config/deploy.env) tells the worker which pipeline modules to
# take tasks for. A module has to exist in two places before listing it is safe:
#
#   source    the worker's registry in the pinned avrp-handler:
#             src/modules/create_module_worker.py (one `module_name == "..."` per module).
#             A name missing there makes the worker raise "Unknown module name".
#   database  a row in the gateway's `module` table (from sql/seed.sql or a
#             migration). Without it no task for that module is ever created, so the
#             module silently never runs.
#
# The list itself must not be empty, must not contain an empty item, and must not
# name a module twice.
#
#   --list-only    check the list only (no source, no database) — used by config/render.sh
#   --source-only  list + source
#   --db-only      list + database
#   (default)      all three — used by scripts/health.sh and by scripts/upgrade.sh
#                  before it starts the worker
#   --handler-dir  avrp-handler checkout (default: $VS_SRC_DIR/avrp-handler)
#
# Exit 0 if everything checked passed, 1 otherwise. Each failure names the module
# and the side that lacks it.
set -uo pipefail
DO_SOURCE=1; DO_DB=1; HANDLER_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list-only) DO_SOURCE=0; DO_DB=0; shift ;;
    --source-only) DO_DB=0; shift ;;
    --db-only) DO_SOURCE=0; shift ;;
    --handler-dir) HANDLER_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-modules: unknown argument: $1" >&2; exit 2 ;;
  esac
done
. "$(dirname "$0")/lib.sh"
HANDLER_DIR="${HANDLER_DIR:-$VS_SRC_DIR/avrp-handler}"
failed=0
bad() { printf 'FAIL  %s\n' "$*"; failed=$((failed + 1)); }

# --- the list itself --------------------------------------------------------------
LIST="${VS_MODULE_LIST:-}"
if [ -z "$(printf '%s' "$LIST" | tr -d ', \t')" ]; then
  bad "VS_MODULE_LIST is empty — the worker would start and do nothing. Name at least one module in config/deploy.env."
  exit 1
fi
case "$LIST" in *" "*|*"	"*) bad "VS_MODULE_LIST contains spaces ('$LIST') — write it as a,b,c" ;; esac
case ",$LIST," in *",,"*) bad "VS_MODULE_LIST has an empty item ('$LIST') — remove the stray comma" ;; esac
MODULES="$(printf '%s' "$LIST" | tr ',' '\n' | sed '/^$/d')"
dups="$(printf '%s\n' "$MODULES" | sort | uniq -d | tr '\n' ' ')"
[ -z "$dups" ] || bad "VS_MODULE_LIST names a module more than once: $dups"
for m in $MODULES; do
  printf '%s' "$m" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' || bad "module '$m': names are lower-case letters, digits, - and _"
done
[ "$failed" -eq 0 ] || exit 1

# --- source side --------------------------------------------------------------------
if [ "$DO_SOURCE" -eq 1 ]; then
  reg="$HANDLER_DIR/src/modules/create_module_worker.py"
  if [ ! -f "$reg" ]; then
    bad "worker registry not found: $reg (is avrp-handler fetched? did the file move upstream?)"
  else
    known="$(grep -Eo "module_name[[:space:]]*==[[:space:]]*[\"'][^\"']+[\"']" "$reg" | sed -E "s/.*[\"']([^\"']+)[\"']/\1/" | sort -u)"
    if [ -z "$known" ]; then
      bad "could not read any module name from $reg — its format changed; update scripts/check-modules.sh"
    else
      for m in $MODULES; do
        printf '%s\n' "$known" | grep -qx -- "$m" \
          || bad "module '$m' is in VS_MODULE_LIST but the worker SOURCE has no such module ($reg). Known there: $(printf '%s' "$known" | tr '\n' ' ')"
      done
    fi
  fi
fi

# --- database side --------------------------------------------------------------------
if [ "$DO_DB" -eq 1 ]; then
  rows="$(PGPASSWORD="$VS_DB_PASSWORD" psql -X -At -v ON_ERROR_STOP=1 -h "$VS_PG_HOST" -p "$VS_PG_PORT" \
            -U "$VS_DB_USER" -d "$VS_DB_NAME" -c 'select module_name from module' 2>&1)"
  if [ $? -ne 0 ]; then
    bad "cannot read the module table in database $VS_DB_NAME as $VS_DB_USER: $(printf '%s' "$rows" | head -1)"
  else
    for m in $MODULES; do
      printf '%s\n' "$rows" | grep -qx -- "$m" \
        || bad "module '$m' is in VS_MODULE_LIST but the gateway DATABASE ($VS_DB_NAME) has no row for it in table module. It arrives with the gateway's seed.sql or a migration: is the gateway pin new enough, and has install/db-init.sh run? In the database: $(printf '%s' "$rows" | tr '\n' ' ')"
    done
  fi
fi

if [ "$failed" -eq 0 ]; then
  sides="list"; [ "$DO_SOURCE" -eq 1 ] && sides="$sides, source"; [ "$DO_DB" -eq 1 ] && sides="$sides, database"
  echo "ok    modules ($sides): $(printf '%s' "$MODULES" | tr '\n' ' ')"
  exit 0
fi
exit 1
