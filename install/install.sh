#!/usr/bin/env bash
# install.sh — STUB (WS-4). Bare Ubuntu 24.04 host -> running ValveScope.
#
# Prerequisites it checks but does not install (see README): NVIDIA driver,
# miniconda at $VS_CONDA_ROOT, Node >= 20, Postgres 16, caddy, git, openssl.
#
# Intended steps, in order. Each will be idempotent, so a failed run can be repeated.
#   1. check prerequisites; refuse dev-checkout ports / DB names (config/render.sh does this)
#   2. create the Unix user $VS_USER and the directories (home, data root, work dir, upload cache)
#   3. install/gen-secrets.sh                      [exists]
#   4. install/fetch-sources.sh                    [exists]
#   5. install/db-init.sh                          [exists] role + both databases; never drops
#   6. conda envs: $VS_HANDLER_ENV (segflow4d + handler) and $VS_AUTOSEG_ENV, from exported env files
#   7. npm ci in gateway, manager, view-service
#   8. config/render.sh --install                  [exists]
#   9. build manager (next build) and viewer (vite build)
#  10. install rendered/systemd/* to /etc/systemd/system, daemon-reload, enable valvescope.target
#  11. create the worker account and the per-person accounts from config/accounts.txt
#  12. firewall: only $VS_PUBLIC_PORT open on the LAN
#  13. scripts/start.sh; scripts/health.sh
set -euo pipefail
echo "install.sh: not implemented yet — steps 3, 4, 5 and 8 can be run by hand today (scripts/upgrade.sh --plan shows the install order); see the header" >&2
exit 3
