#!/usr/bin/env bash
# stop.sh — stop every ValveScope service (needs sudo). Postgres is left running:
# the developer checkout on the same box may share the cluster.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
# The target only pulls units in; stopping it relies on PartOf= in each unit.
sudo systemctl stop "$VS_TARGET"
