# valvescope-deploy

Everything needed to **run** ValveScope on a server. The services are developed
elsewhere (the `avrp-developer` wrapper and the `avrp-*` repositories); this
repository holds no service code. It holds one known-good set of versions and the
glue to install and operate them.

> **Status: skeleton (2026-11-10).** The layout, the configuration generator,
> `versions.lock` and `install/fetch-sources.sh` work. `install.sh`, `backup.sh`,
> `upgrade.sh` and `rollback.sh` are stubs that describe their steps and exit 3.
> See [Status](#status) for the exact line.

## The contract

From a bare Ubuntu host that meets the prerequisites below, this repository takes
you through five things, each with one documented command:

| Step | Command | Result |
|---|---|---|
| **Install** | `install/install.sh` | All services running; a study can be submitted, processed and viewed |
| **Upgrade** | `scripts/upgrade.sh` | The versions in a new `versions.lock` are running; data kept |
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

## Layout

```
versions.lock            the pinned commit of every component (repo, tag, SHA, path)
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
services/                systemd unit templates, valvescope.target, Caddyfile template
scripts/                 start · stop · health · backup · upgrade · rollback
docs/
  RUNBOOK.md             for whoever operates the server
  TEAM_README.md         for the people who use ValveScope
```

Generated files go to `rendered/` and into the fetched sources. Both are outside
git; so is `config/deploy.env`.

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
cp config/deploy.env.example config/deploy.env
install/gen-secrets.sh
config/render.sh                       # writes rendered/
install/fetch-sources.sh --dest /tmp/vs-src
```

## Status

| Piece | State |
|---|---|
| `versions.lock`, `install/fetch-sources.sh` | working |
| `config/render.sh`, templates, `install/gen-secrets.sh` | working |
| systemd units, Caddyfile | written, **not yet run on the host** |
| `scripts/start.sh`, `stop.sh` | thin wrappers over systemd, untested on the host |
| `scripts/health.sh` | partial: unit, port, disk and GPU checks; DB and login checks to do |
| `install/install.sh`, `backup.sh`, `upgrade.sh`, `rollback.sh` | stubs with their step lists |

Open design points, to settle in later work:

1. **Proxy paths.** `/api` and `/viewer` are a proposal. The web viewer builds
   its gateway address as `http://HOST:PORT` with no path, and has no base path,
   so it needs an upstream change before it works behind this layout.
2. **Gateway deploy fixes** (a `start` script, undeclared `node-fetch` /
   `form-data`, blob-store settings validated at boot) land in `avrp-gateway`
   and then the pin moves.
3. **Release tags.** No pinned commit is tagged yet, and the `avrp-handler` pin
   sits on a feature branch rather than `main`.
4. **Reproducible conda environments** exported from the working box.
5. **A stable hostname** for the box instead of its DHCP address.
6. **Licence** for this repository — not chosen yet.
