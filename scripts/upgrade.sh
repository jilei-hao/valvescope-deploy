#!/usr/bin/env bash
# upgrade.sh — bring the server from what IS deployed to what versions.lock WANTS.
#
#   scripts/upgrade.sh --plan [--only a,b]     print the exact ordered actions; change nothing
#   scripts/upgrade.sh        [--only a,b]     do them
#
#   --only LIST      consider only these comma-separated components
#   --lock FILE      wanted versions      (default: versions.lock)
#   --map FILE       component map        (default: components.map)
#   --deployed FILE  deployed versions    (default: $VS_STATE_DIR/deployed.lock)
#
# How it works. The server keeps a deployed.lock: one line per component with the
# SHA that is really installed. An upgrade is the difference between that file and
# versions.lock. Only components whose SHA differs are touched, and for each one
# components.map says which dependency step, build, database step and unit
# restarts it needs. A component is written to deployed.lock only after every one
# of its steps succeeded, so a failed run can simply be repeated.
#
# Each changed component is handled on its own, start to finish:
#   stop its units -> fetch -> deps -> build -> database -> start its units -> record
#
# With no deployed.lock (a fresh server) every component counts as changed, so the
# same plan doubles as the install order.
#
# Exit codes: 0 done or nothing to do · 1 error · 2 bad usage
set -euo pipefail

PLAN=0
ONLY=""
LOCK=""
MAP=""
DEPLOYED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN=1; shift ;;
    --only) ONLY=",$2,"; shift 2 ;;
    --lock) LOCK="$2"; shift 2 ;;
    --map) MAP="$2"; shift 2 ;;
    --deployed) DEPLOYED="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "upgrade: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# A plan is read-only, so it may run from the example config (e.g. on a laptop).
[ "$PLAN" -eq 1 ] && VS_ALLOW_EXAMPLE=1
. "$(dirname "$0")/lib.sh"

LOCK="${LOCK:-$REPO_DIR/versions.lock}"
MAP="${MAP:-$REPO_DIR/components.map}"
DEPLOYED="${DEPLOYED:-$VS_STATE_DIR/deployed.lock}"

die() { printf 'upgrade: %s\n' "$*" >&2; exit 1; }
[ -f "$LOCK" ] || die "lock file not found: $LOCK"
[ -f "$MAP" ]  || die "component map not found: $MAP"

# --- lookups ------------------------------------------------------------------
deployed_sha() { # NAME -> sha or empty
  [ -f "$DEPLOYED" ] || return 0
  awk -v n="$1" '$1 == n { print $2 }' "$DEPLOYED"
}
map_field() { # NAME COLUMN(2..5) -> value, or fails if the component has no map line
  awk -v n="$1" -v c="$2" '
    $1 == n && $1 !~ /^#/ { if (NF != 5) exit 3; print $c; found = 1 }
    END { exit found ? 0 : 4 }' "$MAP"
}
conda_env_for() { # handler|autoseg -> conda env name
  case "$1" in
    handler) printf '%s' "$VS_HANDLER_ENV" ;;
    autoseg) printf '%s' "$VS_AUTOSEG_ENV" ;;
    *) die "components.map names an unknown conda env '$1' (use handler or autoseg)" ;;
  esac
}
selected() { # NAME
  [ -z "$ONLY" ] && return 0
  case "$ONLY" in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# --- the plan -----------------------------------------------------------------
# One action per line, tab-separated:  component <TAB> action <TAB> argument
# Actions: stop start fetch deps build render db-backup db-init record
PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/vs-plan.XXXXXX")"
trap 'rm -f "$PLAN_FILE"' EXIT
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$PLAN_FILE"; }

if [ -n "$ONLY" ]; then
  for want in $(printf '%s' "$ONLY" | tr ',' ' '); do
    awk -v n="$want" '$1 == n { f = 1 } END { exit f ? 0 : 1 }' "$LOCK" \
      || die "--only names '$want', which is not in $LOCK"
  done
fi

changed=0
unchanged=0
while read -r name role url tag sha path; do
  case "$name" in ''|\#*) continue ;; esac
  selected "$name" || continue
  [ "$role" = "host" ] || continue          # client components are not installed here
  have="$(deployed_sha "$name")"
  if [ "$have" = "$sha" ]; then unchanged=$((unchanged + 1)); continue; fi
  changed=$((changed + 1))

  deps="$(map_field "$name" 2)"    || die "$name is in $LOCK but has no valid 5-column line in $MAP"
  build="$(map_field "$name" 3)"
  db="$(map_field "$name" 4)"
  restart="$(map_field "$name" 5)"

  units=""
  [ "$restart" = "-" ] || units="$(printf '%s' "$restart" | tr ',' ' ')"

  for u in $units; do emit "$name" stop "$u"; done
  emit "$name" fetch "${have:-none}..$sha"
  case "$deps" in
    -) ;;
    npm-ci) emit "$name" deps "npm-ci" ;;
    pip-e:*|conda-update:*)
      conda_env_for "${deps#*:}" >/dev/null
      emit "$name" deps "$deps" ;;
    *) die "$name: unknown deps step '$deps' in $MAP" ;;
  esac
  case "$build" in
    -) ;;
    next-build|vite-build)
      emit "$name" render "service .env files"
      emit "$name" build "$build" ;;
    *) die "$name: unknown build step '$build' in $MAP" ;;
  esac
  case "$db" in
    -) ;;
    yes)
      emit "$name" db-backup "$VS_DB_NAME,$VS_DS_DB_NAME"
      emit "$name" db-init "forward migrations only" ;;
    *) die "$name: db column must be yes or - in $MAP" ;;
  esac
  for u in $units; do emit "$name" start "$u"; done
  emit "$name" record "$sha"
