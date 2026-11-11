#!/usr/bin/env bash
# install.sh — Ubuntu 24.04 host -> running ValveScope. Safe to run again: every
# step first looks at what is there and changes only what is missing or different.
# On a finished install it changes nothing and keeps all data.
#
#   install/install.sh                  run every step
#   install/install.sh --check          step 1 only (prerequisites and configuration)
#   install/install.sh --from N         start at step N (after fixing what stopped it)
#   install/install.sh --apply-firewall also apply the firewall rule of step 10
#                                       (without it the rule is only printed)
#
# Run it as a person with sudo, from this repository, which must sit where the
# deploy user can read it (the usual place is $VS_HOME/valvescope-deploy).
# Before the first run: cp config/deploy.env.example config/deploy.env and edit it.
#
# Who owns what. The operator (you) owns this repository and config/deploy.env, the
# only place secrets live. $VS_USER owns everything the services use: sources,
# conda, builds, data, work files. Steps that touch those run as $VS_USER through
# sudo; nothing runs as root except creating the user and directories, installing
# the systemd units and the firewall rule.
#
# Steps
#    1  prerequisites and configuration   checks only; installs nothing. Refuses the
#                                         developer checkout's ports and database names.
#    2  Unix user and directories         $VS_USER; home, sources, state, data root,
#                                         work dir, upload cache, backup dir
#    3  secrets                           install/gen-secrets.sh
#    4  miniconda                         a private install at $VS_CONDA_ROOT
#    5  systemd units                     rendered, installed, enabled — not started
#    6  model weights                     checks they are in place (a person copies them)
#    7  gateway and databases             fetch, npm ci, config, install/db-init.sh
#    8  accounts                          the worker's and config/accounts.txt
#    9  everything else                   conda envs, FireANTs, segflow4d, auto-seg,
#                                         worker, manager and viewer builds, models
#   10  firewall                          prints the rule; applies it only on request
#   11  start and health                  valvescope.target, scripts/health.sh
#
# Steps 7 and 9 are scripts/upgrade.sh: a first install is an upgrade from nothing,
# so the same code path is used on day one and for every later change.
set -euo pipefail

FROM=1; CHECK_ONLY=0; APPLY_FW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --from) FROM="$2"; shift 2 ;;
    --apply-firewall) APPLY_FW=1; shift ;;
    -h|--help) sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$FROM" in [1-9]|1[01]) ;; *) echo "install: --from takes a step number 1-11" >&2; exit 2 ;; esac

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO_DIR/config/deploy.env" ] || {
  echo "install: config/deploy.env not found. Start with:" >&2
  echo "           cp config/deploy.env.example config/deploy.env   # then edit it" >&2
  exit 1; }
[ "$(stat -c %a "$REPO_DIR/config/deploy.env")" = "600" ] || chmod 600 "$REPO_DIR/config/deploy.env"
. "$REPO_DIR/scripts/lib.sh"

# The Miniconda this deployment installs for itself (step 4).
MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-py312_25.1.1-2-Linux-x86_64.sh"
MINICONDA_SHA256="4766d85b5f7d235ce250e998ebb5a8a8210cbd4f2b0fea4d2177b3ed9ea87884"

die()  { printf 'install: %s\n' "$*" >&2; exit 1; }
step() { STEP="$1"; shift; [ "$STEP" -ge "$FROM" ] || return 1; printf '\n== step %s: %s\n' "$STEP" "$*"; }
did()  { printf '   %s\n' "$*"; }
problems=0
bad()  { printf '   MISSING  %s\n' "$*"; problems=$((problems + 1)); }
good() { printf '   ok       %s\n' "$*"; }

