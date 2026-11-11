# valvescope-deploy

Everything needed to **run** ValveScope on a server. The services are developed
elsewhere (the `avrp-developer` wrapper and the `avrp-*` repositories); this
repository holds no service code. It holds one known-good set of versions and the
glue to install and operate them.

> **Status (2026-11-11): rehearsed on the lab box, not yet installed there.**
> On Ludwig (Ubuntu 24.04, RTX 2080) the whole install path except the root
> steps ran in an unprivileged staging tree: both conda environments built from
> their files, FireANTs compiled, databases initialised, a study went through all
> seven modules and rendered in the web viewer behind the proxy. The real install
> (dedicated user, `/opt`, `/srv`, systemd, firewall) has **not** run: it needs
> sudo. One upstream fix it depends on is not pushed. See [Status](#status).

## The contract

From a bare Ubuntu host that meets the prerequisites below, this repository takes
you through five things, each with one documented command:

| Step | Command | Result |
|---|---|---|
| **Install** | `install/install.sh` | All services running; a study can be submitted, processed and viewed |
| **Upgrade** | `scripts/upgrade.sh` | Only the components whose pin changed are rebuilt and restarted; data kept |
| **Rollback** | `scripts/rollback.sh` | The previous `versions.lock` is running again |
| **Backup** | `scripts/backup.sh` | Both databases and the blob store copied to the lab NAS |
| **Health** | `scripts/health.sh` | Exit 0 only if every service, database, disk and the GPU check out |

No developer wrapper is needed on the host, and nothing is configured by hand
outside `config/deploy.env`.

## What gets deployed

```
            browser / iPad
                  │  http://VS_HOST            (the only port open on the LAN)
                  ▼
        ┌───────────────────┐
        │ reverse proxy     │  /         → manager   (Next.js)
        │ (Caddy)           │  /viewer/  → web viewer (static files)
        │                   │  /api/     → gateway
        └─────────┬─────────┘
                  ▼ loopback only
   gateway (Node) ── Postgres: two databases (main + blob metadata)
        ▲          └─ blob store on local disk
        │ loopback
   worker (avrp-handler, Python, GPU) ── calls the auto-segmentation tool
                                         in a second conda environment
```

Each box is a systemd unit (`valvescope-gateway`, `-handler`, `-manager`,
`-viewer`, `-proxy`), grouped under `valvescope.target`. There is no Docker.

## Host prerequisites

`install.sh --check` checks for these; it does not install them.

| Need | Version | Why |
|---|---|---|
| Ubuntu | 24.04 | the tested host |
| NVIDIA driver + GPU | working `nvidia-smi`, ≥ 8 GB VRAM | registration and both AI modules have no CPU fallback |
| gcc-12, g++-12 | — | the worker's CUDA extension is compiled on the server; CUDA 12 rejects Ubuntu 24.04's default gcc 13 |
| Node.js | ≥ 20 | gateway, manager, viewer build |
| PostgreSQL | 16 | two databases on one cluster, loopback only |
| Caddy | 2.x (`apt install caddy`, then `systemctl disable --now caddy.service`) | reverse proxy and static file server. Ubuntu's package starts its own service on port 80; it must be off |
| git, openssl, curl | — | fetching sources, generating secrets, health checks |
| sudo | for the installing person | creating the Unix user, running steps as it, installing systemd units |
| a stored git credential | for the installing person | most pinned repositories are private; the credential is handed to each fetch, never stored for the deploy user |

Miniconda is **not** a prerequisite: `install.sh` installs a private one at
`$VS_CONDA_ROOT` (pinned installer, checksum verified) for the two environments —
the worker's (Python 3.10, torch, VTK, FireANTs) and auto-segmentation's
(Python 3.9, nnU-Net).

Also needed, but not software: the nnU-Net **model weights** copied to the box
and a mount of the lab NAS for backups (Ludwig has none today; see Status).
On the lab network `VS_CA_BUNDLE` must point at the system CA store: the
firewall re-signs TLS for `download.pytorch.org`.

## Coexistence with the developer checkout

The target host is also the development box. The deployment must never share
state with the developer's checkout there. The rule: **nothing in
`config/deploy.env` may equal a value the dev checkout uses.**

| | Developer checkout | Deployment (defaults) |
|---|---|---|
| Unix user | the developer | `valvescope` |
| Ports | 3000, 8000, 5173 | 80 public; 3100, 8100, 5273 on loopback |
| Databases | `avrpdb`, `avrpdsdb` | `vsdb`, `vsdsdb` (same Postgres cluster is fine) |
| Blob store | the developer's data dir | `/srv/valvescope/data` |
| Worker scratch | the checkout's `work/` | `/srv/valvescope/work` |
| conda | the developer's miniconda | `/opt/valvescope/miniconda3` |
| Sources | `~/dev/avrp-developer` | `/opt/valvescope/src`, fetched from `versions.lock` |

The gateway listens on every interface, so its unit confines it to loopback
traffic (`IPAddressAllow=localhost`); `health.sh` fails if it answers on the LAN.

`config/render.sh` enforces the parts it can see: it refuses the dev ports, the
dev database names, `localhost` as the public host, and paths inside a developer
checkout. Never run the dev reset scripts (`rebuild-dev.sh`, `npm run reset-db`)
against the deployment's databases.

## Two rules the scripts are built around

**R1 — deploying never wipes data.** Install and upgrade are safe to run against a
server that already holds studies, and safe to run twice.

- `install/db-init.sh` creates the role and each database only if missing. It
  applies the schema and seed data only to a database with no tables. On a
  database that has data it applies only forward migrations it has not recorded
  yet, plus the functions (code, not data) when they changed. `--plan` shows what
  it would do without doing it.
- It keeps a small table, `vs_schema_migrations`, in each database: what the
  database was created from and which migrations it has had.
- It stops, changing nothing, when something looks unsafe: a database it did not
  create, a pending migration that removes whole tables, a schema or seed file
  edited in place upstream, or the developer checkout's database names.
- Nothing in `install/`, `scripts/` or `config/` drops, truncates, re-seeds or
  clears a directory, and nothing calls the gateway's reset scripts or
  `rebuild-dev.sh`. The blob root is never written to by this repository.
- Anything that removes data is a separate script named `scripts/destroy-*.sh`.
  Such a script does nothing without a `--yes-destroy-…` flag naming the exact
  thing, and prints what it will remove first. Today there is one,
  `destroy-databases.sh`. `tests/run.sh` fails if a destructive command appears
  in any other script.

**R2 — one component can be upgraded alone.**

- `components.map` says, per component, what a change needs: the dependency step,
  whether a build is needed, whether the database step runs, and which systemd
  units restart. The edges were read from the code. Example: `segflow4d` is
  imported inside the worker, so a new `segflow4d` means one `pip install -e`
  into the worker's conda environment and a restart of the worker only.
- The server records what is really installed in `$VS_STATE_DIR/deployed.lock`.
  A component is written there only after all its steps succeeded.
- `scripts/upgrade.sh` compares that file with `versions.lock` and acts only on
  the difference. `--plan` prints the exact ordered actions and changes nothing;
  `--only a,b` restricts it; with no difference it says so and exits 0.

```
$ scripts/upgrade.sh --plan          # after changing only the segflow4d line
segflow4d
   1. stop      stop unit valvescope-handler
   2. fetch     fetch segflow4d at <new sha> (was <old sha>)
   3. deps      pip install -e /opt/valvescope/src/segflow4d into conda env segflow4d
   4. check-modules  every module in VS_MODULE_LIST exists in the worker source and the database
   5. start     start unit valvescope-handler
   6. record    record segflow4d = <new sha> in deployed.lock
```

## Ready for new models, environments and modules

Three more things change over a deployment's life besides code. Each is a table
in this repository, so adding one is a line of data, not a script edit.

**Model weights — `models.manifest`.** Weights are not in git and there is no
artifact store; a person copies them to the server. The manifest says which
models, which version, and how to tell the right bytes are there.

- Each measured model has a file list, `models/<name>.files`: every file with its
  size, plus a sha256 for the weights and configuration files (`*.pth`, `*.json`,
  `*.pkl` and similar). The manifest's checksum is the sha256 of that list.
- `scripts/verify-models.sh` checks **presence and size** of every file. It reads
  no contents, so `health.sh` runs it every time. `--full` also re-hashes the
  weights (minutes). The quick check cannot see a weight file replaced by another
  of exactly the same size; the full one can.
- `scripts/model-manifest.sh --name <name> --write` measures a model on the server.
- A changed version or checksum is an upgrade. The plan names the model, says it
  must be put in place **by hand**, verifies it in full, restarts the units in the
  manifest's last column, and records it in `deployed.models`. If the files are not
  right it stops before restarting anything.
- The three known models were measured on Ludwig on 2026-11-11. They carry no
  upstream version label, so their version is the capture date. A new model starts
  as `UNMEASURED` (only its directory is checked) until it is measured on the server.

**Conda environments — `environments.map`.** Name, real conda environment (or the
`deploy.env` variable holding it), the file it is built from, and the units that
load it. `components.map` refers to environments by name (`pip-e:<name>`), so a
third environment is one line plus its file. An environment file kept in this
repository (`envs/`) is tracked by checksum in `deployed.envs`; when it changes the
plan rebuilds that environment and restarts its units.

**Worker modules — the `VS_MODULE_LIST` guard.** A module must exist in the
worker's registry at the pinned source *and* as a row in the gateway's `module`
table before the worker may be told to run it. `scripts/check-modules.sh` checks
both, and refuses an empty list or a duplicate. It runs in `health.sh`, in
`config/render.sh` (list only) and in every upgrade just before the worker starts.
A failure names the module and the side that lacks it.

## Layout

```
versions.lock            the pinned commit of every component (repo, tag, SHA, path)
components.map           per component: dependency step, build, database step, units to restart
environments.map         per conda environment: real name, file it is built from, units that load it
models.manifest          per model: where it lives, version, checksum, units to restart
models/                  one file list per measured model (sizes + weight hashes)
envs/                    handler.yml (the worker's environment) and the raw captures it was built from
config/
  deploy.env.example     copy to deploy.env — the single source of host, ports,
                         database names, paths and secrets
  render.sh              generates every service .env, the systemd units and the
                         proxy config from deploy.env into rendered/
  templates/             one .env template per service
install/
  install.sh             host → running system, 11 steps, safe to re-run
  fetch-sources.sh       checks out exactly the SHAs in versions.lock
  gen-secrets.sh         fills the CHANGE_ME secrets in deploy.env
  db-init.sh             role + both databases; create-if-missing, forward-only
  build-fireants.sh      FireANTs + its compiled CUDA extension into the worker env
  accounts.sh            the worker's gateway account and one per person
services/                systemd unit templates, valvescope.target, Caddyfile template
scripts/
  upgrade.sh             deployed vs wanted → plan → execute, per component, environment, model
  model-manifest.sh      measure a model directory on the server
  verify-models.sh       are the weights on disk the listed ones (quick, or --full)
  check-modules.sh       is every module in VS_MODULE_LIST runnable here
  start · stop · health · backup · rollback
  destroy-databases.sh   the only script that removes data; needs an explicit flag
tests/run.sh             laptop tests: upgrade plans, db-init plans, a real db-init
                         run against a throwaway Postgres, the destructive-command lint,
                         a fictional third environment, a fake model, the module guard
docs/
  RUNBOOK.md             for whoever operates the server
  TEAM_README.md         for the people who use ValveScope
```

Generated files go to `rendered/` and into the fetched sources. Both are outside
git; so are `config/deploy.env` and the server's `deployed.lock`.

## How the pieces fit

**Two people's worth of permissions.** The operator (a person with sudo) owns this
repository and `config/deploy.env`. The deploy user (`$VS_USER`) owns what the
services use — sources, conda, builds, data — and never reads `deploy.env`; it
receives only the rendered files. Scripts are run by the operator and switch to
the deploy user for the steps that touch its files (`vs_as_user` in
`scripts/lib.sh`). So the repository must sit where the deploy user can read it:
`$VS_HOME/valvescope-deploy`, not a home directory.

**One configuration file.** `config/deploy.env` is the only file edited on the
server. `config/render.sh` reads it and writes each service's configuration in the
shape that service expects. Change a port in one place, re-render, restart.
Two of the services (manager, viewer) bake their configuration into the built
bundle, so they are rebuilt after a change, not just restarted.

**Pinned sources.** `versions.lock` names one commit per component.
`install/fetch-sources.sh` checks out exactly those commits and refuses to touch a
checkout that has local edits. The order of the lines is the install order:
what a service imports comes before the service. Two components (`avrp-auto-seg`, `avrp-ipad`) live
inside the developer wrapper rather than in their own repositories, so they are
pinned as *wrapper commit + path* and fetched as a sparse checkout. `avrp-ipad`
is a client app that is not hosted; it is pinned for the record (role `client`)
and only fetched with `--all`.

**No source patches here.** If a service needs a change to be deployable, the
change goes into that service's repository and the pin moves. This repository
only ever configures.

**Pinned environments.** `envs/handler.yml` gives every package an exact version.
Components are installed into it with `pip install --no-deps` followed by
`pip check`, so a component can neither pull in a newer dependency nor silently
miss one. See `envs/README.md` for how the file was captured and proven.

**Secrets.** Generated on the server by `install/gen-secrets.sh`, stored only in
`config/deploy.env` (mode 600), never committed.

## Trying the parts that work today

```bash
tests/run.sh                           # everything below, checked automatically
cp config/deploy.env.example config/deploy.env
install/gen-secrets.sh
config/render.sh                       # writes rendered/
install/fetch-sources.sh --dest /tmp/vs-src
scripts/upgrade.sh --plan              # no deployed.lock yet: prints the install order
install/db-init.sh --plan --gateway-dir /tmp/vs-src/avrp-gateway   # asks Postgres; changes nothing
```

## Status

Three levels, used exactly:

- **tested** — `tests/run.sh` passes (144 checks on Ludwig, 2026-11-11, Ubuntu
  24.04; the database part against a throwaway PostgreSQL 16.15).
- **rehearsed on Ludwig** — ran for real on the lab box on 2026-11-11, but as the
  developer's account in `~/vs-staging`: a private Miniconda, a throwaway
  PostgreSQL 16 on its own port, ports 8180/3190/8190/5290, services started by
  hand. No sudo, no dedicated user, no systemd, no port 80.
- **not run** — written only.

| Piece | State |
|---|---|
| `versions.lock`, `install/fetch-sources.sh` | tested; rehearsed (all 9 host components fetched at their pins). **Not run:** the credential hand-over to a different user (`--credential-stdin`) |
| `config/render.sh`, templates, `install/gen-secrets.sh` | tested; rehearsed (`--install` twice: second run leaves every file alone). **Not run:** installing files as another user through sudo |
| `scripts/upgrade.sh --plan`, `--only` | tested |
| `scripts/upgrade.sh` executor | **rehearsed**: a first install of all 13 items ran start to finish; a second run said "nothing to do". **Not run:** its `sudo -u` and `systemctl` paths, and a real upgrade of one component on a live install |
| `install/db-init.sh` | tested; rehearsed (role, both databases, 7 migrations, functions; second run: nothing to do) |
| `envs/handler.yml` | **captured and proven on Ludwig**: rebuilt from the file in a separate Miniconda; conda packages identical to the developer environment by name, version and build; pip packages identical plus the listed additions |
| `install/build-fireants.sh` | rehearsed: compiled with gcc-12 against the rebuilt environment, twice (by hand, then by `upgrade.sh`) |
| auto-segmentation environment (`src:avrp-auto-seg/environment.yml`) | rehearsed: built from the pinned file; torch 2.7.0+cu126 sees the GPU; ran TEE inference inside the pipeline |
| `models.manifest` | the three real models are **measured** (23 files, all hashed) from the developer's copies and passed a full verify there. **Not done:** the deployment's own copy under `/srv/valvescope/models` |
| `scripts/check-modules.sh` | tested; rehearsed against the real worker source and a real database, all 7 modules |
| `install/accounts.sh` | rehearsed: worker + two people created, second run changes nothing, all log in |
| Proxy (`services/Caddyfile.tmpl`) | rehearsed with Ubuntu's caddy 2.6.2 on port 8180: `/` manager, `/viewer/` viewer, `/api/` gateway. **Not run:** on port 80 as the deploy user |
| End to end | **rehearsed**: tav006 (TEE, 12 time points) staged through the proxy as a person's account; all 7 modules reached `completed`; the manager's "Open Viewer" opened `/viewer/`; the study rendered with measurements and no console errors (headless Chrome). **Needed the unpinned gateway fix below** |
| `scripts/health.sh` | rehearsed: every check passed except the five systemd-unit checks, which cannot pass without the units. The loopback-confinement check is **not run** |
| `install/install.sh` | step 1 (`--check`) run on Ludwig — it stops on the one missing prerequisite, caddy. **Steps 2–11 not run** (they need sudo) |
| systemd units | **not run.** Rendered only |
| `scripts/start.sh`, `stop.sh` | **not run** |
| `scripts/backup.sh --db-only` | tested; rehearsed once as part of the gateway step (no databases yet, so it skipped). Full backup: stub |
| `scripts/rollback.sh` | stub |
| `scripts/destroy-databases.sh` and the destructive-command lint | tested |
| Firewall | **not looked at**: `ufw` is active on Ludwig and its rules need sudo to read |
| Reboot survival | **not verified** |
| Backups | `VS_BACKUP_DIR` on Ludwig is `/srv/valvescope/backup`, the **same disk as the data** — there is no NAS mount on the box. Protects against a bad migration, not a lost disk |

### What the first install on Ludwig still needs

1. sudo for the installing account (the install was prepared without it).
2. `sudo apt install caddy && sudo systemctl disable --now caddy.service`.
3. The gateway fix for worker access (next table, row 9) pushed and pinned —
   without it no study submitted by a person can be processed.
4. The three model directories copied to `/srv/valvescope/models` (9.0 GB).
5. The names for the per-person accounts.

### Upstream state for R1 (never wipe data)

`db-init.sh` is safe because it refuses rather than guesses. The gaps it had to
work around in `avrp-gateway`, and where each stands (2026-11-10):

| # | Gap | State |
|---|---|---|
| 1 | Schema and seed data edited in place, with no migration. Two cases existed: `20f2e3e` (two modules added to `seed.sql`) and `65197bd` (a column widened in `schemas.sql`). | **Fixed and pinned** (`8f6bac8`, branch `fix/forward-only-migrations`, not yet on `main`): migrations 006 and 007, a written rule (`sql/migrations/README.md`) and `scripts/check-migrations.sh`. |
| 2 | The blob-metadata database had no migrations directory. | **Fixed and pinned** (same commit; the directory is empty today). `db-init.sh` handles it; tested with a real blob migration. |
| 3 | Migrations carry their own `begin`/`commit`, so a migration and the record that it ran are not one transaction. | Open. Safe while every migration is idempotent, which the upstream rule now requires. |
| 4 | No migration tracking upstream; the tracking table here is ours, so a database made by the gateway's own scripts needs `--adopt`. | Open, by design. |
| 5 | Functions. | Fine: all files are `create or replace`; signature changes drop the old function in a migration. |
| 6 | The blob-metadata seed inserts two fixed login tokens. | Open: needs an upstream answer on whether they are still used. |
| 7 | `sql/create_user.sql` grants to a hard-coded `avrpdev`. | Not used here. |
| 8 | `reset-db.sh` and friends drop the database. | Never called from here; the lint forbids it. |

### Other upstream problems found on Ludwig (2026-11-11)

Fixes belong in the service repositories; nothing here patches source.

| # | Where | Problem | State |
|---|---|---|---|
| 9 | `avrp-gateway` | **A worker with its own account cannot process other people's studies.** `fn_verify_study_ownership` only accepts a user connected to the study's case, so the worker gets `403` on every `/data` download and `/study-data` upload. Seen live: phase detection failed with `HTTP 403` on a study staged by a person's account. A dev box hides it (one account does both). | **Fix written, not pushed**: branch `fix/service-account-study-access` (`da83170`, on top of `8f6bac8`): role `application` passes for any existing study. Function only, no migration. Proven against a throwaway PostgreSQL 16 and, applied by hand to the rehearsal database, let the whole pipeline complete. **The pin must move to it before the install.** |
| 10 | `avrp-gateway` | `app.listen(port)` binds every interface; there is no host setting. | Open. Contained here by the unit's `IPAddressAllow=localhost`. |
| 11 | `avrp-gateway` | `POST /user` creates an account without authentication: anyone who can reach `/api` can register. | Open. Needs a decision upstream (the manager has a registration page that uses it). |
| 12 | `avrp-gateway` | `routes/login.js` loads `.env.local`, not `.env`, and reads `SECRET_KEY` at import. It works only because `routes/user.js` is imported first and loads `.env`. | Open. Fragile, not broken. |
| 13 | `avrp-handler` | The worker prints the full login response, token included, to its log (the journal on a server). | Open. |
| 14 | `avrp-handler` | `setup.py` declares `ipython` and `watchdog`; nothing pins them and the developer environment never had them. | Pinned in `envs/handler.yml`. Upstream should drop or pin them. |
| 15 | `avrp-view-service` | The login page has a "Demo Login" button with the developer account's password hard-coded. It fails with 401 on a deployment, but it is the first button on the page. It also lower-cases usernames. | Open. `accounts.sh` only allows lower-case names. |
| 16 | `avrp-gateway`, `avrp-handler`, `avrp-auto-seg` | Defaults in code point into the developer's home directory (`/home/jileihao/...` model paths, the auto-seg CLI path, `avrpdev` credentials). | All overridden by the rendered `.env`; harmless while every key is rendered. |

Not reproduced: the gateway's undeclared `node-fetch` / `form-data` imports. At
`8f6bac8` only `tests/test_study-config.js` imports `node-fetch`; `npm ci` plus
`node app.js` ran the whole rehearsal without either.

Other open design points:

1. **Proxy paths** (`/api`, `/viewer/`). **Pinned and rehearsed** (`611ecd2`,
   `337b434`): both builds succeed on Ludwig and the Caddyfile serves all three
   behind one origin.
2. **Gateway deploy fixes** (a `start` script, blob-store settings validated at
   boot) are still open upstream. `health.sh` now catches the blob-store case.
3. **Release tags.** No pinned commit is tagged, and four pins sit on unmerged
   branches (`avrp-handler`, `avrp-gateway`, `avrp-manager`, `avrp-view-service`).
4. **The auto-segmentation environment is not fully pinned.** Its
   `environment.yml` pins the main packages but not their dependencies, and
   `conda env update` resolves them again at each install. It built and ran on
   2026-11-11; a later install may get different versions. `envs/handler.yml`
   does not have this problem.
5. **Components pinned by wrapper commit** (`avrp-auto-seg`) show as changed
   whenever the wrapper SHA moves, even if their own files did not.
6. **Top-level `automatic_measurement`** in the lock is loaded by nothing; the
   worker uses its own nested copy. It can probably leave the lock.
7. **A stable hostname** for the box instead of its DHCP address.
8. **Licence** for this repository — not chosen yet.
