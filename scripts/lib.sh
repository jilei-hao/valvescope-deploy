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

# --- models ---------------------------------------------------------------------
vs_sha256() { # FILE -> sha256 of its contents
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1
  else shasum -a 256 < "$1" | cut -d' ' -f1; fi
}
# Files whose CONTENT is hashed in a model's file list: weights and configuration.
# Everything else is listed by size only. Changing this rule changes every checksum.
vs_model_hashed() { # RELATIVE PATH -> success if this file gets a sha256
  case "$1" in *.pth|*.pt|*.ckpt|*.onnx|*.json|*.pkl|*.yaml|*.yml) return 0 ;; *) return 1 ;; esac
}
vs_model_dir() { # LOCATION SUBDIR -> directory (LOCATION is a deploy.env variable or an absolute path)
  local base
  case "$1" in
    /*) base="$1" ;;
    *)  eval "base=\${$1:-}"
        [ -n "$base" ] || { echo "valvescope: models.manifest names $1, which is not set in deploy.env" >&2; return 1; } ;;
  esac
  printf '%s/%s' "$base" "$2"
}
