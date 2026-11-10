#!/usr/bin/env bash
# backup.sh — STUB (WS-4). Back up everything needed to rebuild the deployment's data.
#
# The backup set is:
#   1. pg_dump of $VS_DB_NAME     (users, cases, studies, task queue, module status)
#   2. pg_dump of $VS_DS_DB_NAME  (blob metadata — useless without the files, and vice versa)
#   3. the blob root $VS_DATA_ROOT (rsync; large)
#   4. config/deploy.env and versions.lock (so the same versions can read the data)
# Destination: $VS_BACKUP_DIR/<UTC timestamp>/ on the lab NAS.
# Not backed up: $VS_WORK_DIR (scratch), sources and conda envs (rebuilt from the lock).
#
# Open points: dump the two DBs in one consistent moment (stop the gateway, or
# accept a small window); retention; a restore.sh and one restore rehearsal.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
not_implemented "see the plan in this file's header"
