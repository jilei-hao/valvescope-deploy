#!/usr/bin/env bash
# verify-models.sh — are the model weights on disk the ones models.manifest lists?
# Read-only.
#
#   scripts/verify-models.sh [--full] [--manifest FILE] [NAME...]
#
#   (default)  quick: every listed file is present with the listed size. Reads no
#              file contents, so it is cheap enough for scripts/health.sh.
#   --full     quick, plus re-hash every file that has a sha256 in the list (the
#              weights and configuration). Minutes for multi-GB models.
#   NAME...    only these models (default: all in the manifest)
#
# For every model it also checks that models/<name>.files itself still matches the
# checksum in the manifest, so the list cannot drift from what was committed.
#
# A model marked UNMEASURED has no list: only its directory is checked, and it is
# reported as a warning, not a failure.
#
# Exit 0 if nothing failed, 1 otherwise.
set -uo pipefail
FULL=0; MANIFEST=""; NAMES=","
while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL=1; shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "verify-models: unknown argument: $1" >&2; exit 2 ;;
    *) NAMES="$NAMES$1,"; shift ;;
  esac
done
. "$(dirname "$0")/lib.sh"
MANIFEST="${MANIFEST:-$REPO_DIR/models.manifest}"
[ -f "$MANIFEST" ] || { echo "verify-models: manifest not found: $MANIFEST" >&2; exit 1; }
if [ "$NAMES" != "," ]; then
  for n in $(printf '%s' "$NAMES" | tr ',' ' '); do
    awk -v n="$n" '$1 == n && NF == 6 { f = 1 } END { exit f ? 0 : 1 }' "$MANIFEST" \
      || { echo "verify-models: '$n' is not in $(basename "$MANIFEST")" >&2; exit 2; }
  done
fi
mode=quick; [ "$FULL" -eq 1 ] && mode=full
failed=0; warned=0; checked=0
bad() { printf 'FAIL  model %s: %s\n' "$1" "$2"; failed=$((failed + 1)); }

while read -r name location subdir version checksum restart extra; do
  case "$name" in ''|\#*) continue ;; esac
  if [ "$NAMES" != "," ]; then case "$NAMES" in *",$name,"*) ;; *) continue ;; esac; fi
  checked=$((checked + 1))
  dir="$(vs_model_dir "$location" "$subdir")" || { bad "$name" "$location is not set in deploy.env"; continue; }
  if [ ! -d "$dir" ]; then bad "$name" "directory missing: $dir"; continue; fi
  if [ "$checksum" = "UNMEASURED" ]; then
    printf 'warn  model %s: directory exists, but the model is UNMEASURED — contents not checked (%s)\n' "$name" "$dir"
    warned=$((warned + 1)); continue
  fi
  list="$(dirname "$MANIFEST")/models/$name.files"
  if [ ! -f "$list" ]; then bad "$name" "file list missing from the repository: models/$name.files"; continue; fi
  if [ "$(vs_sha256 "$list")" != "$checksum" ]; then
    bad "$name" "models/$name.files does not match the checksum in $(basename "$MANIFEST") (list or manifest edited by hand?)"; continue
  fi
  problems=""; n=0; hashed=0
  while IFS="$(printf '\t')" read -r size sum rel; do
    n=$((n + 1))
    f="$dir/$rel"
    if [ ! -f "$f" ]; then problems="$problems
        missing: $rel"; continue; fi
    have="$(wc -c < "$f" | tr -d ' ')"
    if [ "$have" != "$size" ]; then problems="$problems
        size $have, expected $size: $rel"; continue; fi
    if [ "$FULL" -eq 1 ] && [ "$sum" != "-" ]; then
      hashed=$((hashed + 1))
      [ "$(vs_sha256 "$f")" = "$sum" ] || problems="$problems
        content differs (sha256): $rel"
    fi
  done < "$list"
  if [ -n "$problems" ]; then
    bad "$name" "version $version at $dir does not match its list ($mode check):$problems"
  elif [ "$FULL" -eq 1 ]; then
    printf 'ok    model %s: version %s — %s files present with the right size, %s re-hashed\n' "$name" "$version" "$n" "$hashed"
  else
    printf 'ok    model %s: version %s — %s files present with the right size (contents not read; --full does)\n' "$name" "$version" "$n"
  fi
done < "$MANIFEST"

[ "$checked" -gt 0 ] || { echo "verify-models: no models in $(basename "$MANIFEST")"; }
[ "$failed" -eq 0 ]
