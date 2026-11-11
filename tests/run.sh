#!/usr/bin/env bash
# tests/run.sh — checks that run on a laptop, with no server.
#
#   tests/run.sh                 everything it can
#   VS_TEST_GATEWAY_DIR=DIR      use this avrp-gateway checkout instead of fetching the
#                                pinned one (the checkout is only read)
#   VS_TEST_HANDLER_DIR=DIR      same for avrp-handler (module registry)
#   VS_TEST_NO_PG=1              skip the real-Postgres part
#
# Part 1  upgrade.sh --plan      offline
# Part 2  db-init.sh --plan      offline, database state supplied from a file
# Part 3  destructive-command lint over every script
# Part 5  conda environments as data (a fictional third environment, no code change)
# Part 6  model manifest: measure, quick/full verify, upgrade plan
# Part 7  module list guard, source side (database side is in Part 4)
# Part 4  db-init.sh for real    against a THROWAWAY Postgres cluster this script
#                                creates in a temp dir on its own port and deletes
#                                afterwards. It never connects to any existing server,
#                                so it cannot reach avrpdb / avrpdsdb.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Debian/Ubuntu keep initdb and pg_ctl out of PATH; use the newest installed version.
if ! command -v initdb >/dev/null 2>&1; then
  for d in $(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V -r); do
    [ -x "$d/initdb" ] && { PATH="$d:$PATH"; break; }
  done
