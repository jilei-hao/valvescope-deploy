#!/usr/bin/env bash
# upgrade.sh — bring the server from what IS deployed to what this repository WANTS.
#
#   scripts/upgrade.sh --plan [--only a,b]     print the exact ordered actions; change nothing
#   scripts/upgrade.sh        [--only a,b]     do them
#
#   --only LIST      consider only these, comma-separated: a component name,
#                    env:<name> for a conda environment, model:<name> for a model
#   --lock FILE      wanted component versions   (default: versions.lock)
#   --map FILE       component map               (default: components.map)
#   --envs FILE      conda environments          (default: environments.map)
#   --manifest FILE  model weights               (default: models.manifest)
#   --deployed FILE  deployed component versions (default: $VS_STATE_DIR/deployed.lock);
#                    deployed.envs and deployed.models are read from the same directory
#   --no-health      do not finish with scripts/health.sh (install.sh uses this: on a
#                    first install the services are started after the upgrade)
#
# How it works. Three things are versioned, each with a "wanted" file in this
# repository and a "deployed" file on the server:
#
#   components    versions.lock      deployed.lock     name  sha
#   environments  environments.map   deployed.envs     name  checksum of its env-file
#   models        models.manifest    deployed.models   name  version  checksum
#
# An upgrade is the difference. Only what differs is touched. Each changed item is
# handled on its own, start to finish, and is written to its deployed file only
# after every one of its steps succeeded — so a failed run can simply be repeated.
#
#   environment   stop its units -> create/update the conda env -> start -> record
#   component     stop its units -> fetch -> deps -> config -> build -> database -> start -> record
#   ("start" restarts a unit this script stopped; a unit that was not running is left alone)
#   model         (you put the files in place) -> full verify -> stop -> start -> record
#
# Before the worker unit is started, the module list is checked against the
# worker's source and the gateway database (scripts/check-modules.sh).
#
# With no deployed files (a fresh server) everything counts as changed, so the same
# plan doubles as the install order.
#
# Exit codes: 0 done or nothing to do · 1 error · 2 bad usage
set -euo pipefail

PLAN=0
ONLY=""
LOCK=""
MAP=""
ENVS=""
MANIFEST=""
DEPLOYED=""
NO_HEALTH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN=1; shift ;;
    --only) ONLY=",$2,"; shift 2 ;;
    --lock) LOCK="$2"; shift 2 ;;
    --map) MAP="$2"; shift 2 ;;
    --envs) ENVS="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --deployed) DEPLOYED="$2"; shift 2 ;;
    --no-health) NO_HEALTH=1; shift ;;
    -h|--help) sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "upgrade: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# A plan is read-only, so it may run from the example config (e.g. on a laptop).
[ "$PLAN" -eq 1 ] && VS_ALLOW_EXAMPLE=1
. "$(dirname "$0")/lib.sh"

LOCK="${LOCK:-$REPO_DIR/versions.lock}"
MAP="${MAP:-$REPO_DIR/components.map}"
ENVS="${ENVS:-$REPO_DIR/environments.map}"
MANIFEST="${MANIFEST:-$REPO_DIR/models.manifest}"
DEPLOYED="${DEPLOYED:-$VS_STATE_DIR/deployed.lock}"
DEPLOYED_ENVS="$(dirname "$DEPLOYED")/deployed.envs"
DEPLOYED_MODELS="$(dirname "$DEPLOYED")/deployed.models"
HANDLER_UNIT=valvescope-handler

die() { printf 'upgrade: %s\n' "$*" >&2; exit 1; }
for f in "$LOCK" "$MAP" "$ENVS" "$MANIFEST"; do [ -f "$f" ] || die "file not found: $f"; done

