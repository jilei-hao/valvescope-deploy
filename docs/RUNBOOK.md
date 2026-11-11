# ValveScope runbook

For whoever operates the server. Sections marked *(to write)* are still outlines;
the README's Status table says which parts have actually run on the host.

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

## 3. First install

One command, safe to repeat: `install/install.sh`. It needs a person with sudo.

**Before it** (it checks these and stops with the exact command if one is missing;
it installs none of them):

```bash
sudo apt install caddy gcc-12 g++-12
sudo systemctl disable --now caddy.service   # Ubuntu's package starts a welcome page on port 80
```

plus a working `nvidia-smi`, Node >= 20, PostgreSQL 16 on the port in `deploy.env`,
and a stored git credential for github.com on your own account (most pinned
repositories are private; `git ls-remote https://github.com/jilei-hao/avrp-gateway.git`
must work for you).

**Where the repository goes.** The deploy user must be able to read it, and a home
directory usually is not readable by others. Put it in `$VS_HOME`:

```bash
sudo install -d -o "$USER" /opt/valvescope/valvescope-deploy
git clone https://github.com/jilei-hao/valvescope-deploy /opt/valvescope/valvescope-deploy
cd /opt/valvescope/valvescope-deploy
cp config/deploy.env.example config/deploy.env    # edit: VS_HOST, VS_BACKUP_DIR, VS_LAN_CIDR
install/install.sh --check                        # prerequisites only; changes nothing
install/install.sh
```

**Who owns what.** You own the repository and `config/deploy.env` (mode 600; the
only place secrets are kept). The deploy user (`valvescope`) owns sources, conda,
builds and data, and never sees `deploy.env`: it gets the rendered service files.

**The steps** (`install/install.sh --from N` resumes at one):

| # | Step | Notes |
|---|---|---|
| 1 | prerequisites, configuration | refuses the developer checkout's ports, database names and paths |
| 2 | Unix user and directories | existing directories keep their contents |
| 3 | secrets | only fills values still set to `CHANGE_ME` |
| 4 | miniconda at `$VS_CONDA_ROOT` | pinned installer, checksum verified |
| 5 | systemd units | installed and enabled; nothing started |
| 6 | model weights | **stops here until a person has copied them** — see 5b |
| 7 | gateway and databases | `scripts/upgrade.sh --only avrp-gateway` |
| 8 | accounts | worker account + `config/accounts.txt` — see 7 |
| 9 | everything else | `scripts/upgrade.sh`: conda envs (slow: ~15 GB of downloads), FireANTs compile, worker, manager and viewer builds |
| 10 | firewall | prints the ufw rule; `--apply-firewall` applies it |
| 11 | start and health | `scripts/health.sh` |

- The lab firewall re-signs TLS for `download.pytorch.org`. `VS_CA_BUNDLE` in
  `deploy.env` points pip at the system CA store; without it the worker
  environment fails with `CERTIFICATE_VERIFY_FAILED`.
- Copying the models (step 6), as a person, once:
  `sudo cp -a <source>/Dataset900_LOOCV_f0 $VS_CT_MODELS_DIR/` (same for the two
  TEE datasets under `$VS_TEE_MODELS_DIR`), `sudo chown -R valvescope: /srv/valvescope/models`,
  then `scripts/verify-models.sh --full`.

## 4. Changing configuration
- Edit `config/deploy.env` → `config/render.sh --install` → restart.
- Manager and viewer bake configuration at build: rebuild them, a restart is not enough.
- Never edit a service's `.env` directly; the next render overwrites it.

## 5. Upgrading

The server remembers what is installed in `$VS_STATE_DIR/deployed.lock`. An upgrade
is the difference between that and `versions.lock`.

1. Get the new `versions.lock` (`git pull` in the deploy repo).
2. **Look first:** `scripts/upgrade.sh --plan`. It lists, per changed component,
   the exact steps and which services stop. It changes nothing.
