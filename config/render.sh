#!/usr/bin/env bash
# render.sh — turn config/deploy.env into every generated file.
#
#   config/render.sh [--env FILE] [--out DIR] [--allow-placeholders] [--install]
#
#   --env FILE            deploy.env to read (default: config/deploy.env)
#   --out DIR             output directory (default: ./rendered, gitignored)
#   --allow-placeholders  render even if secrets are still CHANGE_ME (for a dry run)
#   --install             also put the generated files where the services read them:
#                         each service's .env into its checkout under $VS_HOME/src,
#                         the Caddyfile into $VS_HOME/etc. They belong to $VS_USER;
#                         when run by anyone else this uses sudo. A file whose
#                         content is unchanged is left alone. Checkouts that are not
#                         fetched yet are skipped. systemd units are installed by
#                         install/install.sh, not here.
#
# Output:
#   rendered/env/<service>.env     from config/templates/*.env.tmpl
#   rendered/systemd/*             from services/*.service.tmpl and *.target
#   rendered/Caddyfile             from services/Caddyfile.tmpl
#
# Templates use @NAME@ placeholders. Every NAME must be a variable from deploy.env
# or one of the derived variables below; an unknown name is an error, so a typo
# cannot silently render as an empty string.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# VS_DEPLOY_ENV selects another deploy.env, as it does for every script that uses scripts/lib.sh.
ENV_FILE="${VS_DEPLOY_ENV:-$REPO_DIR/config/deploy.env}"
OUT="${VS_RENDER_OUT:-$REPO_DIR/rendered}"
ALLOW_PLACEHOLDERS=0
INSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_FILE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --allow-placeholders) ALLOW_PLACEHOLDERS=1; shift ;;
    --install) INSTALL=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "render: unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { printf 'render: %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found (copy config/deploy.env.example to it)"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

REQUIRED="VS_HOST VS_PUBLIC_PORT VS_USER VS_HOME VS_DATA_ROOT VS_WORK_DIR VS_UPLOAD_CACHE
VS_BACKUP_DIR VS_GATEWAY_PORT VS_MANAGER_PORT VS_VIEWER_PORT VS_PG_HOST VS_PG_PORT VS_DB_NAME
VS_DS_DB_NAME VS_DB_USER VS_DB_PASSWORD VS_JWT_SECRET VS_WORKER_USER VS_WORKER_PASSWORD
VS_MODULE_LIST VS_CONDA_ROOT VS_HANDLER_ENV VS_AUTOSEG_ENV VS_CT_MODELS_DIR VS_TEE_MODELS_DIR
VS_AUTOSEG_FOLDS VS_STUDYGEN_ROI_CROP_PADDING VS_NODE_BIN VS_CADDY_BIN"
for v in $REQUIRED; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || die "$v is missing or empty in $ENV_FILE"
  if [ "$val" = "CHANGE_ME" ] && [ "$ALLOW_PLACEHOLDERS" -eq 0 ]; then
    die "$v is still CHANGE_ME — run install/gen-secrets.sh (or pass --allow-placeholders for a dry run)"
  fi
done

# --- Coexistence with the developer checkout on the same box -----------------
case "$VS_HOST" in localhost|127.*|::1) die "VS_HOST must be the LAN name/address, not $VS_HOST" ;; esac
for p in "$VS_PUBLIC_PORT" "$VS_GATEWAY_PORT" "$VS_MANAGER_PORT" "$VS_VIEWER_PORT"; do
  case "$p" in 3000|3010|5173|7070|8000) die "port $p belongs to the dev checkout; pick another" ;; esac
done
[ "$VS_GATEWAY_PORT" != "$VS_MANAGER_PORT" ] && [ "$VS_GATEWAY_PORT" != "$VS_VIEWER_PORT" ] \
  && [ "$VS_MANAGER_PORT" != "$VS_VIEWER_PORT" ] || die "internal ports must all differ"
for d in "$VS_DB_NAME" "$VS_DS_DB_NAME"; do
  case "$d" in avrpdb|avrpdsdb) die "database name $d belongs to the dev checkout; pick another" ;; esac
done
[ "$VS_DB_NAME" != "$VS_DS_DB_NAME" ] || die "VS_DB_NAME and VS_DS_DB_NAME must differ"
for d in "$VS_HOME" "$VS_DATA_ROOT" "$VS_WORK_DIR"; do
  case "$d" in */avrp-developer*|*/avrp-dev*) die "$d is inside a developer checkout" ;; esac
done