done < "$LOCK"

describe() { # COMPONENT ACTION ARG -> human sentence
  local c="$1" a="$2" x="$3"
  case "$a" in
    stop)      printf 'stop unit %s' "$x" ;;
    start)     printf 'start unit %s' "$x" ;;
    fetch)     printf 'fetch %s at %s (was %s)' "$c" "${x#*..}" "${x%%..*}" ;;
    deps)
      case "$x" in
        npm-ci)         printf 'npm ci in %s' "$VS_SRC_DIR/$c" ;;
        pip-e:*)        printf 'pip install -e %s into conda env %s' "$VS_SRC_DIR/$c" "$(conda_env_for "${x#*:}")" ;;
        conda-update:*) printf 'conda env update %s from %s/environment.yml' "$(conda_env_for "${x#*:}")" "$VS_SRC_DIR/$c" ;;
      esac ;;
    render)    printf 're-render and install the service .env files' ;;
    build)     printf '%s in %s' "$x" "$VS_SRC_DIR/$c" ;;
    db-backup) printf 'dump databases %s to %s' "$x" "$VS_BACKUP_DIR" ;;
    db-init)   printf 'install/db-init.sh (%s; never drops or re-seeds)' "$x" ;;
    record)    printf 'record %s = %s in deployed.lock' "$c" "$x" ;;
  esac
}

print_plan() {
  local n=0 last="" c a x
  while IFS="$(printf '\t')" read -r c a x; do
    if [ "$c" != "$last" ]; then printf '\n%s\n' "$c"; last="$c"; fi
    n=$((n + 1))
    printf '  %2d. %-9s %s\n' "$n" "$a" "$(describe "$c" "$a" "$x")"
  done < "$PLAN_FILE"
}

if [ "$changed" -eq 0 ]; then
  echo "upgrade: nothing to do — all $unchanged selected component(s) already match $(basename "$LOCK")"
  exit 0
fi

echo "upgrade plan: $changed component(s) to change, $unchanged already current"
echo "  wanted:   $LOCK"
if [ -f "$DEPLOYED" ]; then echo "  deployed: $DEPLOYED"; else echo "  deployed: (no deployed.lock — treating every component as new)"; fi
[ "$VS_USING_EXAMPLE" -eq 1 ] && echo "  note: no config/deploy.env here; paths below come from deploy.env.example"
print_plan

if [ "$PLAN" -eq 1 ]; then
  echo
  echo "plan only — nothing was changed"
  exit 0
fi

# --- the executor ---------------------------------------------------------------
# Small functions, one per action. Everything that is destructive to data is absent
# by design: no step here drops a database, clears the blob root or re-seeds.
CONDA="$VS_CONDA_ROOT/bin/conda"
as_user() { # run a command as the deploy user
  if [ "$(id -un)" = "$VS_USER" ]; then "$@"; else sudo -u "$VS_USER" -H "$@"; fi
}
do_stop()  { sudo systemctl stop "$1"; }
do_start() { sudo systemctl start "$1"; }
do_fetch() { as_user "$REPO_DIR/install/fetch-sources.sh" --dest "$VS_SRC_DIR" --lock "$LOCK" --only "$1"; }
do_deps() { # COMPONENT STEP
  local dir="$VS_SRC_DIR/$1"
  case "$2" in
    npm-ci)         ( cd "$dir" && as_user npm ci ) ;;
    pip-e:*)        as_user "$VS_CONDA_ROOT/envs/$(conda_env_for "${2#*:}")/bin/pip" install -e "$dir" ;;
    conda-update:*) ( cd "$dir" && as_user "$CONDA" env update -n "$(conda_env_for "${2#*:}")" -f environment.yml ) ;;
  esac
}
do_render() { as_user "$REPO_DIR/config/render.sh" --install; }
do_build()  { ( cd "$VS_SRC_DIR/$1" && as_user npm run build ); }
do_db_backup() { # COMPONENT — a server that already runs this component must yield both dumps
  if [ -n "$(deployed_sha "$1")" ]; then "$REPO_DIR/scripts/backup.sh" --db-only --must-exist
  else "$REPO_DIR/scripts/backup.sh" --db-only; fi
}
do_db_init()   { "$REPO_DIR/install/db-init.sh" --gateway-dir "$VS_SRC_DIR/avrp-gateway"; }
do_record() { # COMPONENT SHA
  as_user mkdir -p "$(dirname "$DEPLOYED")"
  local tmp="$DEPLOYED.tmp.$$"
  { [ -f "$DEPLOYED" ] && awk -v n="$1" '$1 != n' "$DEPLOYED"
    printf '%s  %s  %s\n' "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } | as_user tee "$tmp" >/dev/null
  as_user mv "$tmp" "$DEPLOYED"
}

echo
echo "executing…"
# Read the plan on fd 3 so the commands we run cannot swallow it from stdin.
while IFS="$(printf '\t')" read -r c a x <&3; do
  printf '== %s: %s\n' "$c" "$(describe "$c" "$a" "$x")"
  case "$a" in
    stop)      do_stop "$x" ;;
    start)     do_start "$x" ;;
    fetch)     do_fetch "$c" ;;
    deps)      do_deps "$c" "$x" ;;
    render)    do_render ;;
    build)     do_build "$c" ;;
    db-backup) do_db_backup "$c" ;;
    db-init)   do_db_init ;;
    record)    do_record "$c" "$x" ;;
    *) die "internal: unknown action $a" ;;
  esac
done 3< "$PLAN_FILE"

echo "upgrade: done — $changed component(s) updated"
"$REPO_DIR/scripts/health.sh" || { echo "upgrade: finished, but health.sh reports problems" >&2; exit 1; }