# ---------------------------------------------------------------------------------
if step 1 "prerequisites and configuration"; then
  # Configuration first: this is where the developer checkout's ports, database
  # names and paths are refused. Nothing is written: the output goes to a scratch
  # directory that is emptied again.
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/vs-check.XXXXXX")"
  "$REPO_DIR/config/render.sh" --allow-placeholders --out "$scratch" >/dev/null || die "fix config/deploy.env (message above)"
  find "$scratch" -type f -exec rm -f {} +; find "$scratch" -depth -type d -exec rmdir {} +
  good "config/deploy.env renders; no developer-checkout port, database or path in it"
  case "$VS_DB_USER" in avrpdev|postgres) die "VS_DB_USER '$VS_DB_USER' belongs to the developer checkout or Postgres" ;; esac
  [ "$VS_USER" != "root" ] || die "VS_USER must not be root"
  [ "$VS_USER" != "$(id -un)" ] || die "VS_USER is your own account ($VS_USER); the deployment needs a dedicated user"

  if [ -r /etc/os-release ] && grep -q 'VERSION_ID="24.04"' /etc/os-release; then good "Ubuntu 24.04"
  else printf '   note     not Ubuntu 24.04 — the only host this install has run on\n'; fi

  if smi="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>&1)"; then
    good "GPU: $smi"
    mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)"
    [ "${mib:-0}" -ge 7900 ] || bad "GPU has ${mib} MiB; registration and both AI modules need about 8 GB"
  else
    case "$smi" in
      *"version mismatch"*) bad "nvidia-smi: driver/library version mismatch — the kernel module and the user-space library differ (a driver update without a reboot). Reboot the box." ;;
      *) bad "nvidia-smi does not work: $(printf '%s' "$smi" | head -1)" ;;
    esac
  fi

  if [ -x "$VS_NODE_BIN" ]; then
    nv="$("$VS_NODE_BIN" --version)"; major="${nv#v}"; major="${major%%.*}"
    if [ "$major" -ge 20 ]; then good "node $nv ($VS_NODE_BIN)"; else bad "node $nv is older than 20"; fi
  else bad "node at $VS_NODE_BIN (VS_NODE_BIN)"; fi
  missing=""
  for c in npm git openssl curl psql pg_dump sha256sum ss; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  if [ -z "$missing" ]; then good "npm, git, openssl, curl, psql, pg_dump"; else bad "on PATH:$missing"; fi

  if command -v pg_isready >/dev/null 2>&1 && pg_isready -q -h "$VS_PG_HOST" -p "$VS_PG_PORT"; then
    good "PostgreSQL answers on $VS_PG_HOST:$VS_PG_PORT"
  else bad "PostgreSQL on $VS_PG_HOST:$VS_PG_PORT (pg_isready)"; fi

  if [ -x "$VS_CADDY_BIN" ]; then
    good "caddy $("$VS_CADDY_BIN" version | awk '{print $1}')"
    # The Ubuntu package starts its own caddy.service with a welcome page on port 80.
    if systemctl is-active --quiet caddy.service 2>/dev/null || systemctl is-enabled --quiet caddy.service 2>/dev/null; then
      bad "the distribution's caddy.service is enabled or running and would hold port 80:  sudo systemctl disable --now caddy.service"
    fi
  else bad "caddy at $VS_CADDY_BIN:  sudo apt install caddy && sudo systemctl disable --now caddy.service"; fi

  # The worker's CUDA extension is compiled here; CUDA 12 needs GCC <= 12.
  if command -v gcc >/dev/null 2>&1; then
    g="$(gcc -dumpversion | cut -d. -f1)"
    if [ "$g" -le 12 ]; then good "gcc $g (usable with CUDA 12)"
    elif command -v gcc-12 >/dev/null 2>&1 && command -v g++-12 >/dev/null 2>&1; then good "gcc $g is too new for CUDA 12; gcc-12 and g++-12 are present"
    else bad "gcc is $g and gcc-12/g++-12 are not installed:  sudo apt install gcc-12 g++-12"; fi
  else bad "gcc:  sudo apt install gcc-12 g++-12"; fi

  if [ -n "${VS_CA_BUNDLE:-}" ] && [ ! -r "$VS_CA_BUNDLE" ]; then bad "VS_CA_BUNDLE=$VS_CA_BUNDLE is not readable"; fi

  # Ports: free, or already ours.
  for pu in "$VS_PUBLIC_PORT:valvescope-proxy" "$VS_GATEWAY_PORT:valvescope-gateway" "$VS_MANAGER_PORT:valvescope-manager" "$VS_VIEWER_PORT:valvescope-viewer"; do
    p="${pu%%:*}"; u="${pu#*:}"
    if ss -ltnH "sport = :$p" 2>/dev/null | grep -q . && ! systemctl is-active --quiet "$u" 2>/dev/null; then
      bad "port $p is in use by something that is not $u (ss -ltnp 'sport = :$p')"
    fi
  done
  [ "$problems" -ne 0 ] || good "ports $VS_PUBLIC_PORT, $VS_GATEWAY_PORT, $VS_MANAGER_PORT, $VS_VIEWER_PORT are free or already ValveScope's"

  if [ "$CHECK_ONLY" -eq 0 ]; then
    if sudo -n true 2>/dev/null || sudo -v; then good "sudo"; else bad "sudo for $(id -un)"; fi
  fi
  [ "$problems" -eq 0 ] || die "$problems prerequisite(s) missing — nothing was changed"