3. **Do it:** `scripts/upgrade.sh`. To do only part: `--only segflow4d,avrp-handler`
   (also `env:<name>` and `model:<name>`).
4. It finishes with `scripts/health.sh`.

What to expect, by component (from `components.map`):

| Changed | Reinstall | Build | Database | Services restarted |
|---|---|---|---|---|
| `segflow4d` | `pip install -e` into the worker env | — | — | worker |
| `avrp-handler` | `pip install -e` into the worker env | — | — | worker |
| `avrp-auto-seg` | `conda env update` of its own env | — | — | none (next task picks it up) |
| `avrp-gateway` | `npm ci` | — | dump both, then `db-init.sh` | gateway |
| `avrp-manager` | `npm ci` | `next build` | — | manager |
| `avrp-view-service` | `npm ci` | `vite build` | — | none (static files) |
| a conda environment file in `envs/` | create or update that environment | — | — | the units listed for it |
| a model in `models.manifest` | you copy the files; full verify | — | — | the units listed for it |

- **If it fails part-way:** the component that failed is not recorded as deployed
  and its services stay stopped. Fix the cause and run `scripts/upgrade.sh` again;
  finished components are skipped.
- A worker restart interrupts a running study. *(How the task is retried — to verify on the host.)*
- *(Not yet run on the server: the executor half of `upgrade.sh`.)*

### Going back

Put the old SHA back in `versions.lock` and run `scripts/upgrade.sh`; it moves just
that component back. **The database does not go back**: migrations only run
forward. Before a gateway upgrade, `upgrade.sh` dumps both databases to
`$VS_BACKUP_DIR/db/<timestamp>/`; restoring that dump is the only way to undo a
migration, and it loses everything written since.

## 5a. The databases

`install/db-init.sh` is the only thing that changes database structure.

- `install/db-init.sh --plan` — what it would do. Read-only.
- It creates what is missing and applies migrations that have not run. On a
  database with studies it never applies the schema or seed files again.
- When it stops with a message, it has changed nothing. The cases:

| Message | Meaning | What to do |
|---|---|---|
| *has tables but no vs_schema_migrations table* | this database was not created by `db-init.sh` | make sure it is the right database; then `--adopt` |
| *schemas.sql / seed.sql changed since this database was created* | upstream edited a create-time file; the change has not reached this server | confirm a migration in the same release carries it, then `--accept-baseline-change`; otherwise report upstream |
| *pending migration … removes whole tables* | a migration would drop or empty a table | read the file; `--allow-destructive-migration <file>` only if intended, after a backup |
| *database name … is reserved* | `deploy.env` points at the developer's database | fix `deploy.env` |

- **Never** run the gateway's `npm run reset-db`, `reset-data` or
  `avrp-util/deployment/rebuild-dev.sh` on this server's databases. They drop them.

### Removing data on purpose

Only `scripts/destroy-*.sh` can remove data. Run one without arguments to see what
exists and what would go; it deletes only what you name with its `--yes-destroy-…`
flag. `destroy-databases.sh` leaves the blob root alone, so after it the files on
disk no longer match any database — restore a dump or clear the blob root by hand.

## 5b. Adding or changing a model

Weights are copied to the server by a person; nothing here downloads them.

1. Copy the model directory to its place (for the current models, under
   `VS_CT_MODELS_DIR` or `VS_TEE_MODELS_DIR`). Replacing a model the worker is
   using: `sudo systemctl stop valvescope-handler` first.
2. New model: add a line to `models.manifest` — name, location (a `deploy.env`
   variable or an absolute path), sub-directory, version label, `UNMEASURED`, and
   the units to restart. If it lives under a new directory, add that variable to
   `config/deploy.env.example` and to the server's `deploy.env`.
3. Measure it **on the server**:
   `scripts/model-manifest.sh --name <name> --version <label> --write`
   This writes `models/<name>.files` and puts the checksum in the manifest.
   It reads every weight file once, so allow a few minutes.
