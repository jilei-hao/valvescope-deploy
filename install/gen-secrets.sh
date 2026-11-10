#!/usr/bin/env bash
# gen-secrets.sh — replace every CHANGE_ME in config/deploy.env with a random value.
# Safe to re-run: values that are already set are left alone.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-$REPO_DIR/config/deploy.env}"
[ -f "$ENV_FILE" ] || { echo "gen-secrets: $ENV_FILE not found" >&2; exit 1; }
chmod 600 "$ENV_FILE"
tmp="$(mktemp "$ENV_FILE.XXXXXX")"
n=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    [A-Z]*=CHANGE_ME)
      # hex only: safe inside .env files, systemd units and URLs
      line="${line%%=*}=$(openssl rand -hex 24)"
      n=$((n + 1)) ;;
  esac
  printf '%s\n' "$line"
done < "$ENV_FILE" > "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$ENV_FILE"
echo "gen-secrets: generated $n value(s) in $ENV_FILE"
