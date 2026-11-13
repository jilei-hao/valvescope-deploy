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

# --- who runs what ----------------------------------------------------------------
# The scripts are run by an operator (a person with sudo). Everything the services
# own — sources, conda, builds, data — belongs to $VS_USER, so those steps run as
# that user. Secrets stay with the operator: config/deploy.env is never read by
# $VS_USER, which only receives the rendered files it needs.
vs_as_user() { # COMMAND... — run as the deploy user (cwd is kept)
  if [ "$(id -un)" = "$VS_USER" ]; then "$@"; else sudo -u "$VS_USER" -H "$@"; fi
}
# Same, for commands that download (pip, conda, npm). On a network that re-signs
# TLS (the lab firewall does this for download.pytorch.org) the tools' own CA
# bundles reject the connection; VS_CA_BUNDLE points them at the system store, which
# has the site CA. Verification stays on. Empty/unset = tool defaults.
# npm and npx are found next to $VS_NODE_BIN, ahead of whatever the system has.
vs_as_user_net() {
  local path; path="$(dirname "$VS_NODE_BIN"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  if [ -n "${VS_CA_BUNDLE:-}" ]; then
    vs_as_user env PATH="$path" PIP_CERT="$VS_CA_BUNDLE" REQUESTS_CA_BUNDLE="$VS_CA_BUNDLE" \
      NODE_EXTRA_CA_CERTS="$VS_CA_BUNDLE" PIP_NO_INPUT=1 NEXT_TELEMETRY_DISABLED=1 "$@"
  else
    vs_as_user env PATH="$path" PIP_NO_INPUT=1 NEXT_TELEMETRY_DISABLED=1 "$@"
  fi
}
# Fetch pinned sources as the deploy user. Most pinned repositories are private and
# $VS_USER has no GitHub credential of its own, so the operator's stored credential
# is handed to that one fetch on stdin. It lives in the fetch process's memory and
# environment only; nothing is written to disk for $VS_USER.
vs_fetch_sources() { # fetch-sources.sh arguments...
  if [ "$(id -un)" = "$VS_USER" ]; then "$REPO_DIR/install/fetch-sources.sh" "$@"; return; fi
  local cred
  cred="$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null || true)"
  [ -n "$cred" ] || echo "valvescope: no stored git credential for github.com — private repositories will fail to fetch" >&2
  printf '%s\n' "$cred" | sudo -u "$VS_USER" -H "$REPO_DIR/install/fetch-sources.sh" --credential-stdin "$@"
}
vs_conda_env_prefix() { printf '%s/envs/%s' "$VS_CONDA_ROOT" "$1"; }

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
