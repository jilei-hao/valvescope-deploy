#!/usr/bin/env bash
# upgrade.sh — STUB (WS-4). Move the deployment to a new versions.lock.
#
# Intended steps:
#   1. scripts/backup.sh
#   2. keep the current lock as versions.lock.previous (what rollback.sh returns to)
#   3. git pull this repo (brings the new versions.lock)
#   4. install/fetch-sources.sh
#   5. reinstall dependencies where a lock file changed (npm ci, pip install -e, conda env update)
#   6. config/render.sh --install; rebuild manager and viewer (their config is baked at build)
#   7. apply gateway database migrations
#   8. restart the services; scripts/health.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
not_implemented "see the plan in this file's header"