# The module list must be usable before anything is rendered from it.
VS_DEPLOY_ENV="$ENV_FILE" "$REPO_DIR/scripts/check-modules.sh" --list-only >/dev/null \
  || { VS_DEPLOY_ENV="$ENV_FILE" "$REPO_DIR/scripts/check-modules.sh" --list-only >&2; die "fix VS_MODULE_LIST in $ENV_FILE"; }

# --- Derived values (not set by hand) -----------------------------------------
if [ "$VS_PUBLIC_PORT" = "80" ]; then
  VS_PUBLIC_ORIGIN="http://$VS_HOST"
else
  VS_PUBLIC_ORIGIN="http://$VS_HOST:$VS_PUBLIC_PORT"
fi
VS_SRC_DIR="$VS_HOME/src"
VS_DEPLOY_DIR="$REPO_DIR"
VS_RENDERED_DIR="$OUT"
VS_ETC_DIR="$VS_HOME/etc"
VS_GATEWAY_INTERNAL_URL="http://127.0.0.1:$VS_GATEWAY_PORT"
VS_HANDLER_PYTHON="$VS_CONDA_ROOT/envs/$VS_HANDLER_ENV/bin/python"
VS_AUTOSEG_CLI="$VS_CONDA_ROOT/envs/$VS_AUTOSEG_ENV/bin/avrp-auto-seg"
export VS_PUBLIC_ORIGIN VS_SRC_DIR VS_DEPLOY_DIR VS_RENDERED_DIR VS_ETC_DIR VS_GATEWAY_INTERNAL_URL \
       VS_HANDLER_PYTHON VS_AUTOSEG_CLI

render_one() { # TEMPLATE OUTPUT MODE
  awk '
    {
      line = $0; out = ""
      while (match(line, /@[A-Z][A-Z0-9_]*@/)) {
        name = substr(line, RSTART + 1, RLENGTH - 2)
        if (!(name in ENVIRON)) {
          printf "render: unknown placeholder @%s@ in %s\n", name, FILENAME > "/dev/stderr"
          bad = 1
        }
        out = out substr(line, 1, RSTART - 1) ENVIRON[name]
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
    END { exit bad }
  ' "$1" > "$2.tmp" || { rm -f "$2.tmp"; exit 1; }
  chmod "$3" "$2.tmp"
  mv "$2.tmp" "$2"
}

umask 077
mkdir -p "$OUT/env" "$OUT/systemd"

for t in "$REPO_DIR"/config/templates/*.env.tmpl; do
  render_one "$t" "$OUT/env/$(basename "$t" .tmpl)" 600
done
for t in "$REPO_DIR"/services/*.service.tmpl; do
  render_one "$t" "$OUT/systemd/$(basename "$t" .tmpl)" 644
done
for t in "$REPO_DIR"/services/*.target; do
  render_one "$t" "$OUT/systemd/$(basename "$t")" 644
done
render_one "$REPO_DIR/services/Caddyfile.tmpl" "$OUT/Caddyfile" 644
echo "rendered into $OUT"

if [ "$INSTALL" -eq 1 ]; then
  as_owner() { if [ "$(id -un)" = "$VS_USER" ]; then "$@"; else sudo -u "$VS_USER" "$@"; fi; }
  put() { # SOURCE DEST MODE — only when the content differs, so a re-run changes nothing
    local src="$1" dest="$2" mode="$3"
    if ! as_owner test -d "$(dirname "$dest")"; then
      echo "skip      $dest (its directory does not exist yet)"; return 0
    fi
    if as_owner cmp -s - "$dest" < "$src" 2>/dev/null; then
      echo "unchanged $dest"; return 0
    fi
    # Read as the operator, written as the owner: $VS_USER cannot read rendered/.
    # The owner reads the content from its inherited stdin (it could not open the
    # file itself), writes a private temporary file and moves it into place.
    as_owner sh -c 'umask 077 && cat > "$1.tmp" && chmod "$2" "$1.tmp" && mv "$1.tmp" "$1"' sh "$dest" "$mode" < "$src"
    echo "installed $dest"
    changed=1
  }
  changed=0
  # Where each service actually reads its configuration from.
  put "$OUT/env/gateway.env"      "$VS_SRC_DIR/avrp-gateway/.env" 600
  put "$OUT/env/handler.env"      "$VS_SRC_DIR/avrp-handler/.env" 600
  put "$OUT/env/manager.env"      "$VS_SRC_DIR/avrp-manager/.env.production.local" 600
  put "$OUT/env/view-service.env" "$VS_SRC_DIR/avrp-view-service/.env.production.local" 600
  put "$OUT/Caddyfile"            "$VS_ETC_DIR/Caddyfile" 644
  [ "$changed" -eq 0 ] || echo "note: manager and view-service read theirs at BUILD time — rebuild them after a change; restart the others"
fi