fi
T="$(mktemp -d "${TMPDIR:-/tmp}/vs-test.XXXXXX")"
PGDATA_T=""
cleanup() {
  [ -n "$PGDATA_T" ] && pg_ctl -D "$PGDATA_T" -m immediate stop >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT

pass=0; failn=0
ok()   { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
fail() { failn=$((failn + 1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
check() { # LABEL COMMAND... (passes if the command succeeds)
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else fail "$label"; fi
}
has()  { printf '%s' "$1" | grep -Eq -- "$2"; }
expect()     { if has "$2" "$3"; then ok "$1"; else fail "$1" "$2"; fi; }
expect_not() { if has "$2" "$3"; then fail "$1" "$2"; else ok "$1"; fi; }

LOCK="$REPO/versions.lock"
# A deployed.lock that says "exactly what versions.lock wants is installed".
# The state dir also says every model in the manifest is deployed as listed.
mkdir -p "$T/state"
awk '$1 !~ /^#/ && NF == 6 && $2 == "host" { print $1, $5 }' "$LOCK" > "$T/state/deployed.lock"
awk '$1 !~ /^#/ && NF == 6 { print $1, $4, $5 }' "$REPO/models.manifest" > "$T/state/deployed.models"
plan() { "$REPO/scripts/upgrade.sh" --plan --deployed "$T/state/deployed.lock" "$@" 2>&1; }
bump() { # NAME -> a lock file where only NAME's sha differs
  awk -v n="$1" '$1 == n { $5 = "0123456789abcdef0123456789abcdef01234567" } { print }' "$LOCK" > "$T/lock.$1"
  printf '%s' "$T/lock.$1"
}
# The component names that head a section of the plan output.
touched() { printf '%s\n' "$1" | grep -E '^[a-z][A-Za-z0-9_-]*$' | sort | tr '\n' ' '; }

GIT_BEFORE="$(git -C "$REPO" status --porcelain 2>/dev/null)"
echo "== Part 1: upgrade.sh --plan"
out="$(plan)"; rc=$?
[ $rc -eq 0 ] && ok "unchanged lock: exit 0" || fail "unchanged lock: exit 0" "$out"
expect     "unchanged lock: says nothing to do" "$out" 'nothing to do'
expect_not "unchanged lock: no actions listed"  "$out" '(fetch|deps|build|stop|start|record|db-init)[[:space:]]'

out="$(plan --lock "$(bump segflow4d)")"; rc=$?
[ $rc -eq 0 ] && ok "segflow4d only: exit 0" || fail "segflow4d only: exit 0" "$out"
[ "$(touched "$out")" = "segflow4d " ] && ok "segflow4d only: the only component touched" || fail "segflow4d only: the only component touched" "$out"
expect     "segflow4d only: fetches segflow4d"            "$out" 'fetch +fetch segflow4d at 0123456789'
expect     "segflow4d only: reinstalls into handler env"  "$out" 'deps +pip install -e .*/segflow4d into conda env segflow4d'
expect     "segflow4d only: stops the handler unit"       "$out" 'stop +stop unit valvescope-handler'
expect     "segflow4d only: starts the handler unit"      "$out" 'start +start unit valvescope-handler'
expect     "segflow4d only: records it"                   "$out" 'record +record segflow4d = 0123456789'
expect_not "segflow4d only: no other unit"                "$out" 'valvescope-(gateway|manager|viewer|proxy)'
expect_not "segflow4d only: no npm, build or database"    "$out" '(npm ci|next-build|vite-build|db-init|db-backup|conda env update)'
[ "$(printf '%s\n' "$out" | grep -Ec '^ +[0-9]+\. ')" = "6" ] && ok "segflow4d only: exactly 6 actions" || fail "segflow4d only: exactly 6 actions" "$out"
order="$(printf '%s\n' "$out" | awk '/^ +[0-9]+\. /{printf "%s ", $2}')"
[ "$order" = "stop fetch deps check-modules start record " ] && ok "segflow4d only: order stop→fetch→deps→check-modules→start→record" || fail "segflow4d only: order" "$order"
expect_not "segflow4d only: no environment or model touched" "$out" '^(env|model):' 

out="$(plan --lock "$(bump avrp-gateway)")"
[ "$(touched "$out")" = "avrp-gateway " ] && ok "gateway only: the only component touched" || fail "gateway only: the only component touched" "$out"
expect     "gateway only: npm ci"                  "$out" 'deps +npm ci in .*/avrp-gateway'
expect     "gateway only: database backup first"   "$out" 'db-backup'
expect     "gateway only: db-init"                 "$out" 'db-init +install/db-init.sh'
expect_not "gateway only: handler not restarted"   "$out" 'valvescope-handler'
order="$(printf '%s\n' "$out" | awk '/^ +[0-9]+\. /{printf "%s ", $2}')"
[ "$order" = "stop fetch deps db-backup db-init start record " ] && ok "gateway only: backup before db-init, both while stopped" || fail "gateway only: order" "$order"

out="$(plan --lock "$(bump avrp-manager)")"
order="$(printf '%s\n' "$out" | awk '/^ +[0-9]+\. /{printf "%s ", $2}')"
[ "$order" = "stop fetch deps render build start record " ] && ok "manager only: render then build, in order" || fail "manager only: order" "$order"
expect_not "manager only: no other unit"           "$out" 'valvescope-(gateway|handler|viewer|proxy)'

out="$(plan --lock "$(bump avrp-auto-seg)")"
expect     "auto-seg only: conda env update"       "$out" 'conda env update avrp-auto-seg'
expect_not "auto-seg only: no unit restarts"       "$out" '(stop|start) unit'

out="$(plan --lock "$(bump avrp-ipad)")"
expect     "client component (avrp-ipad): nothing to do" "$out" 'nothing to do'

awk '$1 == "segflow4d" || $1 == "avrp-manager" { $5 = "0123456789abcdef0123456789abcdef01234567" } { print }' "$LOCK" > "$T/lock.two"
out="$(plan --lock "$T/lock.two" --only segflow4d)"
[ "$(touched "$out")" = "segflow4d " ] && ok "--only restricts a two-component change to one" || fail "--only restricts" "$out"
out="$(plan --lock "$T/lock.two")"
[ "$(touched "$out")" = "avrp-manager segflow4d " ] && ok "two changes: both planned, nothing else" || fail "two changes" "$out"
out="$(plan --only no-such-thing)"; rc=$?
[ $rc -ne 0 ] && ok "--only with an unknown name fails" || fail "--only with an unknown name fails" "$out"

out="$("$REPO/scripts/upgrade.sh" --plan --deployed "$T/absent" 2>&1)"
n="$(touched "$out" | wc -w | tr -d ' ')"
[ "$n" = "8" ] && ok "no deployed.lock: all 8 host components planned (install order)" || fail "no deployed.lock: all 8 host components" "$out"

# every host component of the lock has a map line, and the map has no strangers
miss=""; for c in $(awk '$1 !~ /^#/ && NF == 6 { print $1 }' "$LOCK"); do
  awk -v n="$c" '$1 == n && NF == 5 { f = 1 } END { exit f ? 0 : 1 }' "$REPO/components.map" || miss="$miss $c"; done
for c in $(awk '$1 !~ /^#/ && NF == 5 { print $1 }' "$REPO/components.map"); do
  awk -v n="$c" '$1 == n && NF == 6 { f = 1 } END { exit f ? 0 : 1 }' "$LOCK" || miss="$miss map-only:$c"; done
[ -z "$miss" ] && ok "versions.lock and components.map name the same components" || fail "lock/map mismatch" "$miss"
[ "$(git -C "$REPO" status --porcelain 2>/dev/null)" = "$GIT_BEFORE" ] && ok "plan mode wrote nothing into the repo" || fail "plan mode wrote into the repo" "$(git -C "$REPO" status --porcelain)"

echo "== Part 2: db-init.sh --plan (offline)"
GW="${VS_TEST_GATEWAY_DIR:-}"
if [ -z "$GW" ]; then
  if "$REPO/install/fetch-sources.sh" --dest "$T/src" --only avrp-gateway,avrp-handler >"$T/fetch.log" 2>&1; then
    GW="$T/src/avrp-gateway"
  else
    fail "fetch the pinned avrp-gateway + avrp-handler (set VS_TEST_GATEWAY_DIR / VS_TEST_HANDLER_DIR to test offline)" "$(cat "$T/fetch.log")"
  fi
fi
if [ -n "$GW" ]; then
  echo "      gateway SQL from $GW @ $(git -C "$GW" rev-parse --short HEAD 2>/dev/null)"
  sha() { cat "$@" | shasum -a 256 | cut -d' ' -f1; }
  fsha() { sha $(ls "$1"/functions/*.sql | LC_ALL=C sort); }
  {
    echo "role yes"
    for pair in "vsdb:$GW/sql" "vsdsdb:$GW/data/db_adapters/sql"; do
      db="${pair%%:*}"; dir="${pair#*:}"
      echo "db $db populated"; echo "tracking $db yes"
      echo "applied $db baseline:schemas.sql $(sha "$dir/schemas.sql")"
      echo "applied $db baseline:seed.sql $(sha "$dir/seed.sql")"
      echo "applied $db functions $(fsha "$dir")"
      [ -d "$dir/migrations" ] && for m in $(ls "$dir/migrations"); do echo "applied $db migration:$m $(sha "$dir/migrations/$m")"; done
    done
  } > "$T/state.current"
  dbplan() { "$REPO/install/db-init.sh" --plan --gateway-dir "$GW" "$@" 2>&1; }
  NMIG="$(ls "$GW/sql/migrations" | grep -c '\.sql$')"
  LASTMIG="$(ls "$GW/sql/migrations" | grep '\.sql$' | LC_ALL=C sort | tail -1)"

  out="$(dbplan --state-from "$T/state.current")"; rc=$?
  [ $rc -eq 0 ] && ok "existing, current database: exit 0" || fail "existing, current database: exit 0" "$out"
  expect     "existing, current database: nothing to do" "$out" 'nothing to do'

  grep -v "migration:$LASTMIG" "$T/state.current" > "$T/state.behind"
  out="$(dbplan --state-from "$T/state.behind")"
  expect     "existing database one migration behind: applies $LASTMIG" "$out" "apply-migration +$LASTMIG"
  expect_not "existing database: no create step"   "$out" '(create-role|create-database)'
  expect_not "existing database: no schema or seed step" "$out" '(apply-schema|schemas\.sql|seed\.sql)'
  [ "$(printf '%s\n' "$out" | grep -c 'apply-migration')" = "1" ] && ok "existing database: only the one missing migration" || fail "only the one missing migration" "$out"

  printf 'role no\n' > "$T/state.fresh"
  out="$(dbplan --state-from "$T/state.fresh")"
  expect "fresh server: creates the role"            "$out" 'create-role'
  [ "$(printf '%s\n' "$out" | grep -c 'create-database')" = "2" ] && ok "fresh server: creates both databases" || fail "fresh server: creates both databases" "$out"
  [ "$(printf '%s\n' "$out" | grep -c 'apply-schema')" = "2" ]    && ok "fresh server: schema applied to both" || fail "fresh server: schema applied to both" "$out"
  [ "$(printf '%s\n' "$out" | grep -c 'apply-migration')" = "$NMIG" ] && ok "fresh server: all $NMIG gateway migrations" || fail "fresh server: all $NMIG gateway migrations" "$out"

  printf 'role yes\ndb vsdb populated\ntracking vsdb no\n' > "$T/state.foreign"
  out="$(dbplan --state-from "$T/state.foreign")"; rc=$?
  [ $rc -ne 0 ] && has "$out" 'not created by db-init' && ok "database with tables but no tracking: refused" || fail "foreign database refused" "$out"

  sed 's/^applied vsdb baseline:seed.sql .*/applied vsdb baseline:seed.sql 0000/' "$T/state.current" > "$T/state.seedchanged"
  out="$(dbplan --state-from "$T/state.seedchanged")"; rc=$?
  [ $rc -ne 0 ] && has "$out" 'seed.sql changed' && ok "seed.sql edited in place upstream: stops" || fail "seed.sql edited in place: stops" "$out"

  cp -R "$GW" "$T/gw-bad"; rm -rf "$T/gw-bad/.git"
  printf 'begin;\ndrop table study;\ncommit;\n' > "$T/gw-bad/sql/migrations/901_bad.sql"
  out="$("$REPO/install/db-init.sh" --plan --gateway-dir "$T/gw-bad" --state-from "$T/state.current" 2>&1)"; rc=$?
  [ $rc -ne 0 ] && has "$out" 'removes whole tables' && ok "pending migration that drops a table: refused on a database with data" || fail "destructive migration refused" "$out"

  # the blob-metadata database has its own migrations directory (empty upstream today)
  cp -R "$GW" "$T/gw-blob"; rm -rf "$T/gw-blob/.git"
  mkdir -p "$T/gw-blob/data/db_adapters/sql/migrations"
  printf 'notes, not a migration\n' > "$T/gw-blob/data/db_adapters/sql/migrations/README.md"
  out="$("$REPO/install/db-init.sh" --plan --gateway-dir "$T/gw-blob" --state-from "$T/state.current" 2>&1)"
  expect "blob metadata: a migrations directory with no .sql file is nothing to do" "$out" 'nothing to do'
  printf 'begin;\nalter table files add column if not exists vs_test_col int;\ncommit;\n' > "$T/gw-blob/data/db_adapters/sql/migrations/900_test.sql"
  out="$("$REPO/install/db-init.sh" --plan --gateway-dir "$T/gw-blob" --state-from "$T/state.current" 2>&1)"
  expect "blob metadata: a pending migration is planned against the blob database" "$out" 'blobmeta \(vsdsdb\) +apply-migration +900_test.sql'
  [ "$(printf '%s\n' "$out" | grep -c 'apply-')" = "1" ] && ok "blob metadata: and nothing else is planned" || fail "blob migration: nothing else planned" "$out"
  printf 'begin;\ntruncate files;\ncommit;\n' > "$T/gw-blob/data/db_adapters/sql/migrations/901_bad.sql"
  out="$("$REPO/install/db-init.sh" --plan --gateway-dir "$T/gw-blob" --state-from "$T/state.current" 2>&1)"; rc=$?
  [ $rc -ne 0 ] && has "$out" "'vsdsdb': pending migration 901_bad.sql removes whole tables" && ok "blob metadata: table-emptying migration refused" || fail "blob destructive migration refused" "$out"

  VS_DEPLOY_ENV="$T/devnames.env"; sed 's/^VS_DB_NAME=.*/VS_DB_NAME=avrpdb/' "$REPO/config/deploy.env.example" > "$VS_DEPLOY_ENV"
  out="$(VS_DEPLOY_ENV="$VS_DEPLOY_ENV" "$REPO/install/db-init.sh" --plan --gateway-dir "$GW" --state-from "$T/state.fresh" 2>&1)"; rc=$?
  [ $rc -ne 0 ] && has "$out" 'reserved' && ok "database name avrpdb: refused" || fail "database name avrpdb refused" "$out"
  unset VS_DEPLOY_ENV
fi

echo "== Part 3: destructive commands live only in destroy-*.sh"
pat='(rm +-[a-zA-Z]*r|dropdb|drop +(database|table|schema)|truncate|reset-db|reset-data|rebuild-dev|git +clean|git +reset +--hard|mkfs|--delete)'
hits=""
for f in "$REPO"/install/*.sh "$REPO"/scripts/*.sh "$REPO"/config/*.sh; do
  case "$(basename "$f")" in destroy-*.sh) continue ;; esac
  h="$(grep -nEi "$pat" "$f" | grep -Ev '^[0-9]+:[[:space:]]*#' | grep -v 'lint:detect-only')"
  [ -n "$h" ] && hits="$hits
$(basename "$f"): $h"
done
[ -z "$hits" ] && ok "no destructive command outside destroy-*.sh" || fail "destructive command outside destroy-*.sh" "$hits"
for f in "$REPO"/scripts/destroy-*.sh; do
  grep -q -- '--yes-destroy-' "$f" && ok "$(basename "$f") needs an explicit --yes-destroy-… flag" || fail "$(basename "$f") has no confirmation flag"
done


echo "== Part 5: environments are data"
out="$(plan)"
expect "handler env-file not in the repo yet: said so, not managed" "$out" "environment 'handler': envs/handler.yml is not in this repository yet"
# A fictional third environment and a component that installs into it. Only data
# files are written here; scripts/upgrade.sh is the committed one.
mkdir -p "$T/b/envs"
cp "$REPO/environments.map" "$T/b/environments.map"
echo 'measure  vs-measure-env  envs/measure.yml  valvescope-handler' >> "$T/b/environments.map"
printf 'name: vs-measure-env\ndependencies:\n  - python=3.11\n' > "$T/b/envs/measure.yml"
cp "$REPO/components.map" "$T/b/components.map"
echo 'dl-measure  pip-e:measure  -  -  valvescope-handler' >> "$T/b/components.map"
cp "$LOCK" "$T/b/versions.lock"
echo 'dl-measure  host  https://example.invalid/dl-measure.git  -  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  -' >> "$T/b/versions.lock"
bplan() { plan --lock "$T/b/versions.lock" --map "$T/b/components.map" --envs "$T/b/environments.map" "$@"; }
out="$(bplan)"; rc=$?
[ $rc -eq 0 ] && ok "third env + component: plan succeeds with no script change" || fail "third env + component: plan succeeds" "$out"
expect "third env: env:measure is planned"                 "$out" '^env:measure$'
expect "third env: created from its env-file under its real name" "$out" "env-apply +create or update conda env vs-measure-env from .*/b/envs/measure.yml"
expect "third env: recorded in deployed.envs"              "$out" 'record-env +record env:measure .* in deployed.envs'
expect "third env: its component installs into it"         "$out" 'deps +pip install -e .*/dl-measure into conda env vs-measure-env'
[ "$(touched "$out")" = "dl-measure " ] && ok "third env: no existing component touched" || fail "third env: no existing component touched" "$out"
first="$(printf '%s\n' "$out" | grep -E '^(env:|[a-z])' | grep -v '^upgrade' | head -1)"
[ "$first" = "env:measure" ] && ok "third env: environment comes before the component that needs it" || fail "environment before component" "$out"
expect "third env: its unit restarts around the env step"  "$out" 'stop +stop unit valvescope-handler'
# once recorded, nothing to do; a changed env-file is a change again
cp "$T/state/deployed.lock" "$T/b/deployed.lock"; echo 'dl-measure aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >> "$T/b/deployed.lock"
cp "$T/state/deployed.models" "$T/b/deployed.models"
echo "measure $(shasum -a 256 < "$T/b/envs/measure.yml" | cut -d' ' -f1)" > "$T/b/deployed.envs"
b2() { "$REPO/scripts/upgrade.sh" --plan --deployed "$T/b/deployed.lock" --lock "$T/b/versions.lock" --map "$T/b/components.map" --envs "$T/b/environments.map" "$@" 2>&1; }
out="$(b2)"
expect "third env deployed: nothing to do" "$out" 'nothing to do'
echo '  - numpy' >> "$T/b/envs/measure.yml"
out="$(b2)"
expect     "env-file edited: env:measure planned again" "$out" '^env:measure$'
expect_not "env-file edited: no component refetched"    "$out" 'fetch '
out="$(b2 --only env:measure)"
expect "--only env:<name> selects an environment" "$out" '^env:measure$'
sed 's/pip-e:measure/pip-e:nosuchenv/' "$T/b/components.map" > "$T/b/components.bad"
out="$(plan --lock "$T/b/versions.lock" --map "$T/b/components.bad" --envs "$T/b/environments.map")"; rc=$?
[ $rc -ne 0 ] && has "$out" "conda environment 'nosuchenv'" && ok "component naming an unknown environment: refused, names it" || fail "unknown environment refused" "$out"

echo "== Part 6: model manifest"
[ "$(awk '$1 !~ /^#/ && NF == 6 && $5 == "UNMEASURED"' "$REPO/models.manifest" | wc -l | tr -d ' ')" = "3" ] && ok "manifest seeds the three known models as UNMEASURED" || fail "three UNMEASURED placeholders"
for d in Dataset900_LOOCV_f0 Dataset2222_FinalAVData Dataset3333_FinalAVData_2Chan; do
  grep -q "$d" "$REPO/models.manifest" || fail "manifest names $d"
done
out="$(plan)"; expect "deployed models match the manifest: nothing to do" "$out" 'nothing to do'
out="$("$REPO/scripts/upgrade.sh" --plan --deployed "$T/absent" --only model:ct-loocv-f0 2>&1)"
expect "unmeasured model on a fresh server: planned, marked UNMEASURED" "$out" "model 'ct-loocv-f0' is UNMEASURED"

# a small fake model with the shape of an nnU-Net directory
M="$T/m"; mkdir -p "$M/weights/Dataset42_Fake/fold_0" "$M/repo/models"
head -c 300000 /dev/urandom > "$M/weights/Dataset42_Fake/fold_0/checkpoint_final.pth"
echo '{"plans": 1}' > "$M/weights/Dataset42_Fake/plans.json"
echo 'epoch 1' > "$M/weights/Dataset42_Fake/fold_0/training_log.txt"
sed "s|^VS_CT_MODELS_DIR=.*|VS_CT_MODELS_DIR=$M/weights|" "$REPO/config/deploy.env.example" > "$M/deploy.env"
echo 'fake-model  VS_CT_MODELS_DIR  Dataset42_Fake  v1  UNMEASURED  valvescope-handler' > "$M/repo/models.manifest"
mm() { VS_DEPLOY_ENV="$M/deploy.env" "$REPO/scripts/model-manifest.sh" --manifest "$M/repo/models.manifest" "$@" 2>&1; }
vm() { VS_DEPLOY_ENV="$M/deploy.env" "$REPO/scripts/verify-models.sh" --manifest "$M/repo/models.manifest" "$@" 2>&1; }
out="$(vm)"; rc=$?
[ $rc -eq 0 ] && has "$out" 'warn +model fake-model: .*UNMEASURED' && ok "verify: UNMEASURED model with its directory present is a warning" || fail "verify UNMEASURED" "$out"
out="$(mm --name fake-model)"
[ "$(awk '{print $5}' "$M/repo/models.manifest")" = "UNMEASURED" ] && ok "model-manifest without --write leaves the manifest alone" || fail "manifest untouched without --write" "$out"
out="$(mm --name fake-model --write --version v2)"; rc=$?
sum="$(awk '{print $5}' "$M/repo/models.manifest")"
[ $rc -eq 0 ] && [ ${#sum} -eq 64 ] && [ "$(awk '{print $4}' "$M/repo/models.manifest")" = "v2" ] && ok "model-manifest --write records checksum and version" || fail "model-manifest --write" "$out"
[ "$(wc -l < "$M/repo/models/fake-model.files" | tr -d ' ')" = "3" ] && ok "file list has every file" || fail "file list has every file" "$(cat "$M/repo/models/fake-model.files")"
[ "$(awk -F'\t' '$2 != "-"' "$M/repo/models/fake-model.files" | wc -l | tr -d ' ')" = "2" ] && ok "weights and config are hashed, the log is size-only" || fail "hash rule" "$(cat "$M/repo/models/fake-model.files")"
out="$(mm --name fake-model --write)"
[ "$(awk '{print $5}' "$M/repo/models.manifest")" = "$sum" ] && ok "measuring twice gives the same checksum" || fail "checksum stable" "$out"
out="$(vm)"; rc=$?;        [ $rc -eq 0 ] && has "$out" 'ok +model fake-model: version v2 — 3 files' && ok "verify quick: passes" || fail "verify quick passes" "$out"
out="$(vm --full)"; rc=$?; [ $rc -eq 0 ] && has "$out" '2 re-hashed' && ok "verify full: passes, re-hashes 2 files" || fail "verify full passes" "$out"
# same size, different bytes: only the full check can see it
head -c 300000 /dev/urandom > "$M/weights/Dataset42_Fake/fold_0/checkpoint_final.pth"
out="$(vm)"; rc=$?;        [ $rc -eq 0 ] && ok "weights swapped for same-size bytes: quick check passes (documented limit)" || fail "quick with same-size swap" "$out"
out="$(vm --full)"; rc=$?; [ $rc -ne 0 ] && has "$out" 'content differs .*checkpoint_final.pth' && ok "weights swapped for same-size bytes: full check fails, names the file" || fail "full catches swap" "$out"
head -c 1000 /dev/urandom > "$M/weights/Dataset42_Fake/fold_0/checkpoint_final.pth"
out="$(vm)"; rc=$?;        [ $rc -ne 0 ] && has "$out" 'size 1000, expected 300000' && ok "wrong size: quick check fails" || fail "quick catches size" "$out"
rm "$M/weights/Dataset42_Fake/plans.json"
out="$(vm)"; rc=$?;        [ $rc -ne 0 ] && has "$out" 'missing: plans.json' && ok "missing file: quick check fails, names it" || fail "quick catches missing" "$out"
echo 'x' >> "$M/repo/models/fake-model.files"
out="$(vm)"; rc=$?;        [ $rc -ne 0 ] && has "$out" 'does not match the checksum' && ok "file list edited by hand: refused" || fail "edited list refused" "$out"
# the planner
mplan() { VS_DEPLOY_ENV="$M/deploy.env" "$REPO/scripts/upgrade.sh" --plan --manifest "$M/repo/models.manifest" --deployed "$M/state/deployed.lock" "$@" 2>&1; }
mkdir -p "$M/state"; cp "$T/state/deployed.lock" "$M/state/"
echo "fake-model v1 $sum" > "$M/state/deployed.models"
out="$(mplan)"; rc=$?
[ $rc -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -E '^(model|env):|^[a-z][A-Za-z0-9_-]*$' | tr '\n' ' ')" = "model:fake-model " ] && ok "model version change: the only item planned" || fail "model change is the only item" "$out"
expect     "model change: names the model and both versions' place" "$out" 'BY HAND: put fake-model version v2 in place at .*/weights/Dataset42_Fake \(was v1/'
expect     "model change: says weights are not in git"  "$out" 'not in git and there is no artifact store'
order="$(printf '%s\n' "$out" | awk '/^ +[0-9]+\. /{printf "%s ", $2}')"
[ "$order" = "manual verify-model stop check-modules start record-model " ] && ok "model change: by hand → full verify → restart → record, in order" || fail "model change: order" "$order"
expect     "model change: restarts the handler unit"    "$out" 'start +start unit valvescope-handler'
expect     "model change: recorded in deployed.models"  "$out" 'record-model +record fake-model = v2 '
expect_not "model change: no fetch, deps, build or database" "$out" '(fetch |npm ci|pip install|next-build|db-init)'
echo "fake-model v2 $(awk '{print $5}' "$M/repo/models.manifest")" > "$M/state/deployed.models"
out="$(mplan)"; expect "model deployed as listed: nothing to do" "$out" 'nothing to do'

echo "== Part 7: module list guard (source side)"
HD="${VS_TEST_HANDLER_DIR:-$T/src/avrp-handler}"
if [ ! -f "$HD/src/modules/create_module_worker.py" ]; then
  fail "pinned avrp-handler not available at $HD"
else
  echo "      worker registry from $HD @ $(git -C "$HD" rev-parse --short HEAD 2>/dev/null)"
  cm() { # MODULE_LIST args...
    local list="$1"; shift
    sed "s/^VS_MODULE_LIST=.*/VS_MODULE_LIST=$list/" "${CM_BASE:-$REPO/config/deploy.env.example}" > "$T/cm.env"
    VS_DEPLOY_ENV="$T/cm.env" "$REPO/scripts/check-modules.sh" --handler-dir "$HD" "$@" 2>&1
  }
  def="$(. "$REPO/config/deploy.env.example"; printf '%s' "$VS_MODULE_LIST")"
  out="$(cm "$def" --source-only)"; rc=$?
  [ $rc -eq 0 ] && ok "default VS_MODULE_LIST exists in the pinned worker source" || fail "default list in source" "$out"
  out="$(cm "tp-measurements,study-generator,global-measurements,phase-detection,auto-segmentation,root-strain,root-diameter" --source-only)"; rc=$?
  [ $rc -eq 0 ] && ok "all 7 modules of the pinned registry are recognised" || fail "all registry modules recognised" "$out"
  out="$(cm "study-generator,fusion-detection" --source-only)"; rc=$?
  [ $rc -ne 0 ] && has "$out" "module 'fusion-detection' .*worker SOURCE" && ok "module not in the worker source: fails, names module and side" || fail "missing in source" "$out"
  expect_not "…and does not blame the module that exists" "$out" "module 'study-generator'"
  out="$(cm "" --list-only)"; rc=$?
  [ $rc -ne 0 ] && has "$out" 'VS_MODULE_LIST is empty' && ok "empty list: refused" || fail "empty list refused" "$out"
  out="$(cm "study-generator,phase-detection,study-generator" --list-only)"; rc=$?
  [ $rc -ne 0 ] && has "$out" 'more than once: study-generator' && ok "duplicate: refused, names it" || fail "duplicate refused" "$out"
  out="$(cm "study-generator,,phase-detection" --list-only)"; rc=$?
  [ $rc -ne 0 ] && has "$out" 'empty item' && ok "stray comma: refused" || fail "stray comma refused" "$out"
  out="$(cm "$def" --source-only --handler-dir "$T/nowhere")"; rc=$?
  [ $rc -ne 0 ] && has "$out" 'worker registry not found' && ok "registry file missing: fails clearly" || fail "registry missing" "$out"
  sed -e 's/^VS_MODULE_LIST=.*/VS_MODULE_LIST=a,a/' -e 's/CHANGE_ME/x/' "$REPO/config/deploy.env.example" > "$T/dup.env"
  out="$("$REPO/config/render.sh" --env "$T/dup.env" --out "$T/rendered" 2>&1)"; rc=$?
  [ $rc -ne 0 ] && has "$out" 'more than once' && ok "config/render.sh refuses a bad module list" || fail "render refuses bad list" "$out"
fi

echo "== Part 4: db-init.sh against a throwaway Postgres"
if [ "${VS_TEST_NO_PG:-0}" = "1" ] || [ -z "$GW" ] || ! command -v initdb >/dev/null 2>&1 || ! command -v pg_ctl >/dev/null 2>&1; then
  echo "skip  no initdb/pg_ctl on PATH (or VS_TEST_NO_PG=1) — real-database checks not run"
else
  PORT=54329
  while nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; do PORT=$((PORT + 1)); done
  PGDATA_T="$T/pg"
  if ! LC_ALL=C initdb -D "$PGDATA_T" -U vs_test_admin -A trust -E UTF8 --locale=C >"$T/initdb.log" 2>&1 \
     || ! LC_ALL=C pg_ctl -D "$PGDATA_T" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=" -l "$T/pg.log" -w start >/dev/null 2>&1; then
    PGDATA_T=""
    fail "start a throwaway Postgres cluster" "$(tail -5 "$T/initdb.log" "$T/pg.log" 2>/dev/null)"
  else
    echo "      throwaway cluster: $(psql -h 127.0.0.1 -p "$PORT" -U vs_test_admin -d postgres -Atc 'show server_version') on port $PORT"
    export VS_DEPLOY_ENV="$T/deploy.env"
    sed -e "s/^VS_PG_PORT=.*/VS_PG_PORT=$PORT/" -e 's/^VS_DB_NAME=.*/VS_DB_NAME=vs_test_main/' \
        -e 's/^VS_DS_DB_NAME=.*/VS_DS_DB_NAME=vs_test_blob/' -e 's/^VS_DB_USER=.*/VS_DB_USER=vs_test_role/' \
        -e 's/^VS_DB_PASSWORD=.*/VS_DB_PASSWORD=testpw123/' -e "s|^VS_BACKUP_DIR=.*|VS_BACKUP_DIR=$T/backup|" \
        "$REPO/config/deploy.env.example" > "$VS_DEPLOY_ENV"
    export VS_PG_ADMIN_PSQL="psql -h 127.0.0.1 -p $PORT -U vs_test_admin"
    q() { psql -h 127.0.0.1 -p "$PORT" -U vs_test_admin -X -At -d "$1" -c "$2" 2>&1; }
    dump() { pg_dump -h 127.0.0.1 -p "$PORT" -U vs_test_admin "$1" | grep -v '^\\\(un\)\{0,1\}restrict' | shasum | cut -d' ' -f1; }
    dbinit() { "$REPO/install/db-init.sh" --gateway-dir "${GWX:-$GW}" "$@" 2>&1; }

    out="$(dbinit)"; rc=$?
    [ $rc -eq 0 ] && ok "first run on an empty cluster succeeds" || fail "first run on an empty cluster succeeds" "$out"
    [ "$(q vs_test_main "select count(*) from pg_tables where schemaname='public'")" -gt 15 ] && ok "main database has its tables" || fail "main database has its tables"
    [ "$(q vs_test_main "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'")" -ge 30 ] && ok "main database has its functions" || fail "main database has its functions"
    [ "$(q vs_test_main "select count(*) from vs_schema_migrations where key like 'migration:%'")" = "$NMIG" ] && ok "$NMIG migrations recorded" || fail "$NMIG migrations recorded"
    [ "$(q vs_test_main "select count(*) from information_schema.columns where table_name='study_module_status' and column_name='lease_expires_at'")" = "1" ] && ok "migration 001 really applied (lease column present)" || fail "migration 001 applied"
    [ "$(q vs_test_blob "select count(*) from folders")" = "1" ] && ok "blob-metadata database seeded (root folder)" || fail "blob-metadata database seeded"
    [ "$(q vs_test_main "select tableowner from pg_tables where tablename='study'")" = "vs_test_role" ] && ok "objects are owned by the deploy role" || fail "objects owned by deploy role"

    # rows a real server would hold
    q vs_test_main "insert into user_role(role_name) values ('vs-test-keep')" >/dev/null
    q vs_test_blob "insert into folders(name, parent_id) values ('vs-test-keep', null)" >/dev/null
    d1="$(dump vs_test_main)"; b1="$(dump vs_test_blob)"

    out="$(dbinit --plan)"
    expect     "plan against the existing databases: nothing to do" "$out" 'nothing to do'
    expect_not "plan against the existing databases: no create or schema step" "$out" '(create-|apply-schema)'
    out="$(dbinit)"; rc=$?
    [ $rc -eq 0 ] && has "$out" 'nothing to do' && ok "second run: nothing to do" || fail "second run: nothing to do" "$out"
    [ "$(dump vs_test_main)" = "$d1" ] && [ "$(dump vs_test_blob)" = "$b1" ] && ok "second run: both databases byte-identical in pg_dump" || fail "second run changed a database"
    [ "$(q vs_test_main "select count(*) from user_role where role_name='vs-test-keep'")" = "1" ] && ok "second run: inserted row kept (main)" || fail "inserted row kept (main)"
    [ "$(q vs_test_blob "select count(*) from folders where name='vs-test-keep'")" = "1" ] && ok "second run: inserted row kept (blob metadata)" || fail "inserted row kept (blob)"

    # a later release: one new forward migration and one changed function
    cp -R "$GW" "$T/gw-next"; rm -rf "$T/gw-next/.git"
    printf 'begin;\nalter table study add column if not exists vs_test_col int;\ncommit;\n' > "$T/gw-next/sql/migrations/900_test.sql"
    printf '\n-- changed\n' >> "$T/gw-next/sql/functions/fn_get_user_info.sql"
    out="$(GWX="$T/gw-next" dbinit)"; rc=$?
    [ $rc -eq 0 ] && has "$out" 'apply-migration +900_test.sql' && ok "new release: applies only the new migration" || fail "new release: applies the new migration" "$out"
    expect_not "new release: no schema, seed or create step" "$out" '(create-|apply-schema)'
    [ "$(printf '%s\n' "$out" | grep -c '== .*apply-migration')" = "1" ] && ok "new release: old migrations not re-run" || fail "old migrations not re-run" "$out"
    [ "$(q vs_test_main "select count(*) from information_schema.columns where table_name='study' and column_name='vs_test_col'")" = "1" ] && ok "new release: migration took effect" || fail "migration took effect"
    [ "$(q vs_test_main "select count(*) from user_role where role_name='vs-test-keep'")" = "1" ] && ok "new release: inserted row still there" || fail "row kept after migration"
    out="$(GWX="$T/gw-next" dbinit)"
    expect "new release: running it again does nothing" "$out" 'nothing to do'

    # the blob-metadata database migrates the same way
    mkdir -p "$T/gw-next/data/db_adapters/sql/migrations"
    printf 'begin;\nalter table files add column if not exists vs_test_col int;\ncommit;\n' > "$T/gw-next/data/db_adapters/sql/migrations/900_test.sql"
    out="$(GWX="$T/gw-next" dbinit)"; rc=$?
    [ $rc -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c '== .*apply-migration')" = "1" ] && has "$out" '== blobmeta: apply-migration 900_test.sql' && ok "blob metadata: applies only its new migration" || fail "blob metadata migration applied" "$out"
    [ "$(q vs_test_blob "select count(*) from information_schema.columns where table_name='files' and column_name='vs_test_col'")" = "1" ] && ok "blob metadata: migration took effect" || fail "blob migration took effect"
    [ "$(q vs_test_blob "select count(*) from vs_schema_migrations where key = 'migration:900_test.sql'")" = "1" ] && ok "blob metadata: migration recorded in that database" || fail "blob migration recorded"
    [ "$(q vs_test_blob "select count(*) from folders where name='vs-test-keep'")" = "1" ] && ok "blob metadata: inserted row still there" || fail "blob row kept after migration"
    out="$(GWX="$T/gw-next" dbinit)"
    expect "blob metadata: running it again does nothing" "$out" 'nothing to do'

    # guards against a database with data
    printf 'begin;\ndrop table study cascade;\ncommit;\n' > "$T/gw-next/sql/migrations/901_bad.sql"
    out="$(GWX="$T/gw-next" dbinit)"; rc=$?
    [ $rc -ne 0 ] && [ "$(q vs_test_main "select count(*) from pg_tables where tablename='study'")" = "1" ] && ok "table-dropping migration refused; table still there" || fail "table-dropping migration refused" "$out"
    rm "$T/gw-next/sql/migrations/901_bad.sql"
    printf '\n-- edited in place\n' >> "$T/gw-next/sql/seed.sql"
    out="$(GWX="$T/gw-next" dbinit)"; rc=$?
    [ $rc -ne 0 ] && has "$out" 'seed.sql changed' && ok "seed.sql edited in place: stops and changes nothing" || fail "seed.sql edited in place stops" "$out"

    q postgres 'create database vs_test_foreign' >/dev/null; q vs_test_foreign 'create table t(x int); insert into t values (1)' >/dev/null
    sed 's/^VS_DB_NAME=.*/VS_DB_NAME=vs_test_foreign/' "$T/deploy.env" > "$T/deploy.foreign.env"
    out="$(VS_DEPLOY_ENV="$T/deploy.foreign.env" "$REPO/install/db-init.sh" --gateway-dir "$GW" 2>&1)"; rc=$?
    [ $rc -ne 0 ] && [ "$(q vs_test_foreign 'select count(*) from t')" = "1" ] && ok "database made by something else: refused, untouched" || fail "foreign database refused" "$out"

    # module list guard, database side (main database still holds the pinned seed rows)
    if [ -f "${HD:-/nonexistent}/src/modules/create_module_worker.py" ]; then
      CM_BASE="$T/deploy.env"
      out="$(cm "$def")"; rc=$?
      [ $rc -eq 0 ] && has "$out" 'list, source, database' && ok "default module list: in source AND in the database" || fail "default list source+db" "$out"
      q vs_test_main "update module set module_name = 'root-diameter-x' where module_name = 'root-diameter'" >/dev/null
      out="$(cm "study-generator,root-diameter")"; rc=$?
      [ $rc -ne 0 ] && has "$out" "module 'root-diameter' .*gateway DATABASE" && ok "module in source but not in the database: fails, names module and side" || fail "missing in database" "$out"
      expect_not "…and does not blame the source for it" "$out" "module 'root-diameter' .*worker SOURCE"
      q vs_test_main "update module set module_name = 'root-diameter' where module_name = 'root-diameter-x'" >/dev/null
      out="$(cm "study-generator,fusion-detection")"; rc=$?
      [ $rc -ne 0 ] && [ "$(printf '%s\n' "$out" | grep -c "module 'fusion-detection'")" = "2" ] && ok "module missing on both sides: both reported" || fail "missing on both sides" "$out"
      unset CM_BASE
    fi

    # backup and the destroy guard
    out="$("$REPO/scripts/backup.sh" --db-only --must-exist 2>&1)"; rc=$?
    [ $rc -eq 0 ] && [ "$(find "$T/backup" -name '*.dump' | wc -l | tr -d ' ')" = "2" ] && ok "backup --db-only writes two dumps" || fail "backup --db-only" "$out"
    out="$("$REPO/scripts/destroy-databases.sh" 2>&1)"; rc=$?
    [ $rc -ne 0 ] && has "$out" 'Nothing deleted' && has "$out" 'vs_test_main: .* tables' && ok "destroy-databases without a flag: lists, deletes nothing" || fail "destroy without flag" "$out"
    [ "$(q postgres "select count(*) from pg_database where datname like 'vs_test_%'")" = "3" ] && ok "…and all databases are still there" || fail "databases still there"
    out="$("$REPO/scripts/destroy-databases.sh" --yes-destroy-database postgres 2>&1)"; rc=$?
    [ $rc -ne 0 ] && ok "destroy-databases refuses a name that is not this deployment's" || fail "destroy refuses foreign name" "$out"
    out="$("$REPO/scripts/destroy-databases.sh" --yes-destroy-database vs_test_blob 2>&1)"; rc=$?
    [ $rc -eq 0 ] && has "$out" 'vs_test_blob: .*WILL BE DELETED' && has "$out" 'vs_test_main: .*kept' \
      && [ "$(q postgres "select string_agg(datname, ',' order by datname) from pg_database where datname like 'vs_test_%'")" = "vs_test_foreign,vs_test_main" ] \
      && ok "destroy-databases with the flag: prints what goes, deletes only that one" || fail "destroy with flag" "$out"
    unset VS_DEPLOY_ENV VS_PG_ADMIN_PSQL
  fi
fi

echo
echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