fi
[ "$CHECK_ONLY" -eq 0 ] || { echo; echo "install: check only — nothing was changed"; exit 0; }

# ---------------------------------------------------------------------------------
if step 2 "Unix user and directories"; then
  if getent passwd "$VS_USER" >/dev/null; then did "user $VS_USER exists"
  else
    sudo useradd --system --user-group --home-dir "$VS_HOME" --no-create-home --shell /usr/sbin/nologin "$VS_USER"
    did "created system user $VS_USER (home $VS_HOME, no login shell)"
  fi
  ensure_dir() { # DIR MODE — created if missing; an existing directory keeps its contents
    local d="$1" mode="$2" owner
    if ! sudo test -d "$d"; then
      sudo install -d -o "$VS_USER" -g "$VS_USER" -m "$mode" "$d"; did "created $d"
    else
      owner="$(sudo stat -c %U "$d")"
      if [ "$owner" != "$VS_USER" ]; then sudo chown "$VS_USER:$VS_USER" "$d"; did "$d now belongs to $VS_USER (was $owner; contents untouched)"
      else did "exists  $d"; fi
    fi
  }
  ensure_dir "$VS_HOME" 755
  ensure_dir "$VS_SRC_DIR" 755
  ensure_dir "$VS_STATE_DIR" 755
  ensure_dir "$VS_HOME/etc" 755
  ensure_dir "$VS_DATA_ROOT" 750
  ensure_dir "$VS_WORK_DIR" 750
  ensure_dir "$VS_UPLOAD_CACHE" 750
  ensure_dir "$VS_BACKUP_DIR" 750
  ensure_dir "$VS_CT_MODELS_DIR" 755
  ensure_dir "$VS_TEE_MODELS_DIR" 755
  if vs_as_user test -r "$REPO_DIR/versions.lock" && vs_as_user test -x "$REPO_DIR/install/fetch-sources.sh"; then
    did "$VS_USER can read this repository"
  else
    die "$VS_USER cannot read this repository at $REPO_DIR. Put it where that user can, e.g. $VS_HOME/valvescope-deploy (owned by you), and run install.sh from there."
  fi
fi

# ---------------------------------------------------------------------------------
if step 3 "secrets"; then
  "$REPO_DIR/install/gen-secrets.sh" | sed 's/^/   /'
  . "$REPO_DIR/scripts/lib.sh"     # pick up what was just generated
fi

