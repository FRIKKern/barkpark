#!/usr/bin/env bash
# check() evals its condition later, so single quotes and "unused" vars are intended.
# shellcheck disable=SC2016,SC2034
# Runs deploy.sh's admin token blocks, sliced out of deploy.sh itself, with a
# fake `docker`. It pins that a re-run (existing .env) with no token file mints
# through the image's bin/admin-token into that file, as root in the container
# with the file's directory mounted, that a fresh box and a box with the file
# do not call it, and that a failed mint does not stop the run.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fails=$((fails + 1)); fi; }

awk '/^bp_run\(\) \{$/{on=1} on{print} on && /^\}$/{exit}' "$ROOT/deploy.sh" > "$TMP/run.sh"
awk '/^SEED_PROFILE="\$\{BARKPARK_SEED_PROFILE:-clean\}"$/{on=1} on{print} on && /^fi$/{exit}' "$ROOT/deploy.sh" > "$TMP/pre.sh"
awk '/^if \[ -n "\$RECOVERY_MINT" \]/{on=1} on{print} on && /^fi$/{exit}' "$ROOT/deploy.sh" > "$TMP/post.sh"
grep -q 'docker run --rm --network host' "$TMP/run.sh" || { echo "FATAL: bp_run not found in deploy.sh"; exit 1; }
grep -q RECOVERY_MINT=1 "$TMP/pre.sh" || { echo "FATAL: token block not found in deploy.sh"; exit 1; }
grep -q 'bin/admin-token' "$TMP/post.sh" || { echo "FATAL: recovery block not found in deploy.sh"; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
[ -n "${MINT_FAIL:-}" ] && { echo "admin-token: boom" >&2; exit 1; }
file=""
while [ $# -gt 0 ]; do [ "$1" = "--file" ] && file="$2"; shift; done
mkdir -p "$(dirname "$file")"
printf 'bp_admin_fake\n' > "$file"
echo "Admin token id: 11111111-2222-3333-4444-555555555555"
echo "Token written to $file (mode 0600). Id written to $file.id."
DOCKER
chmod +x "$TMP/bin/docker"

run() { # $1 = FRESH_ENV value; rest = extra env
  local fresh="$1"; shift
  : > "$TMP/docker.log"
  env -u BARKPARK_SEED_ADMIN_TOKEN PATH="$TMP/bin:$PATH" DOCKER_LOG="$TMP/docker.log" \
    BARKPARK_ADMIN_TOKEN_FILE="$TMP/etc/admin-token" APP_DIR=/opt/barkpark MEDIA_DIR=/opt/barkpark/uploads \
    BARKPARK_IMAGE=ghcr.io/frikkern/barkpark:9.9.9 FRESH_ENV="$fresh" "$@" \
    bash -c 'set -euo pipefail; ADMIN_TOKEN_ID=""; . "$1"; . "$2"; . "$3"; echo "ID=$ADMIN_TOKEN_ID TOKEN=${ADMIN_TOKEN:+set}"' \
    _ "$TMP/run.sh" "$TMP/pre.sh" "$TMP/post.sh" 2>&1
}

out="$(run "")"
log="$(cat "$TMP/docker.log")"
check "re-run without the file calls bin/admin-token in the image" 'grep -q "ghcr.io/frikkern/barkpark:9.9.9 bin/admin-token --label admin (deploy.sh re-run) --file $TMP/etc/admin-token$" <<<"$log"'
check "the mint runs as root with the token directory mounted" 'grep -q -- "-u 0 -v $TMP/etc:$TMP/etc " <<<"$log"'
check "the mint gets the .env and the host network" 'grep -q -- "--network host --env-file /opt/barkpark/.env" <<<"$log"'
check "re-run picks up the id" 'grep -q "^ID=11111111-2222-3333-4444-555555555555 TOKEN=set$" <<<"$out"'
check "the token value is not printed" '! grep -q bp_admin_fake <<<"$out"'

out="$(run "")"
check "a second re-run finds the file and does not mint" '[ ! -s "$TMP/docker.log" ] && grep -q "TOKEN=set" <<<"$out"'

rm -rf "${TMP:?}/etc"
out="$(run 1)"
check "a fresh box mints in the seed, not the recovery command" '[ ! -s "$TMP/docker.log" ] && [ -s "$TMP/etc/admin-token" ]'

rm -rf "${TMP:?}/etc"
out="$(run "" BARKPARK_SEED_PROFILE=demo)"
check "the demo profile does not mint" '[ ! -s "$TMP/docker.log" ]'

out="$(run "" MINT_FAIL=1)"; rc=$?
check "a failed mint does not stop the run" '[ "$rc" -eq 0 ] && grep -q "docker exec barkpark bin/admin-token" <<<"$out"'

if [ "$fails" -ne 0 ]; then echo "deploy-admin-token-recovery: $fails failed"; exit 1; fi
echo "deploy-admin-token-recovery: all checks passed"