4. Commit `models.manifest` and `models/<name>.files`, and get the commit onto the
   server's copy of this repository.
5. `scripts/upgrade.sh --plan` now lists the model; `scripts/upgrade.sh` verifies
   it in full, restarts the listed units and records it.

- Check at any time: `scripts/verify-models.sh` (sizes; seconds) or `--full`
  (re-hashes the weights; minutes). `health.sh` runs the quick one.
- `UNMEASURED` in the manifest means only the directory's existence is checked.
- If the model is used by new code, the code's pin and the model go in the same
  commit, so one upgrade brings both.

## 5c. Adding a conda environment

1. Put its environment file in `envs/<name>.yml` (export it from a working
   environment and prove it rebuilds before committing).
2. Add one line to `environments.map`: short name, conda environment name (or
   `$VS_SOMETHING` with that variable added to `deploy.env`), `envs/<name>.yml`,
   and the units that load it (`-` if it is only run as a separate program).
3. For each component installed into it, set that component's `deps` in
   `components.map` to `pip-e:<name>`.
4. `scripts/upgrade.sh --plan` shows `env:<name>` being created before the
   components that need it. No script is edited.

- Changing an environment later = editing its file and committing; the next
  upgrade rebuilds it and restarts its units.
- An environment whose file lives inside a component (`src:…`, like
  `avrp-auto-seg`) is rebuilt when that component's pin moves.
- *(Creating and updating real conda environments from here has not been run yet.)*

## 5d. Adding a worker module

A module needs three things, in this order:

1. **Code:** the module is in the worker's registry
   (`avrp-handler/src/modules/create_module_worker.py`) at the pinned SHA.
2. **Database:** the gateway's `module` table has a row for it — it arrives with a
   gateway **migration** (not an edit to `seed.sql`; see 5a).
3. **Configuration:** only then add its name to `VS_MODULE_LIST` in `deploy.env`,
   `config/render.sh --install`, restart the worker.

`scripts/check-modules.sh` verifies 1 and 2 for every name in the list. It runs in
`health.sh` and before the worker starts in every upgrade.

| Message | Meaning | What to do |
|---|---|---|
| *…but the worker SOURCE has no such module* | the pinned `avrp-handler` does not have it (or the name is misspelt) | move the handler pin, or fix the name |
| *…but the gateway DATABASE has no row for it* | the gateway pin is too old, or `db-init.sh` has not run | upgrade the gateway first |
| *VS_MODULE_LIST is empty* / *more than once* | the list itself is wrong | fix `deploy.env` |

If the module needs its own model or environment, do 5b / 5c in the same change.

## 6. Backup and restore
- **Works today:** `scripts/backup.sh --db-only` dumps both databases to
  `$VS_BACKUP_DIR/db/<timestamp>/` (restore with `pg_restore`).
- *(To write with the full backup:)* the blob root, `deploy.env`, `versions.lock`,
  `deployed.lock`; schedule, retention, where on the NAS; the restore procedure and
  the date of the last restore rehearsal.

## 7. User accounts

Accounts live in the gateway's database. `install/accounts.sh` adds the ones that
are missing and never touches one that exists.

- **A new person:** add a line with their username to `config/accounts.txt` (not
  in git, mode 600), run `install/accounts.sh`. It generates an initial password,
  writes it next to the name in that file, and creates the account (role `user`).
  Hand the password over in person. `username password` on the line sets your own.
- **Who has an account:** `install/accounts.sh --list`.
- **The worker's account** is `VS_WORKER_USER` in `deploy.env` (role `application`).
  It is not a person's login.
- People see only the cases they created themselves.
- *(Not built: changing or resetting a password, removing an account. The gateway
  has no endpoint for either; today that is an SQL statement by the operator.)*
- **Known gap:** the gateway's `POST /user` creates an account for anyone who can
  reach `/api` — there is no sign-up approval. On the lab LAN that means anyone on
  the LAN. To fix upstream in `avrp-gateway`.

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
