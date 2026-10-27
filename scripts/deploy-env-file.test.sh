#!/usr/bin/env bash
# check() evals its condition later, so single quotes and "unused" vars are intended.
# shellcheck disable=SC2016,SC2034
# Runs deploy.sh's BARKPARK_ENV_FILE merge, sliced out of deploy.sh itself,
# against a temporary .env. It pins that the file cannot replace DATABASE_URL
# or the generated keys, that deploy.sh prints one line naming each kept key,
# that every other key still merges, and that the merged file is deleted.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fails=$((fails + 1)); fi; }

awk '/^if \[ -n "\$\{BARKPARK_ENV_FILE:-\}" \]; then$/{on=1} on{print} on && /^fi$/{exit}' "$ROOT/deploy.sh" > "$TMP/merge.sh"
grep -q DEPLOY_OWNED_KEYS "$TMP/merge.sh" || { echo "FATAL: env-file merge not found in deploy.sh"; exit 1; }

APP_DIR="$TMP/app"
mkdir -p "$APP_DIR"
cat > "$APP_DIR/.env" <<'ENV'
DATABASE_URL=ecto://barkpark:deploypw@localhost/barkpark_prod
SECRET_KEY_BASE=deploy-secret
BARKPARK_KEK=deploy-kek
PHX_HOST=old.example.com
PORT=4000
ENV
cat > "$TMP/init.env" <<'ENV'
# written by an older bp instance init
DATABASE_URL=ecto://barkpark:initpw@localhost/barkpark
export SECRET_KEY_BASE=init-secret
BARKPARK_CLOAK_KEY=init-cloak
BARKPARK_KEK=init-kek
PREVIEW_JWT_SECRET=init-jwt
PHX_HOST=cms.example.com
BARKPARK_OPERATOR_EMAILS=ops@example.com
ENV

out="$(APP_DIR="$APP_DIR" BARKPARK_ENV_FILE="$TMP/init.env" bash -c 'set -euo pipefail; . "$1"' _ "$TMP/merge.sh" 2>&1)"
rc=$?
env="$(cat "$APP_DIR/.env")"

check "merge exits 0" '[ "$rc" -eq 0 ]'
check "DATABASE_URL keeps deploy.sh value" 'grep -qx "DATABASE_URL=ecto://barkpark:deploypw@localhost/barkpark_prod" <<<"$env"'
check "SECRET_KEY_BASE keeps deploy.sh value" 'grep -qx "SECRET_KEY_BASE=deploy-secret" <<<"$env"'
check "BARKPARK_KEK keeps deploy.sh value" 'grep -qx "BARKPARK_KEK=deploy-kek" <<<"$env"'
check "no init value reaches .env" '! grep -q "init-\|initpw" <<<"$env"'
check "other keys still merge" 'grep -qx "PHX_HOST=cms.example.com" <<<"$env" && grep -qx "BARKPARK_OPERATOR_EMAILS=ops@example.com" <<<"$env" && grep -qx "PORT=4000" <<<"$env"'
check "one line names each kept key" '[ "$(grep -c "^>> Kept deploy.sh" <<<"$out")" -eq 1 ] && grep "^>> Kept deploy.sh" <<<"$out" | grep -q "DATABASE_URL SECRET_KEY_BASE BARKPARK_CLOAK_KEY BARKPARK_KEK PREVIEW_JWT_SECRET"'
check "merged line leaves out kept keys" 'grep "^>> Merged" <<<"$out" | grep -q "PHX_HOST BARKPARK_OPERATOR_EMAILS" && ! grep "^>> Merged" <<<"$out" | grep -q DATABASE_URL'
check "no secret value printed" '! grep -q "init-\|initpw\|deploypw" <<<"$out"'
check "merged file is deleted" '[ ! -e "$TMP/init.env" ] && grep -q "^>> Deleted $TMP/init.env" <<<"$out"'

# A file that is .env itself is merged in place and kept.
before="$(cat "$APP_DIR/.env")"
out3="$(APP_DIR="$APP_DIR" BARKPARK_ENV_FILE="$TMP/app/.env" bash -c 'set -euo pipefail; . "$1"' _ "$TMP/merge.sh" 2>&1)"
check ".env itself is kept" '[ -s "$APP_DIR/.env" ] && [ "$(cat "$APP_DIR/.env")" = "$before" ] && ! grep -q "^>> Deleted" <<<"$out3"'

# A file without owned keys prints no kept line.
printf 'PHX_HOST=b.example.com\n' > "$TMP/clean.env"
out2="$(APP_DIR="$APP_DIR" BARKPARK_ENV_FILE="$TMP/clean.env" bash -c 'set -euo pipefail; . "$1"' _ "$TMP/merge.sh" 2>&1)"
check "no kept line without owned keys" '! grep -q "^>> Kept" <<<"$out2"'

# .env holds the keys: secure_env sets mode 600, and deploy.sh calls it after
# the .env is written and again before the instance check, on every run.
sed -n '/^secure_env() {/p' "$ROOT/deploy.sh" > "$TMP/secure.sh"
chmod 644 "$APP_DIR/.env"
APP_DIR="$APP_DIR" bash -c 'chown() { :; }; . "$1"; secure_env' _ "$TMP/secure.sh"
mode="$(stat -c %a "$APP_DIR/.env" 2>/dev/null || stat -f %Lp "$APP_DIR/.env")"
check "secure_env leaves .env at mode 600" '[ "$mode" = 600 ]'
check "deploy.sh calls secure_env twice" '[ "$(grep -c "^secure_env$" "$ROOT/deploy.sh")" -eq 2 ]'
check "secure_env makes root the owner" 'grep -q "chown root:root \"\$APP_DIR/.env\"" "$TMP/secure.sh"'

if [ "$fails" -ne 0 ]; then echo "deploy-env-file: $fails failed"; exit 1; fi
echo "deploy-env-file: all passed"
