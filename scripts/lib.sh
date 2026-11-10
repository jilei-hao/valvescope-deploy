# lib.sh — shared by the scripts in this directory. Source it, do not run it.
# Loads config/deploy.env and defines the unit list.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${VS_DEPLOY_ENV:-$REPO_DIR/config/deploy.env}"
if [ ! -f "$ENV_FILE" ]; then
  echo "valvescope: $ENV_FILE not found (copy config/deploy.env.example to it)" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
VS_TARGET=valvescope.target
VS_UNITS="valvescope-gateway valvescope-handler valvescope-manager valvescope-viewer valvescope-proxy"
not_implemented() {
  echo "$(basename "$0"): not implemented yet — $1" >&2
  exit 3
}
