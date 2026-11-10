#!/usr/bin/env bash
# rollback.sh — STUB (WS-4). Return to the previous versions.lock.
#
# Code rollback already works without this script: put the old SHA back in
# versions.lock (git revert the commit that moved it) and run scripts/upgrade.sh.
# The diff against deployed.lock then moves just that component back.
#
# What this script still has to add: remembering the previous lock automatically.
#
# Open point: the DATABASE does not roll back. Migrations only go forward, and
# install/db-init.sh never undoes one. Rolling the gateway back across a schema
# change means either the old gateway tolerates the newer schema, or the database
# dump that upgrade.sh took before migrating is restored (losing what was written
# since). Decide which, per release, before the first real upgrade.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
not_implemented "see the plan in this file's header"