# ---------------------------------------------------------------------------------
if step 4 "miniconda at $VS_CONDA_ROOT"; then
  if vs_as_user test -x "$VS_CONDA_ROOT/bin/conda"; then
    did "present: $(cd / && vs_as_user "$VS_CONDA_ROOT/bin/conda" --version)"
  else
    case "$VS_CONDA_ROOT" in /home/*) die "VS_CONDA_ROOT is inside a home directory ($VS_CONDA_ROOT); the deployment has its own conda" ;; esac
    tmp="$(vs_as_user mktemp -d "${TMPDIR:-/tmp}/vs-conda.XXXXXX")"
    did "downloading $(basename "$MINICONDA_URL")"
    ( cd / && vs_as_user curl -fsSL -o "$tmp/miniconda.sh" "$MINICONDA_URL" )
    got="$(vs_as_user sha256sum "$tmp/miniconda.sh" | cut -d' ' -f1)"
    [ "$got" = "$MINICONDA_SHA256" ] || die "installer checksum is $got, expected $MINICONDA_SHA256 — not run"
    # -b: no prompts, and no edit of any shell start-up file.
    ( cd / && vs_as_user bash "$tmp/miniconda.sh" -b -p "$VS_CONDA_ROOT" >/dev/null )
    vs_as_user rm -f "$tmp/miniconda.sh"; vs_as_user rmdir "$tmp"
    did "installed: $(cd / && vs_as_user "$VS_CONDA_ROOT/bin/conda" --version)"
  fi
fi

# ---------------------------------------------------------------------------------
if step 5 "systemd units"; then
  "$REPO_DIR/config/render.sh" >/dev/null
  changed=0
  for f in "$REPO_DIR"/rendered/systemd/*; do
    dest="/etc/systemd/system/$(basename "$f")"
    if cmp -s "$f" "$dest" 2>/dev/null; then did "unchanged $dest"
    else sudo install -o root -g root -m 644 "$f" "$dest"; did "installed $dest"; changed=1; fi
  done
  [ "$changed" -eq 0 ] || sudo systemctl daemon-reload
  for u in $VS_TARGET $VS_UNITS; do
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then :; else sudo systemctl enable "$u" >/dev/null 2>&1; did "enabled $u"; fi
  done
  did "every unit is enabled (starts with the machine); this step starts nothing"
fi

# ---------------------------------------------------------------------------------
if step 6 "model weights"; then
  if out="$("$REPO_DIR/scripts/verify-models.sh" 2>&1)"; then printf '%s\n' "$out" | sed 's/^/   /'
  else
    printf '%s\n' "$out" | sed 's/^/   /'
    die "model weights are not in place. They are not in git and nothing downloads them: copy each
         model directory to the path shown above (owned by $VS_USER), then: install/install.sh --from 6"
  fi
fi

# ---------------------------------------------------------------------------------
if step 7 "gateway and databases"; then
  "$REPO_DIR/scripts/upgrade.sh" --no-health --only avrp-gateway
fi

# ---------------------------------------------------------------------------------
if step 8 "accounts"; then
  "$REPO_DIR/install/accounts.sh" | sed 's/^/   /'
fi

# ---------------------------------------------------------------------------------
if step 9 "conda environments, worker, manager, viewer, models"; then
  "$REPO_DIR/scripts/upgrade.sh" --no-health
  "$REPO_DIR/scripts/check-modules.sh" | sed 's/^/   /'
fi

# ---------------------------------------------------------------------------------
if step 10 "firewall"; then
  if ! command -v ufw >/dev/null 2>&1; then
    did "ufw is not installed — nothing to do here"
  else
    # The services listen on loopback; only the proxy's port has to be reachable.
    if [ -n "${VS_LAN_CIDR:-}" ]; then rule="allow from $VS_LAN_CIDR to any port $VS_PUBLIC_PORT proto tcp"
    else rule="allow $VS_PUBLIC_PORT/tcp"; fi
    status="$(sudo ufw status 2>/dev/null || true)"
    if printf '%s\n' "$status" | grep -q '^Status: inactive'; then
      did "ufw is inactive: nothing blocks port $VS_PUBLIC_PORT. Nothing changed."
    elif printf '%s\n' "$status" | grep -Eq "^$VS_PUBLIC_PORT(/tcp)?[[:space:]]+ALLOW"; then
      did "ufw already allows port $VS_PUBLIC_PORT"
    elif [ "$APPLY_FW" -eq 1 ]; then
      # shellcheck disable=SC2086
      sudo ufw $rule
      did "applied: ufw $rule"
    else
      did "ufw is active and does not allow port $VS_PUBLIC_PORT. The rule this install needs:"
      did "    sudo ufw $rule"
      did "NOT applied — the firewall is shared with everything else on this machine."
      did "Apply it yourself, or run: install/install.sh --from 10 --apply-firewall"
    fi
  fi
fi

# ---------------------------------------------------------------------------------
if step 11 "start and health"; then
  all=1; for u in $VS_UNITS; do systemctl is-active --quiet "$u" || all=0; done
  if [ "$all" -eq 1 ]; then did "every unit is already running; nothing started or restarted"
  else
    sudo systemctl start "$VS_TARGET"
    did "started $VS_TARGET"
    # Give the services a moment to open their ports before judging them.
    i=0
    while [ "$i" -lt 30 ]; do
      if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$VS_GATEWAY_PORT/" \
         && curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:$VS_MANAGER_PORT/"; then break; fi
      i=$((i + 1)); sleep 1
    done
  fi
  "$REPO_DIR/scripts/health.sh"
fi
