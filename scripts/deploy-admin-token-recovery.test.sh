#!/usr/bin/env bash
# check() evals its condition later, so single quotes and "unused" vars are intended.
# shellcheck disable=SC2016,SC2034
# Runs deploy.sh's admin token blocks, sliced out of deploy.sh itself, with a
# fake `mix`. It pins that a re-run (existing .env) with no token file mints
# through `mix barkpark.admin_token` into that file, that a fresh box and a
# box with the file do not call it, and that a failed mint does not stop the run.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fails=$((fails + 1)); fi; }

awk '/^SEED_PROFILE="\$\{BARKPARK_SEED_PROFILE:-clean\}"$/{on=1} on{print} on && /^fi$/{exit}' "$ROOT/deploy.sh" > "$TMP/pre.sh"
awk '/^if \[ -n "\$RECOVERY_MINT" \]/{on=1} on{print} on && /^fi$/{exit}' "$ROOT/deploy.sh" > "$TMP/post.sh"
grep -q RECOVERY_MINT=1 "$TMP/pre.sh" || { echo "FATAL: token block not found in deploy.sh"; exit 1; }
grep -q 'mix barkpark.admin_token' "$TMP/post.sh" || { echo "FATAL: recovery block not found in deploy.sh"; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/mix" <<'MIX'
#!/usr/bin/env bash
echo "$*" >> "$MIX_LOG"
[ -n "${MIX_FAIL:-}" ] && { echo "admin-token: boom" >&2; exit 1; }
file=""
while [ $# -gt 0 ]; do [ "$1" = "--file" ] && file="$2"; shift; done
mkdir -p "$(dirname "$file")"
printf 'bp_admin_fake\n' > "$file"
echo "Admin token id: 11111111-2222-3333-4444-555555555555"
echo "Token written to $file (mode 0600). Id written to $file.id."
MIX
chmod +x "$TMP/bin/mix"

run() { # $1 = FRESH_ENV value; rest = extra env
  local fresh="$1"; shift
  : > "$TMP/mix.log"
  env -u BARKPARK_SEED_ADMIN_TOKEN PATH="$TMP/bin:$PATH" MIX_LOG="$TMP/mix.log" \
    BARKPARK_ADMIN_TOKEN_FILE="$TMP/etc/admin-token" APP_DIR=/opt/barkpark FRESH_ENV="$fresh" "$@" \
    bash -c 'set -euo pipefail; ADMIN_TOKEN_ID=""; . "$1"; . "$2"; echo "ID=$ADMIN_TOKEN_ID TOKEN=${ADMIN_TOKEN:+set}"' \
    _ "$TMP/pre.sh" "$TMP/post.sh" 2>&1
}

out="$(run "")"
check "re-run without the file calls the recovery command" 'grep -q "^barkpark.admin_token --label admin (deploy.sh re-run) --file $TMP/etc/admin-token$" "$TMP/mix.log"'
check "re-run picks up the id" 'grep -q "^ID=11111111-2222-3333-4444-555555555555 TOKEN=set$" <<<"$out"'
check "the token value is not printed" '! grep -q bp_admin_fake <<<"$out"'

out="$(run "")"
check "a second re-run finds the file and does not mint" '[ ! -s "$TMP/mix.log" ] && grep -q "TOKEN=set" <<<"$out"'

rm -rf "${TMP:?}/etc"
out="$(run 1)"
check "a fresh box mints in the seed, not the recovery command" '[ ! -s "$TMP/mix.log" ] && [ -s "$TMP/etc/admin-token" ]'

rm -rf "${TMP:?}/etc"
out="$(run "" BARKPARK_SEED_PROFILE=demo)"
check "the demo profile does not mint" '[ ! -s "$TMP/mix.log" ]'

out="$(run "" MIX_FAIL=1)"; rc=$?
check "a failed mint does not stop the run" '[ "$rc" -eq 0 ] && grep -q "start.sh admin-token" <<<"$out"'

if [ "$fails" -ne 0 ]; then echo "deploy-admin-token-recovery: $fails failed"; exit 1; fi
echo "deploy-admin-token-recovery: all checks passed"