# --- lookups ------------------------------------------------------------------
deployed_value() { # FILE NAME -> everything after the name on that line (minus timestamp col), or empty
  [ -f "$1" ] || return 0
  awk -v n="$2" '$1 == n { print $2 }' "$1"
}
deployed_sha() { deployed_value "$DEPLOYED" "$1"; }
row_field() { # FILE NCOLS NAME COLUMN -> value; fails if NAME has no well-formed line
  awk -v n="$3" -v c="$4" -v nf="$2" '
    $1 == n && $1 !~ /^#/ { if (NF != nf) exit 3; print $c; found = 1 }
    END { exit found ? 0 : 4 }' "$1"
}
map_field() { row_field "$MAP" 5 "$1" "$2"; }
env_field() { row_field "$ENVS" 4 "$1" "$2"; }
conda_env_name() { # ENV NAME -> real conda environment name
  local v
  v="$(env_field "$1" 2)" || die "components.map or --only names conda environment '$1', which has no 4-column line in $(basename "$ENVS")"
  case "$v" in
    \$*) v="${v#\$}"; eval "v=\${$v:-}"
         [ -n "$v" ] || die "environment '$1': the variable named in $(basename "$ENVS") is not set in deploy.env" ;;
  esac
  printf '%s' "$v"
}
env_file() { # ENV NAME -> path of its env-file
  local f; f="$(env_field "$1" 3)"
  case "$f" in
    src:*) printf '%s' "$VS_SRC_DIR/${f#src:}" ;;
    /*)    printf '%s' "$f" ;;
    *)     printf '%s' "$(cd "$(dirname "$ENVS")" && pwd)/$f" ;;
  esac
}
sha_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1; else shasum -a 256 < "$1" | cut -d' ' -f1; fi; }
selected() { # NAME (as it would appear in --only)
  [ -z "$ONLY" ] && return 0
  case "$ONLY" in *",$1,"*) return 0 ;; *) return 1 ;; esac
}
units_of() { [ "$1" = "-" ] || printf '%s' "$1" | tr ',' ' '; }

# --- the plan -----------------------------------------------------------------
# One action per line, tab-separated:  item <TAB> action <TAB> argument
# item is a component name, env:<name> or model:<name>.
PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/vs-plan.XXXXXX")"
trap 'rm -f "$PLAN_FILE"' EXIT
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$PLAN_FILE"; }
emit_stop()  { local u; for u in $(units_of "$2"); do emit "$1" stop "$u"; done; }
emit_start() { # the worker never starts with a module list it cannot serve
  local u
  for u in $(units_of "$2"); do
    [ "$u" = "$HANDLER_UNIT" ] && emit "$1" check-modules "VS_MODULE_LIST"
    emit "$1" start "$u"
  done
}
NOTES=""
note() { NOTES="$NOTES
  note: $*"; }

if [ -n "$ONLY" ]; then
  for want in $(printf '%s' "$ONLY" | tr ',' ' '); do
    case "$want" in
      env:*)   env_field "${want#env:}" 1 >/dev/null 2>&1 || die "--only names '$want', which is not in $(basename "$ENVS")" ;;
      model:*) row_field "$MANIFEST" 6 "${want#model:}" 1 >/dev/null 2>&1 || die "--only names '$want', which is not in $(basename "$MANIFEST")" ;;
      *) awk -v n="$want" '$1 == n { f = 1 } END { exit f ? 0 : 1 }' "$LOCK" \
           || die "--only names '$want', which is not in $(basename "$LOCK") (use env:<name> or model:<name> for those)" ;;
    esac
  done
fi

changed=0
unchanged=0

# 1. environments — first, because components install into them
while read -r name cenv file units extra; do
  case "$name" in ''|\#*) continue ;; esac
  [ -n "${units:-}" ] && [ -z "${extra:-}" ] || die "$(basename "$ENVS"): line for '$name' needs exactly 4 columns"
  selected "env:$name" || continue
  conda_env_name "$name" >/dev/null
  case "$file" in src:*) continue ;; esac            # rebuilt by its component's line
  path="$(env_file "$name")"
  if [ ! -f "$path" ]; then
    note "environment '$name': $file is not in this repository yet — taken as already existing, not managed"
    continue
  fi
  sum="$(sha_file "$path")"
  if [ "$(deployed_value "$DEPLOYED_ENVS" "$name")" = "$sum" ]; then unchanged=$((unchanged + 1)); continue; fi
  changed=$((changed + 1))
  emit_stop "env:$name" "$units"
  emit "env:$name" env-apply "$name"
  emit_start "env:$name" "$units"
  emit "env:$name" record-env "$sum"
done < "$ENVS"

# 2. components
while read -r name role url tag sha path; do
  case "$name" in ''|\#*) continue ;; esac
  selected "$name" || continue
  [ "$role" = "host" ] || continue          # client components are not installed here
  have="$(deployed_sha "$name")"
  if [ "$have" = "$sha" ]; then unchanged=$((unchanged + 1)); continue; fi
  changed=$((changed + 1))

  deps="$(map_field "$name" 2)"    || die "$name is in $(basename "$LOCK") but has no valid 5-column line in $(basename "$MAP")"
  build="$(map_field "$name" 3)"
  db="$(map_field "$name" 4)"
  restart="$(map_field "$name" 5)"

  emit_stop "$name" "$restart"
  emit "$name" fetch "${have:-none}..$sha"
  case "$deps" in
    -) ;;
    npm-ci) emit "$name" deps "npm-ci" ;;
    pip-e:*|conda-update:*|fireants:*)
      conda_env_name "${deps#*:}" >/dev/null
      emit "$name" deps "$deps" ;;
    *) die "$name: unknown deps step '$deps' in $(basename "$MAP")" ;;
  esac
  # A component that is built or that a unit runs has a generated config file in
  # its checkout; a fresh checkout has none, so it is (re)written before use.
  if [ "$build" != "-" ] || [ "$restart" != "-" ]; then emit "$name" render "service .env files"; fi
  case "$build" in
    -) ;;
    next-build|vite-build) emit "$name" build "$build" ;;
    *) die "$name: unknown build step '$build' in $(basename "$MAP")" ;;
  esac
  case "$db" in
    -) ;;
    yes)
      emit "$name" db-backup "$VS_DB_NAME,$VS_DS_DB_NAME"
      emit "$name" db-init "forward migrations only" ;;
    *) die "$name: db column must be yes or - in $(basename "$MAP")" ;;
  esac
  emit_start "$name" "$restart"
  emit "$name" record "$sha"
done < "$LOCK"

# 3. models — last: they need a person, and the code that loads them is in place by now
while read -r name location subdir version checksum restart extra; do
  case "$name" in ''|\#*) continue ;; esac
  [ -n "${restart:-}" ] && [ -z "${extra:-}" ] || die "$(basename "$MANIFEST"): line for '$name' needs exactly 6 columns"
  selected "model:$name" || continue
  want="$version/$checksum"
  have="$(awk -v n="$name" '$1 == n { print $2 "/" $3 }' "$DEPLOYED_MODELS" 2>/dev/null || true)"
  if [ "$have" = "$want" ]; then unchanged=$((unchanged + 1)); continue; fi
  changed=$((changed + 1))
  case "$location" in
    /*) dir="$location/$subdir" ;;
    *)  eval "dir=\${$location:-}"; [ -n "$dir" ] || die "model '$name': $location is not set in deploy.env"; dir="$dir/$subdir" ;;
  esac
  emit "model:$name" manual "$version|$dir|${have:-none}"
  emit "model:$name" verify-model "$name"
  [ "$checksum" = "UNMEASURED" ] && note "model '$name' is UNMEASURED in $(basename "$MANIFEST"): only its directory can be checked. Measure it on the server (scripts/model-manifest.sh --name $name --write) and commit the result."
  emit_stop "model:$name" "$restart"
  emit_start "model:$name" "$restart"
  emit "model:$name" record-model "$version $checksum"
done < "$MANIFEST"

describe() { # ITEM ACTION ARG -> human sentence
  local c="$1" a="$2" x="$3"
  case "$a" in
    stop)      printf 'stop unit %s' "$x" ;;
    start)     printf 'start unit %s' "$x" ;;
    check-modules) printf 'scripts/check-modules.sh (every module in %s exists in the worker source and the gateway database)' "$x" ;;
    fetch)     printf 'fetch %s at %s (was %s)' "$c" "${x#*..}" "${x%%..*}" ;;
    deps)
      case "$x" in
        npm-ci)         printf 'npm ci in %s' "$VS_SRC_DIR/$c" ;;
        pip-e:*)        printf 'pip install --no-deps -e %s into conda env %s, then pip check' "$VS_SRC_DIR/$c" "$(conda_env_name "${x#*:}")" ;;
        conda-update:*) printf 'conda env update %s from %s/environment.yml' "$(conda_env_name "${x#*:}")" "$VS_SRC_DIR/$c" ;;
        fireants:*)     printf 'install/build-fireants.sh: fireants + compiled CUDA ops from %s into conda env %s' "$VS_SRC_DIR/$c" "$(conda_env_name "${x#*:}")" ;;
      esac ;;
    render)    printf 'config/render.sh --install (service .env files and Caddyfile; unchanged files are left alone)' ;;
    build)     printf '%s in %s' "$x" "$VS_SRC_DIR/$c" ;;
    db-backup) printf 'dump databases %s to %s' "$x" "$VS_BACKUP_DIR" ;;
    db-init)   printf 'install/db-init.sh (%s; never drops or re-seeds)' "$x" ;;
    record)    printf 'record %s = %s in deployed.lock' "$c" "$x" ;;
    env-apply) printf 'create or update conda env %s from %s' "$(conda_env_name "$x")" "$(env_file "$x")" ;;
    record-env) printf 'record %s (env-file %s) in deployed.envs' "$c" "$(printf '%s' "$x" | cut -c1-12)" ;;
    manual)
      local v d h; v="${x%%|*}"; d="${x#*|}"; h="${d#*|}"; d="${d%%|*}"
      printf 'BY HAND: put %s version %s in place at %s (was %s). Weights are not in git and there is no artifact store; this script will not copy them.' "${c#model:}" "$v" "$d" "$h" ;;
    verify-model) printf 'scripts/verify-models.sh --full %s (stops here if the files are not the listed ones)' "$x" ;;
    record-model) printf 'record %s = %s in deployed.models' "${c#model:}" "$x" ;;
  esac
}

print_plan() {
  local n=0 last="" c a x
  while IFS="$(printf '\t')" read -r c a x; do
    if [ "$c" != "$last" ]; then printf '\n%s\n' "$c"; last="$c"; fi
    n=$((n + 1))
    printf '  %2d. %-13s %s\n' "$n" "$a" "$(describe "$c" "$a" "$x")"
  done < "$PLAN_FILE"
}

if [ "$changed" -eq 0 ]; then
  echo "upgrade: nothing to do — all $unchanged selected item(s) already match this repository"
  [ -z "$NOTES" ] || printf '%s\n' "$NOTES"
  exit 0
fi

echo "upgrade plan: $changed item(s) to change, $unchanged already current"
echo "  wanted:   $(basename "$LOCK"), $(basename "$ENVS"), $(basename "$MANIFEST")"
if [ -f "$DEPLOYED" ]; then echo "  deployed: $(dirname "$DEPLOYED")"; else echo "  deployed: (no deployed.lock — treating every component as new)"; fi
[ "$VS_USING_EXAMPLE" -eq 1 ] && echo "  note: no config/deploy.env here; paths below come from deploy.env.example"
print_plan
[ -z "$NOTES" ] || printf '%s\n' "$NOTES"

if [ "$PLAN" -eq 1 ]; then
  echo
  echo "plan only — nothing was changed"
  exit 0
fi

# --- the executor ---------------------------------------------------------------
# Small functions, one per action. Everything that is destructive to data is absent
# by design: no step here drops a database, clears the blob root or re-seeds.
# Who runs what: see vs_as_user in scripts/lib.sh. Commands run from / or from the
# component's checkout, never from the operator's own directory, which $VS_USER
# may not be able to enter.
CONDA="$VS_CONDA_ROOT/bin/conda"
as_user() { vs_as_user "$@"; }
# An upgrade restarts what was running; it does not start what was not. On a first
# install nothing runs yet (install/install.sh starts everything at the end), and a
# unit an operator stopped on purpose stays stopped. What this script stopped is
# remembered in the state directory, so a run that failed half-way and is repeated
# still brings those units back.
STOPPED_FILE="$(dirname "$DEPLOYED")/stopped-by-upgrade"
do_stop() {
  if systemctl is-active --quiet "$1"; then
    vs_as_user mkdir -p "$(dirname "$STOPPED_FILE")"
    grep -qx -- "$1" "$STOPPED_FILE" 2>/dev/null || printf '%s\n' "$1" | vs_as_user tee -a "$STOPPED_FILE" >/dev/null
    sudo systemctl stop "$1"
  else
    echo "   ($1 is not running)"
  fi
}
do_start() {
  if grep -qx -- "$1" "$STOPPED_FILE" 2>/dev/null; then
    sudo systemctl start "$1"
    grep -vx -- "$1" "$STOPPED_FILE" | vs_as_user tee "$STOPPED_FILE.tmp" >/dev/null || true
    vs_as_user mv "$STOPPED_FILE.tmp" "$STOPPED_FILE"
  else
    echo "   ($1 was not running before this upgrade — left as it is)"
  fi
}
do_fetch() { ( cd / && vs_fetch_sources --dest "$VS_SRC_DIR" --lock "$LOCK" --only "$1" ); }
do_deps() { # COMPONENT STEP
  local dir="$VS_SRC_DIR/$1" prefix
  case "$2" in
    npm-ci)         ( cd "$dir" && vs_as_user_net npm ci --no-audit --no-fund ) ;;
    pip-e:*)
      # --no-deps: every dependency is pinned in the environment file. Without it
      # pip would pull whatever is newest for anything the component names loosely
      # (segflow4d asks for "fireants", which would replace the pinned build).
      # pip check then fails the step if the component needs something the file lacks.
      prefix="$(vs_conda_env_prefix "$(conda_env_name "${2#*:}")")"
      ( cd "$dir" && vs_as_user_net "$prefix/bin/python" -m pip install --no-deps -e "$dir" \
          && vs_as_user "$prefix/bin/python" -m pip check ) ;;
    conda-update:*) ( cd "$dir" && vs_as_user_net "$CONDA" env update -n "$(conda_env_name "${2#*:}")" -f environment.yml ) ;;
    fireants:*)
      prefix="$(vs_conda_env_prefix "$(conda_env_name "${2#*:}")")"
      ( cd "$dir" && vs_as_user_net "$REPO_DIR/install/build-fireants.sh" --env-prefix "$prefix" --src "$dir" ) ;;
  esac
}
do_env_apply() { # ENV NAME — create the conda env if it is absent, else update it
  local env file; env="$(conda_env_name "$1")"; file="$(env_file "$1")"
  [ -x "$CONDA" ] || die "no conda at $CONDA — install/install.sh puts miniconda there"
  # conda writes a temporary requirements file next to the env-file, which lives in
  # the operator's repository; hand it a copy the deploy user owns instead.
  local tmp; tmp="$(vs_as_user mktemp -d "${TMPDIR:-/tmp}/vs-env.XXXXXX")"
  vs_as_user tee "$tmp/$(basename "$file")" < "$file" >/dev/null
  if vs_as_user test -d "$VS_CONDA_ROOT/envs/$env"; then
    ( cd / && vs_as_user_net "$CONDA" env update -n "$env" -f "$tmp/$(basename "$file")" )
  else
    ( cd / && vs_as_user_net "$CONDA" env create -n "$env" -f "$tmp/$(basename "$file")" )
  fi
  vs_as_user rm -f "$tmp/$(basename "$file")"
  vs_as_user rmdir "$tmp" 2>/dev/null || true
}
do_render() { "$REPO_DIR/config/render.sh" --install; }
do_build()  { ( cd "$VS_SRC_DIR/$1" && vs_as_user_net npm run build ); }
do_db_backup() { # COMPONENT — a server that already runs this component must yield both dumps
  if [ -n "$(deployed_sha "$1")" ]; then "$REPO_DIR/scripts/backup.sh" --db-only --must-exist
  else "$REPO_DIR/scripts/backup.sh" --db-only; fi
}
do_db_init()   { "$REPO_DIR/install/db-init.sh" --gateway-dir "$VS_SRC_DIR/avrp-gateway"; }
do_check_modules() { "$REPO_DIR/scripts/check-modules.sh"; }
do_verify_model() {
  "$REPO_DIR/scripts/verify-models.sh" --manifest "$MANIFEST" --full "$1" || {
    echo "upgrade: model '$1' is not in place as listed. Nothing was restarted or recorded." >&2
    echo "         Put the files in place by hand (see the BY HAND line above), then run this again." >&2
    exit 1; }
}
do_record() { # FILE NAME VALUE... — replace NAME's line in a deployed file
  local file="$1" name="$2"; shift 2
  as_user mkdir -p "$(dirname "$file")"
  local tmp="$file.tmp.$$"
  { [ -f "$file" ] && awk -v n="$name" '$1 != n' "$file"
    printf '%s  %s  %s\n' "$name" "$*" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } | as_user tee "$tmp" >/dev/null
  as_user mv "$tmp" "$file"
}

echo
echo "executing…"
# Read the plan on fd 3 so the commands we run cannot swallow it from stdin.
while IFS="$(printf '\t')" read -r c a x <&3; do
  printf '== %s: %s\n' "$c" "$(describe "$c" "$a" "$x")"
  case "$a" in
    stop)          do_stop "$x" ;;
    start)         do_start "$x" ;;
    check-modules) # only meaningful once the worker and the database are both there
                   if [ -n "$(deployed_sha avrp-handler)" ] && [ -n "$(deployed_sha avrp-gateway)" ]; then do_check_modules
                   else echo "   (first install: the module list is checked by install.sh once everything is in place)"; fi ;;
    fetch)         do_fetch "$c" ;;
    deps)          do_deps "$c" "$x" ;;
    render)        do_render ;;
    build)         do_build "$c" ;;
    db-backup)     do_db_backup "$c" ;;
    db-init)       do_db_init ;;
    record)        do_record "$DEPLOYED" "$c" "$x" ;;
    env-apply)     do_env_apply "$x" ;;
    record-env)    do_record "$DEPLOYED_ENVS" "${c#env:}" "$x" ;;
    manual)        : ;;   # a person's step; verify-model, next, proves it was done
    verify-model)  do_verify_model "$x" ;;
    record-model)  do_record "$DEPLOYED_MODELS" "${c#model:}" "$x" ;;
    *) die "internal: unknown action $a" ;;
  esac
done 3< "$PLAN_FILE"

echo "upgrade: done — $changed item(s) updated"
[ "$NO_HEALTH" -eq 0 ] || exit 0
"$REPO_DIR/scripts/health.sh" || { echo "upgrade: finished, but health.sh reports problems" >&2; exit 1; }
