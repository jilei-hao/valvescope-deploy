# ValveScope runbook

For whoever operates the server. **Outline only** — sections marked *(to write)*
get filled in as each piece is built and proven on the host.

## 1. The system in one page
- What runs where: five systemd units under `valvescope.target`; Postgres; the GPU.
- Where things live: `/opt/valvescope` (deploy repo, sources, conda), the data
  root, the work dir, the backup mount. All set in `config/deploy.env`.
- The developer checkout on the same box, and why the two never share anything
  (see the coexistence table in the README).

## 2. Everyday commands
- Start / stop / status: `scripts/start.sh`, `scripts/stop.sh`, `systemctl status 'valvescope-*'`
- Is it healthy: `scripts/health.sh`
- Logs: `journalctl -u valvescope-handler -f` (same for the other units)

## 3. First install *(to write with install.sh)*
- Prerequisites check · create user and directories · secrets · sources ·
  databases · conda environments · builds · units · accounts · firewall · first health check.

## 4. Changing configuration
- Edit `config/deploy.env` → `config/render.sh --install` → restart.
- Manager and viewer bake configuration at build: rebuild them, a restart is not enough.
- Never edit a service's `.env` directly; the next render overwrites it.

## 5. Upgrade and rollback *(to write with upgrade.sh / rollback.sh)*
- How a new `versions.lock` arrives, what `upgrade.sh` does, how to confirm it.
- Rolling back, and the limit: database migrations only go forward.

## 6. Backup and restore *(to write with backup.sh)*
- What is in a backup (both databases, the blob root, `deploy.env`, `versions.lock`).
- Schedule, retention, where on the NAS.
- Restore procedure, and the date of the last restore rehearsal.

## 7. User accounts *(to write)*
- Adding and removing a person. The worker's own account. Resetting a password.

## 8. Troubleshooting
Known failure modes, each with symptom → cause → fix. Seeded from the July 2026
deploy audit; verify each on the deployed system before relying on it.

| Symptom | Likely cause | Fix |
|---|---|---|
| Gateway is up but every file request returns 500 | blob-store settings missing from its `.env` | re-render; check `DATA_ROOT_DIR`, `DS_DB_*` |
| Web viewer loads, shows no studies, no error | viewer built with `localhost` as the gateway host | fix `VS_HOST`, re-render, rebuild the viewer |
| A study fails with out-of-memory on the GPU | a crashed run left a process holding GPU memory | `nvidia-smi --query-compute-apps=pid,used_memory --format=csv`; restart the worker unit |
| Worker runs but picks up no tasks, or runs old code | started with the bare `avrp-handler` command | only ever via the unit (`python -m src.main` in the checkout) |
| Work dir fills the disk | the worker never deletes its scratch files | stop the worker, empty `$VS_WORK_DIR` *(automatic cleanup: to do)* |
| Browsers cannot reach the server after a reboot | the box's DHCP address changed | *(to write once the hostname is settled)* |

## 9. Who to ask *(to write)*
