# valvescope-deploy

Everything needed to **run** ValveScope on a server. The services are developed
elsewhere (the `avrp-developer` wrapper and the `avrp-*` repositories); this
repository holds no service code. It holds one known-good set of versions and the
glue to install and operate them.

> **Status (2026-11-10): skeleton plus the two operating rules.** Fetching pinned
> sources, rendering configuration, planning an upgrade and initialising the
> databases work and are tested on a laptop (`tests/run.sh`). Nothing has run on the
> server yet. `install.sh`, the full backup and `rollback.sh` are still stubs.
> See [Status](#status) for the exact line.

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

`install.sh` checks for these; it does not install them.

| Need | Version | Why |
|---|---|---|
| Ubuntu | 24.04 | the tested host |
| NVIDIA driver + GPU | working `nvidia-smi`, ≥ 8 GB VRAM | registration and both AI modules have no CPU fallback |
| miniconda | any recent | two environments: the worker's (Python 3.10, torch, VTK, FireANTs) and auto-segmentation's (Python 3.9, nnU-Net) |
| Node.js | ≥ 20 | gateway, manager, viewer build |
| PostgreSQL | 16 | two databases on one cluster, loopback only |
| Caddy | 2.x (`apt install caddy`) | reverse proxy and static file server |
| git, openssl, curl | — | fetching sources, generating secrets, health checks |
| sudo | for the installing person | creating the Unix user and installing systemd units |

Also needed, but not software: the nnU-Net **model weights** copied to the box,
read access to the private GitHub repositories named in `versions.lock`, and a
mount of the lab NAS for backups.

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
- The three known models are listed as `UNMEASURED` placeholders: the checksums can
  only be taken on the lab box.

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
envs/                    environment files owned by the deployment (none yet)
config/
  deploy.env.example     copy to deploy.env — the single source of host, ports,
                         database names, paths and secrets
  render.sh              generates every service .env, the systemd units and the
                         proxy config from deploy.env into rendered/
  templates/             one .env template per service
install/
  install.sh             bare host → running system            (stub)
  fetch-sources.sh       checks out exactly the SHAs in versions.lock
  gen-secrets.sh         fills the CHANGE_ME secrets in deploy.env
  db-init.sh             role + both databases; create-if-missing, forward-only
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

**One configuration file.** `config/deploy.env` is the only file edited on the
server. `config/render.sh` reads it and writes each service's configuration in the
shape that service expects. Change a port in one place, re-render, restart.
Two of the services (manager, viewer) bake their configuration into the built
bundle, so they are rebuilt after a change, not just restarted.

**Pinned sources.** `versions.lock` names one commit per component.
`install/fetch-sources.sh` checks out exactly those commits and refuses to touch a
checkout that has local edits. Two components (`avrp-auto-seg`, `avrp-ipad`) live
inside the developer wrapper rather than in their own repositories, so they are
pinned as *wrapper commit + path* and fetched as a sparse checkout. `avrp-ipad`
is a client app that is not hosted; it is pinned for the record (role `client`)
and only fetched with `--all`.

**No source patches here.** If a service needs a change to be deployable, the
change goes into that service's repository and the pin moves. This repository
only ever configures.

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

"Tested" means `tests/run.sh` passes on a Mac (126 checks, 2026-11-10; the database
part ran against a throwaway PostgreSQL 18 cluster — the server has 16).

| Piece | State |
|---|---|
| `versions.lock`, `install/fetch-sources.sh` | working, tested |
| `config/render.sh`, templates, `install/gen-secrets.sh` | working, tested by hand |
| `components.map`, `scripts/upgrade.sh --plan`, `--only` | working, tested |
| `scripts/upgrade.sh` executor | **written, never run** — it needs systemd, conda and the installed sources |
| `install/db-init.sh` (plan and real) | working, tested: second run changes nothing and keeps inserted rows |
| `environments.map` and environment steps in the plan | plan tested (a fictional third environment needs no script change); creating or updating a real conda environment is **written, never run** |
| `envs/handler.yml` (the worker's environment file) | **missing** — to be exported from the lab box; until then that environment is not managed |
| `models.manifest`, `model-manifest.sh`, `verify-models.sh`, model steps in the plan | working, tested on a small fake model |
| The three real models | **UNMEASURED placeholders** — checksums can only be taken on the lab box |
| `scripts/check-modules.sh` | working, tested: source side against the pinned `avrp-handler`, database side against the throwaway Postgres |
| `scripts/backup.sh --db-only` | working, tested |
| `scripts/destroy-databases.sh` and the destructive-command lint | working, tested |
| systemd units, Caddyfile | written, **not yet run on the host** |
| `scripts/start.sh`, `stop.sh` | thin wrappers over systemd, untested on the host |
| `scripts/health.sh` | partial: unit, port, disk, GPU, model (quick) and module checks; DB and login checks to do. Never run as a whole |
| `install/install.sh`, full `backup.sh`, `rollback.sh` | stubs with their step lists |

### Upstream state for R1 (never wipe data)

`db-init.sh` is safe because it refuses rather than guesses. The gaps it had to
work around in `avrp-gateway`, and where each stands (2026-11-10):

| # | Gap | State |
|---|---|---|
| 1 | Schema and seed data edited in place, with no migration. Two cases existed: `20f2e3e` (two modules added to `seed.sql`) and `65197bd` (a column widened in `schemas.sql`). | **Fixed upstream, not yet pinned** — branch `fix/forward-only-migrations` (`8f6bac8`) adds migrations 006 and 007, a written rule (`sql/migrations/README.md`) and `scripts/check-migrations.sh`. Verified: a pre-change database migrated forward equals a fresh one in schema, reference rows and row counts. |
| 2 | The blob-metadata database had no migrations directory. | **Fixed on the same branch** — `data/db_adapters/sql/migrations/` exists (empty; the schema has not changed since the merge) and the check script covers it. `db-init.sh` does not read it yet: **to do** when the pin moves. |
| 3 | Migrations carry their own `begin`/`commit`, so a migration and the record that it ran are not one transaction. | Open. Safe while every migration is idempotent, which the upstream rule now requires. |
| 4 | No migration tracking upstream; the tracking table here is ours, so a database made by the gateway's own scripts needs `--adopt`. | Open, by design. |
| 5 | Functions. | Fine: all files are `create or replace`; signature changes drop the old function in a migration. |
| 6 | The blob-metadata seed inserts two fixed login tokens. | Open: needs an upstream answer on whether they are still used. |
| 7 | `sql/create_user.sql` grants to a hard-coded `avrpdev`. | Not used here. |
| 8 | `reset-db.sh` and friends drop the database. | Never called from here; the lint forbids it. |

Until `versions.lock` pins a gateway commit that contains `8f6bac8`, an existing
database would stop at the baseline check on its first upgrade (gap 1). A first
install is unaffected.

Other open design points:

1. **Proxy paths** (`/api`, `/viewer/`). **Fixed upstream, not yet pinned.** The
   viewer takes a gateway address with a path and a base path
   (`avrp-view-service` branch `feature/gateway-url-and-base-path`, `611ecd2`;
   browser-verified behind a one-origin test server). The manager's "Open Viewer"
   link is configurable and its production build works for the first time
   (`avrp-manager` branch `fix/viewer-url-configurable`, `337b434`) — before
   that commit `next build` fails, so the manager cannot be installed from the
   current pin. The templates here already emit the new settings; the Caddyfile
   has not been run yet.
2. **Gateway deploy fixes** (a `start` script, undeclared `node-fetch` /
   `form-data`, blob-store settings validated at boot) land in `avrp-gateway`
   and then the pin moves.
3. **Release tags.** No pinned commit is tagged yet, and the `avrp-handler` pin
   sits on a feature branch rather than `main`.
4. **Reproducible conda environments** exported from the working box. Until then
   the `deps` steps for the worker assume the environments already exist.
5. **Components pinned by wrapper commit** (`avrp-auto-seg`) show as changed
   whenever the wrapper SHA moves, even if their own files did not.
6. **Top-level `automatic_measurement`** in the lock is loaded by nothing; the
   worker uses its own nested copy. It can probably leave the lock.
7. **A stable hostname** for the box instead of its DHCP address.
8. **Licence** for this repository — not chosen yet.
