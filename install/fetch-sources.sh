#!/usr/bin/env bash
# fetch-sources.sh — check out exactly the commits named in versions.lock.
#
#   install/fetch-sources.sh [--dest DIR] [--lock FILE] [--all] [--only a,b,c]
#
#   --dest DIR   where sources go (default: $VS_HOME/src from config/deploy.env,
#                else ./src)
#   --lock FILE  lock file to read (default: versions.lock next to this repo)
#   --all        also fetch role=client components (e.g. avrp-ipad)
#   --only LIST  fetch only these comma-separated component names
#   --credential-stdin
#                read a git credential (the output of `git credential fill`) from
#                stdin and use it for this run only. For running as a user that has
#                no GitHub access of its own; see vs_fetch_sources in scripts/lib.sh.
#
# Each component lands in DIR/<name> at a detached HEAD equal to the pinned SHA.
# Components with a path (they live inside another repo) are checked out sparsely
# into DIR/.repos/<repo>@<sha> and DIR/<name> is a symlink into that checkout.
# Submodules of a component are initialised at the commits that component records.
#
# Safe to re-run: an existing checkout is moved to the pinned SHA. It refuses to
# touch a checkout with local changes — the deploy tree carries no source patches.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$REPO_DIR/versions.lock"
DEST=""
ALL=0
ONLY=""
CRED_STDIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --lock) LOCK="$2"; shift 2 ;;
    --all)  ALL=1; shift ;;
    --only) ONLY=",$2,"; shift 2 ;;
    --credential-stdin) CRED_STDIN=1; shift ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fetch-sources: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$DEST" ]; then
  if [ -f "$REPO_DIR/config/deploy.env" ]; then
    # shellcheck disable=SC1091
    VS_HOME="$(. "$REPO_DIR/config/deploy.env" && printf '%s' "${VS_HOME:-}")"
  fi
  DEST="${VS_HOME:+$VS_HOME/src}"
  DEST="${DEST:-$REPO_DIR/src}"
fi

if [ "$CRED_STDIN" -eq 1 ]; then
  # Held in this process's environment only. The helper below hands it to git (and
  # to the submodule fetches git starts); the user's own helpers are switched off.
  VS_GIT_CRED="$(cat)"
  export VS_GIT_CRED GIT_TERMINAL_PROMPT=0
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
  export GIT_CONFIG_KEY_1=credential.helper
  export GIT_CONFIG_VALUE_1='!f() { test "$1" = get && printf "%s\n" "$VS_GIT_CRED"; }; f'
fi

[ -f "$LOCK" ] || { echo "fetch-sources: lock file not found: $LOCK" >&2; exit 1; }
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

say() { printf '%s\n' "$*"; }
die() { printf 'fetch-sources: %s\n' "$*" >&2; exit 1; }

# checkout_at DIR URL SHA [SPARSE_PATH...]
# Brings DIR to a detached HEAD at SHA, fetching only that commit.
checkout_at() {
  local dir="$1" url="$2" sha="$3"; shift 3
  if [ -d "$dir/.git" ]; then
    [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] \
      || die "$dir has local changes; refusing to move it"
    git -C "$dir" remote set-url origin "$url"
  else
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
  fi
  if [ $# -gt 0 ]; then
    # Blobs are fetched lazily, so only the sparse paths are ever downloaded.
    git -C "$dir" config remote.origin.promisor true
    git -C "$dir" config remote.origin.partialclonefilter blob:none
    git -C "$dir" sparse-checkout set --cone "$@"
  fi
  if [ "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$sha" ]; then
    if [ $# -gt 0 ]; then
      git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$sha"
    else
      git -C "$dir" fetch -q --depth 1 origin "$sha"
    fi
    git -C "$dir" -c advice.detachedHead=false checkout -q --detach "$sha"
  fi
  local got
  got="$(git -C "$dir" rev-parse HEAD)"
  [ "$got" = "$sha" ] || die "$dir is at $got, expected $sha"
  if [ -f "$dir/.gitmodules" ]; then
    git -C "$dir" submodule -q update --init --recursive --depth 1
  fi
}

# Sparse paths wanted per wrapper-style checkout, collected in a first pass so two
# components from the same repo+sha share one checkout.
shared_paths() { # URL SHA -> space-separated paths selected from the lock
  local want_url="$1" want_sha="$2" name role url tag sha path out=""
  while read -r name role url tag sha path; do
    case "$name" in ''|\#*) continue ;; esac
    [ "$path" != "-" ] && [ "$url" = "$want_url" ] && [ "$sha" = "$want_sha" ] || continue
    selected "$name" "$role" || continue
    out="$out $path"
  done < "$LOCK"
  printf '%s' "$out"
}

selected() { # NAME ROLE
  if [ -n "$ONLY" ]; then
    case "$ONLY" in *",$1,"*) return 0 ;; *) return 1 ;; esac
  fi
  [ "$2" = "host" ] || [ "$ALL" -eq 1 ]
}

count=0
while read -r name role url tag sha path; do
  case "$name" in ''|\#*) continue ;; esac
  [ -n "${path:-}" ] || die "malformed line for '$name' (need 6 columns)"
  case "$sha" in
    *[!0-9a-f]*) die "$name: sha is not hex: $sha" ;;
  esac
  [ ${#sha} -eq 40 ] || die "$name: sha must be the full 40 characters"
  case "$role" in host|client) ;; *) die "$name: role must be host or client" ;; esac
  selected "$name" "$role" || { say "skip   $name ($role)"; continue; }

  if [ "$path" = "-" ]; then
    checkout_at "$DEST/$name" "$url" "$sha"
  else
    repo="$(basename "$url" .git)"
    shared="$DEST/.repos/$repo@$sha"
    # shellcheck disable=SC2046
    checkout_at "$shared" "$url" "$sha" $(shared_paths "$url" "$sha")
    [ -d "$shared/$path" ] || die "$name: path '$path' not found in $repo@$sha"
    if [ -e "$DEST/$name" ] && [ ! -L "$DEST/$name" ]; then
      die "$DEST/$name exists and is not a symlink"
    fi
    ln -sfn ".repos/$repo@$sha/$path" "$DEST/$name"
  fi
  label="$sha"; [ "$tag" = "-" ] || label="$tag ($sha)"
  say "ok     $name @ $label"
  count=$((count + 1))
done < "$LOCK"

[ "$count" -gt 0 ] || die "nothing selected from $LOCK"
say "fetched $count component(s) into $DEST"
