#!/usr/bin/env bash
# accounts.sh — make sure the gateway accounts exist: the worker's and one per person.
# Only ever ADDS accounts. An account that exists is left alone (password included).
#
#   install/accounts.sh            create what is missing
#   install/accounts.sh --list     show the accounts in the database; change nothing
#
# Where accounts come from
#   worker    VS_WORKER_USER / VS_WORKER_PASSWORD in config/deploy.env, role "application"
#   people    config/accounts.txt (not in git, mode 600), role "user". One per line:
#                 username
#                 username  initial-password
#             A line without a password gets a generated one, written back into the
#             file so it can be handed to the person. '#' starts a comment.
#
# How: the same way the gateway does it (routes/user.js) — bcrypt of SECRET_KEY +
# password, stored through the database function fn_create_user — using the bcrypt
# and pg modules of the installed gateway. It talks to the database directly, so the
# gateway does not have to be running, and the worker's account can exist before the
# worker first starts.
#
# Note: bcrypt reads only the first 72 bytes. With the 48-character SECRET_KEY that
# gen-secrets.sh makes, the first 24 characters of a password count.
set -euo pipefail
LIST=0
case "${1:-}" in
  --list) LIST=1 ;;
  "") ;;
  -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "accounts: unknown argument: $1" >&2; exit 2 ;;
esac
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib.sh"
die() { printf 'accounts: %s\n' "$*" >&2; exit 1; }

GW="$VS_SRC_DIR/avrp-gateway"
[ -d "$GW/node_modules/bcrypt" ] && [ -d "$GW/node_modules/pg" ] \
  || die "the gateway's node modules are not installed under $GW (run scripts/upgrade.sh --only avrp-gateway first)"
psql_main() { PGPASSWORD="$VS_DB_PASSWORD" psql -X -At -v ON_ERROR_STOP=1 -h "$VS_PG_HOST" -p "$VS_PG_PORT" -U "$VS_DB_USER" -d "$VS_DB_NAME" "$@"; }

if [ "$LIST" -eq 1 ]; then
  psql_main -F '  ' -c "select u.username, r.role_name from users u join user_role r using (user_role_id) order by 1"
  exit 0
fi

# Lower case only: the web viewer's login form lower-cases what is typed, so an
# account with a capital letter in its name could never log in there.
valid_name() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9._-]{1,49}$'; }
ACCOUNTS_FILE="$REPO_DIR/config/accounts.txt"
WANT="$(mktemp "${TMPDIR:-/tmp}/vs-accounts.XXXXXX")"
trap 'rm -f "$WANT"' EXIT
chmod 600 "$WANT"

valid_name "$VS_WORKER_USER" || die "VS_WORKER_USER '$VS_WORKER_USER' is not a usable account name"
[ "$VS_WORKER_PASSWORD" != "CHANGE_ME" ] || die "VS_WORKER_PASSWORD is still CHANGE_ME — run install/gen-secrets.sh"
printf '%s\t%s\t%s\n' "$VS_WORKER_USER" application "$VS_WORKER_PASSWORD" > "$WANT"

if [ -f "$ACCOUNTS_FILE" ]; then
  chmod 600 "$ACCOUNTS_FILE"
  # Fill in missing passwords first, so the file is the record of what was handed out.
  tmp="$(mktemp "$ACCOUNTS_FILE.XXXXXX")"; chmod 600 "$tmp"; filled=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*|[[:space:]]*\#*) printf '%s\n' "$line"; continue ;; esac
    # shellcheck disable=SC2086
    set -- $line
    if [ $# -eq 1 ]; then
      line="$1  $(openssl rand -hex 8)"; filled=$((filled + 1))
    elif [ $# -ne 2 ]; then
      rm -f "$tmp"; die "$ACCOUNTS_FILE: each line is 'username' or 'username password' — got: $1 …"
    fi
    printf '%s\n' "$line"
  done < "$ACCOUNTS_FILE" > "$tmp"
  mv "$tmp" "$ACCOUNTS_FILE"
  [ "$filled" -eq 0 ] || echo "accounts: generated $filled initial password(s) in $ACCOUNTS_FILE"
  while read -r name pw extra; do
    case "$name" in ''|\#*) continue ;; esac
    valid_name "$name" || die "$ACCOUNTS_FILE: '$name' is not a usable account name (lower-case letters, digits, . _ -)"
    [ "$name" != "$VS_WORKER_USER" ] || die "$ACCOUNTS_FILE: '$name' is the worker's account; people need their own"
    printf '%s\t%s\t%s\n' "$name" user "$pw" >> "$WANT"
  done < "$ACCOUNTS_FILE"
else
  echo "accounts: no config/accounts.txt — only the worker account is managed (add one username per line for people)"
fi
dups="$(cut -f1 "$WANT" | sort | uniq -d | tr '\n' ' ')"
[ -z "$dups" ] || die "account named more than once: $dups"

# Which are missing?
have="$(psql_main -c 'select username from users')" || die "cannot read the users table in $VS_DB_NAME"
TODO="$(mktemp "${TMPDIR:-/tmp}/vs-accounts.XXXXXX")"; chmod 600 "$TODO"
trap 'rm -f "$WANT" "$TODO"' EXIT
while IFS="$(printf '\t')" read -r name role pw; do
  if printf '%s\n' "$have" | grep -qx -- "$name"; then
    echo "exists    $name"
  else
    printf '%s\t%s\t%s\n' "$name" "$role" "$pw" >> "$TODO"
  fi
done < "$WANT"
if [ ! -s "$TODO" ]; then
  echo "accounts: nothing to do"
  exit 0
fi

# The script is read from stdin so that its imports resolve against the gateway's
# node_modules (the working directory); the list arrives on fd 3, secrets in the
# environment of this one process.
( cd "$GW" && DB_HOST="$VS_PG_HOST" DB_PORT="$VS_PG_PORT" DB_NAME="$VS_DB_NAME" DB_USER="$VS_DB_USER" \
    DB_PASSWORD="$VS_DB_PASSWORD" SECRET_KEY="$VS_JWT_SECRET" \
    "$VS_NODE_BIN" --input-type=module - 3< "$TODO" <<'JS'
import fs from 'node:fs';
import pkg from 'pg';
import bcrypt from 'bcrypt';
const rows = fs.readFileSync(3, 'utf8').split('\n').filter(Boolean).map((l) => l.split('\t'));
const pool = new pkg.Pool({
  host: process.env.DB_HOST, port: Number(process.env.DB_PORT), database: process.env.DB_NAME,
  user: process.env.DB_USER, password: process.env.DB_PASSWORD,
});
let failed = 0;
try {
  for (const [name, role, pw] of rows) {
    try {
      const hash = await bcrypt.hash(process.env.SECRET_KEY + pw, 10);
      const r = await pool.query('select fn_create_user($1, $2, $3) as id', [name, hash, role]);
      console.log(`created   ${name} (role ${role}, user_id ${r.rows[0].id})`);
    } catch (e) {
      failed += 1;
      console.error(`FAILED    ${name}: ${e.message}`);
    }
  }
} finally {
  await pool.end();
}
process.exit(failed ? 1 : 0);
JS
)
