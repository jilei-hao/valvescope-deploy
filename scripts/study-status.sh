#!/usr/bin/env bash
# study-status.sh STUDY_ID — the module status of one study, read from the database.
# Read-only. Exit 0 when every module is completed, 1 otherwise.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
case "${1:-}" in ''|*[!0-9]*) echo "usage: scripts/study-status.sh STUDY_ID" >&2; exit 2 ;; esac
out="$(PGPASSWORD="$VS_DB_PASSWORD" psql -X -At -F '  ' -h "$VS_PG_HOST" -p "$VS_PG_PORT" -U "$VS_DB_USER" -d "$VS_DB_NAME" -c "
  select rpad(m.module_name, 20), rpad(l.study_module_status_name, 10), 'attempts ' || sms.attempt_count, left(coalesce(sms.last_error, ''), 100)
  from study_module_status sms
  join module m using (module_id)
  join study_module_status_lut l using (study_module_status_id)
  where sms.study_id = $1 order by m.module_precedence_rank")" || exit 2
[ -n "$out" ] || { echo "study-status: no study $1"; exit 2; }
printf '%s\n' "$out"
printf '%s\n' "$out" | awk '$2 != "completed" { bad = 1 } END { exit bad }'
