#!/usr/bin/env bash
# model-manifest.sh — measure a model directory: write its file list and checksum.
# Run it ON THE SERVER, where the weights are. It only reads the model directory.
#
#   scripts/model-manifest.sh --name NAME [--write] [--version LABEL] [--dir DIR]
#
#   --name NAME      the model's name. If it is already in models.manifest, its
#                    directory is taken from there.
#   --dir DIR        the model directory, for a model that has no manifest line yet
#   --version LABEL  version label to print / write (default: keep the current one)
#   --write          update NAME's line in models.manifest (checksum, and version if
#                    given). Without it the manifest is left alone and the line is printed.
#   --manifest FILE  manifest to use (default: models.manifest)
#
# Writes models/<NAME>.files next to the manifest: one line per file, tab-separated
#     size <TAB> sha256-or-"-" <TAB> path relative to the model directory
# sorted by path. Weights and configuration files get a sha256 (the rule is
# vs_model_hashed in scripts/lib.sh); other files are listed by size only. The
# checksum for the manifest is the sha256 of that list.
#
# Then commit models/<NAME>.files and models.manifest. Reading multi-GB weights
# takes minutes.
set -euo pipefail
NAME=""; DIR=""; VERSION=""; WRITE=0; MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --write) WRITE=1; shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "model-manifest: unknown argument: $1" >&2; exit 2 ;;
  esac
done
. "$(dirname "$0")/lib.sh"
die() { printf 'model-manifest: %s\n' "$*" >&2; exit 1; }
MANIFEST="${MANIFEST:-$REPO_DIR/models.manifest}"
[ -n "$NAME" ] || die "--name is required"
printf '%s' "$NAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || die "name may only contain letters, digits and . _ -"
[ -z "$VERSION" ] || printf '%s' "$VERSION" | grep -Eq '^[A-Za-z0-9._-]+$' || die "version may only contain letters, digits and . _ -"

line="$(awk -v n="$NAME" '$1 == n && NF == 6' "$MANIFEST" 2>/dev/null || true)"
if [ -z "$DIR" ]; then
  [ -n "$line" ] || die "'$NAME' is not in $(basename "$MANIFEST"); give --dir for a new model"
  # shellcheck disable=SC2086
  set -- $line
  DIR="$(vs_model_dir "$2" "$3")"
fi
[ -d "$DIR" ] || die "model directory not found: $DIR"
DIR="$(cd "$DIR" && pwd)"

out_dir="$(dirname "$MANIFEST")/models"
mkdir -p "$out_dir"
list="$out_dir/$NAME.files"
tmp="$list.tmp.$$"
nfiles=0; nhashed=0
( cd "$DIR" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) > "$tmp.paths"
while IFS= read -r rel; do
  size="$(wc -c < "$DIR/$rel" | tr -d ' ')"
  if vs_model_hashed "$rel"; then sum="$(vs_sha256 "$DIR/$rel")"; nhashed=$((nhashed + 1)); else sum="-"; fi
  printf '%s\t%s\t%s\n' "$size" "$sum" "$rel"
  nfiles=$((nfiles + 1))
done < "$tmp.paths" > "$tmp"
rm -f "$tmp.paths"
[ "$nfiles" -gt 0 ] || { rm -f "$tmp"; die "no files under $DIR"; }
mv "$tmp" "$list"
checksum="$(vs_sha256 "$list")"

echo "model-manifest: $NAME — $nfiles files, $nhashed hashed, in $DIR"
echo "  file list: $list"
echo "  checksum:  $checksum"
if [ "$WRITE" -eq 1 ]; then
  [ -n "$line" ] || die "'$NAME' has no line in $(basename "$MANIFEST") to update; add this line by hand:
  $NAME  <location>  <subdir>  ${VERSION:-<version>}  $checksum  <units or ->"
  awk -v n="$NAME" -v c="$checksum" -v v="$VERSION" '
    $1 == n && NF == 6 && $1 !~ /^#/ { if (v != "") $4 = v; $5 = c; print $1 "  " $2 "  " $3 "  " $4 "  " $5 "  " $6; next }
    { print }' "$MANIFEST" > "$MANIFEST.tmp.$$"
  mv "$MANIFEST.tmp.$$" "$MANIFEST"
  echo "  updated $(basename "$MANIFEST"). Commit it together with models/$NAME.files."
else
  echo "  manifest line (not written; pass --write, or paste it):"
  if [ -n "$line" ]; then
    # shellcheck disable=SC2086
    set -- $line
    echo "    $1  $2  $3  ${VERSION:-$4}  $checksum  $6"
  else
    echo "    $NAME  <location>  <subdir>  ${VERSION:-<version>}  $checksum  <units or ->"
  fi
fi
