# lib.sh — shared by the scripts in this repo. Source it, do not run it.
# Loads config/deploy.env and defines common names.
#
# Set VS_ALLOW_EXAMPLE=1 before sourcing to fall back to deploy.env.example when
# no deploy.env exists (used by read-only "--plan" modes, never by anything that acts).
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${VS_DEPLOY_ENV:-$REPO_DIR/config/deploy.env}"
VS_USING_EXAMPLE=0
if [ ! -f "$ENV_FILE" ]; then
  if [ "${VS_ALLOW_EXAMPLE:-0}" = "1" ]; then
    ENV_FILE="$REPO_DIR/config/deploy.env.example"
    VS_USING_EXAMPLE=1
  else
    echo "valvescope: $ENV_FILE not found (copy config/deploy.env.example to it)" >&2
    exit 1
  fi
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
VS_SRC_DIR="${VS_SRC_DIR:-$VS_HOME/src}"
# Where the server records what is actually deployed (not in git, not in the sources).
VS_STATE_DIR="${VS_STATE_DIR:-$VS_HOME/state}"
VS_TARGET=valvescope.target
VS_UNITS="valvescope-gateway valvescope-handler valvescope-manager valvescope-viewer valvescope-proxy"
not_implemented() {
  echo "$(basename "$0"): not implemented yet — $1" >&2
  exit 3
}
