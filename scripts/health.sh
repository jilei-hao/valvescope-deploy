#!/usr/bin/env bash
# health.sh — is the deployment working? Exit 0 only if every check passes.
# Read-only: it logs in and asks questions, it never writes a study or a file.
#
#   scripts/health.sh
#
# What it checks, and what each check catches:
#   units        the five systemd units are active
#   ports        gateway, manager and viewer answer on loopback; the proxy answers on
#                the public address for /, /viewer/ and /api/
#   databases    both are reachable as the deploy role
#   login        the worker's gateway account can log in (wrong SECRET_KEY, missing
#                account, gateway cannot reach its database)
#   blob store   an authenticated /data request is answered by the blob-metadata
#                database — a gateway with broken blob settings starts fine and then
#                answers 500 on every file
#   disks        blob root and work dir belong to the deploy user and have free space
#   GPU          visible; no process of the deploy user holds GPU memory outside the
#                worker unit (what a crashed registration leaves behind)
#   models       scripts/verify-models.sh (presence and size; --full reads the weights)
#   modules      scripts/check-modules.sh (worker source and gateway database)
#
# VS_MIN_FREE_GB (default 20) is the free-space floor for the data and work disks.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail=0
ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }
warn() { printf 'warn  %s\n' "$*"; }
check() { # LABEL COMMAND...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null; }
GW="http://127.0.0.1:$VS_GATEWAY_PORT"
if [ "$VS_PUBLIC_PORT" = "80" ]; then PUB="http://$VS_HOST"; else PUB="http://$VS_HOST:$VS_PUBLIC_PORT"; fi

# --- units ------------------------------------------------------------------------
for u in $VS_UNITS; do
  check "unit $u is active" systemctl is-active --quiet "$u"
done

# --- ports ------------------------------------------------------------------------
check "gateway answers on :$VS_GATEWAY_PORT"  curl -s  -o /dev/null --max-time 5 "$GW/"
check "manager answers on :$VS_MANAGER_PORT"  curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:$VS_MANAGER_PORT/"
check "viewer answers on :$VS_VIEWER_PORT"    curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:$VS_VIEWER_PORT/"
check "proxy serves the manager at $PUB/"     curl -sf -o /dev/null --max-time 5 "$PUB/"
c="$(http_code "$PUB/viewer/")"
[ "$c" = "200" ] && ok "proxy serves the viewer at $PUB/viewer/" || bad "proxy serves the viewer at $PUB/viewer/ (http $c)"
# No token: the gateway itself must answer 401. Anything else means /api does not reach it.
c="$(http_code "$PUB/api/case_studies")"
[ "$c" = "401" ] && ok "proxy reaches the gateway at $PUB/api/ (401 without a token, as it should)" || bad "proxy reaches the gateway at $PUB/api/ (expected 401 without a token, got http $c)"

# --- databases ----------------------------------------------------------------------
for db in "$VS_DB_NAME" "$VS_DS_DB_NAME"; do
  if PGPASSWORD="$VS_DB_PASSWORD" psql -X -At -h "$VS_PG_HOST" -p "$VS_PG_PORT" -U "$VS_DB_USER" -d "$db" -c 'select 1' >/dev/null 2>&1; then
    ok "database $db is reachable as $VS_DB_USER"
  else bad "database $db is reachable as $VS_DB_USER"; fi
done

# --- login and blob store -------------------------------------------------------------
# The password goes in a request body read from stdin, never on a command line.
token="$(printf '{"username":"%s","password":"%s"}' "$VS_WORKER_USER" "$VS_WORKER_PASSWORD" \
  | curl -s --max-time 10 -H 'Content-Type: application/json' --data-binary @- "$GW/login" 2>/dev/null \
  | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [ -n "$token" ]; then
  ok "gateway login works for the worker account ($VS_WORKER_USER)"
  # A file id that cannot exist. A working blob store looks it up and says 404;
  # a gateway whose blob settings are wrong answers 500.
  c="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - "$GW/data?id=2147483000" 2>/dev/null)"
  case "$c" in
    404) ok "blob store answers (unknown file id -> 404; the blob-metadata database is being read)" ;;
    *)   bad "blob store: an unknown file id should give 404, got http $c (check DATA_ROOT_DIR, FILE_ADAPTER_TYPE, DS_DB_* in the gateway's .env)" ;;
  esac
else
  bad "gateway login works for the worker account ($VS_WORKER_USER) — no token returned (install/accounts.sh --list shows the accounts)"
  bad "blob store: not checked (no login)"
fi

# --- disks ----------------------------------------------------------------------------
min_gb="${VS_MIN_FREE_GB:-20}"
for pair in "blob root:$VS_DATA_ROOT" "work dir:$VS_WORK_DIR"; do
  label="${pair%%:*}"; d="${pair#*:}"
  if [ ! -d "$d" ]; then bad "$label $d exists"; continue; fi
  owner="$(stat -c %U "$d" 2>/dev/null)"; mode="$(stat -c %a "$d" 2>/dev/null)"
  case "$mode" in [2367]??) w=1 ;; *) w=0 ;; esac
  if [ "$owner" = "$VS_USER" ] && [ "$w" -eq 1 ]; then ok "$label $d belongs to $VS_USER and is writable by it"
  else bad "$label $d must belong to $VS_USER and be writable by it (owner $owner, mode $mode)"; fi
  free="$(df -BG --output=avail "$d" 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [ "${free:-0}" -ge "$min_gb" ]; then ok "$label has ${free} GB free (floor: $min_gb GB)"
  else bad "$label has ${free:-?} GB free, below the floor of $min_gb GB"; fi
done

# --- GPU --------------------------------------------------------------------------------
if nvidia-smi >/dev/null 2>&1; then
  ok "GPU is visible ($(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader | head -1))"
  stray=""
  for pid in $(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null); do
    [ -d "/proc/$pid" ] || continue
    [ "$(stat -c %U "/proc/$pid" 2>/dev/null)" = "$VS_USER" ] || continue      # someone else's work
    grep -q 'valvescope-handler\.service' "/proc/$pid/cgroup" 2>/dev/null || stray="$stray $pid"
  done
  if [ -z "$stray" ]; then ok "no GPU process of $VS_USER outside the worker unit"
  else bad "GPU memory is held by process(es) of $VS_USER that are not part of the worker unit:$stray (left by a crashed run; look before stopping them)"; fi
else
  bad "GPU is visible (nvidia-smi fails; 'version mismatch' means a driver update is waiting for a reboot)"
fi

# --- models and modules: these print their own ok/warn/FAIL lines ------------------------
"$(dirname "$0")/verify-models.sh" || fail=1
"$(dirname "$0")/check-modules.sh" || fail=1

if [ "$fail" -eq 0 ]; then echo "health: all checks passed"; else echo "health: PROBLEMS — see the FAIL lines above"; fi
exit $fail
