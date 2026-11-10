#!/usr/bin/env bash
# health.sh — is the deployment working? Exit 0 only if every check passes.
#
# STUB (WS-4): the checks below are the intended list. Unit state and port
# checks are real; the ones marked TODO need the installed system to design against.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail=0
check() { # LABEL COMMAND...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'ok    %s\n' "$label"; else printf 'FAIL  %s\n' "$label"; fail=1; fi
}
for u in $VS_UNITS; do
  check "unit $u is active" systemctl is-active --quiet "$u"
done
check "gateway answers on :$VS_GATEWAY_PORT"  curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$VS_GATEWAY_PORT/"
check "manager answers on :$VS_MANAGER_PORT"  curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:$VS_MANAGER_PORT/"
check "viewer answers on :$VS_VIEWER_PORT"    curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:$VS_VIEWER_PORT/"
check "proxy answers on $VS_HOST:$VS_PUBLIC_PORT" curl -sf -o /dev/null --max-time 5 "http://$VS_HOST:$VS_PUBLIC_PORT/"
check "blob root is writable" test -w "$VS_DATA_ROOT"
check "work dir is writable"  test -w "$VS_WORK_DIR"
check "GPU is visible"        nvidia-smi
# TODO(WS-4): both databases reachable with the deploy role (psql, needs PGPASSWORD handling)
# TODO(WS-4): gateway login works and a /data request returns 200 (catches the
#             "boots healthy, 500s on every blob" failure)
# TODO(WS-4): no stray GPU process left by a crashed worker (nvidia-smi --query-compute-apps)
# TODO(WS-4): free disk on the data root and work dir above a threshold
exit $fail
