#!/usr/bin/env bash
# rollback.sh — STUB (WS-4). Return to the previous versions.lock.
#
# Intended steps:
#   1. swap versions.lock with versions.lock.previous
#   2. install/fetch-sources.sh, dependencies, render, rebuild — as in upgrade.sh
#   3. restart the services; scripts/health.sh
#
# Open point: database migrations only go forward. A rollback across a schema
# change needs either a down-migration or a restore of the pre-upgrade backup;
# decide which before the first real upgrade.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
not_implemented "see the plan in this file's header"
