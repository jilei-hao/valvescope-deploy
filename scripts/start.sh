#!/usr/bin/env bash
# start.sh — start every ValveScope service (needs sudo).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
sudo systemctl start "$VS_TARGET"
exec "$(dirname "$0")/health.sh"
