#!/usr/bin/env bash
# check() evals its condition later, so single quotes and "unused" vars are intended.
# shellcheck disable=SC2016,SC2034
# Runs deploy.sh's barkpark_image block, sliced out of deploy.sh itself, with a
# fake `docker` and `git`, in both modes:
#   image        BARKPARK_IMAGE, or the release :latest names, or the ref a
#                re-run finds in image.env; pulled from the registry.
#   from source  BARKPARK_FROM_SOURCE=<ref>: a git fetch of that ref and a
#                docker build of api/Dockerfile, with no registry call at all.
# It also pins the media move for a VM from the source build, and that the
# systemd unit runs the ref in image.env.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fails=$((fails + 1)); fi; }

awk '/^# bp_git BEGIN$/{on=1} on{print} /^# bp_git END$/{exit}' "$ROOT/deploy.sh" > "$TMP/git.sh"
awk '/^# barkpark_image BEGIN$/{on=1} on{print} /^# barkpark_image END$/{exit}' "$ROOT/deploy.sh" > "$TMP/image.sh"
awk '/^if \[ -d "\$APP_DIR\/api\/uploads" \]/{on=1} on{print} on && /^chown -R/{exit}' "$ROOT/deploy.sh" > "$TMP/media.sh"
grep -q 'barkpark_image()' "$TMP/image.sh" || { echo "FATAL: barkpark_image not found in deploy.sh"; exit 1; }
grep -q 'bp_git()' "$TMP/git.sh" || { echo "FATAL: bp_git not found in deploy.sh"; exit 1; }
grep -q 'mv "\$APP_DIR/api/uploads"' "$TMP/media.sh" || { echo "FATAL: media move not found in deploy.sh"; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >> "$CALLS"
case "$1 $2" in
  "image inspect")
    if [ "$3" = -f ]; then printf '%s\n' "${FAKE_LABEL:-}"; exit 0; fi
    case " ${FAKE_PRESENT:-} " in *" $3 "*) exit 0 ;; esac
    exit 1 ;;
  "pull -q")
    [ -n "${FAKE_PULL_FAIL:-}" ] && { echo "Error response from daemon: unreachable" >&2; exit 1; }
    exit 0 ;;
esac
[ "$1" = build ] && [ -n "${FAKE_BUILD_FAIL:-}" ] && exit 1
exit 0
DOCKER
cat > "$TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >> "$CALLS"
case "$*" in *"rev-parse HEAD"*) echo 0123456789abcdef0123456789abcdef01234567 ;; esac
[ -n "${FAKE_FETCH_FAIL:-}" ] && [ "$1" = fetch ] && exit 128
exit 0
GIT
chmod +x "$TMP/bin/docker" "$TMP/bin/git"

# run <extra env...>: runs barkpark_image and prints BARKPARK_IMAGE and the rc.
run() {
  : > "$TMP/calls"
  env -u BARKPARK_IMAGE -u BARKPARK_FROM_SOURCE PATH="$TMP/bin:$PATH" CALLS="$TMP/calls" \
    REPO=https://github.com/FRIKKern/barkpark.git SRC_DIR="$TMP/src" IMAGE_ENV="$TMP/etc/image.env" "$@" \
    bash -c 'set -euo pipefail; . "$1"; . "$2"; rc=0; barkpark_image || rc=$?; echo "IMAGE=${BARKPARK_IMAGE:-} RC=$rc"' \
    _ "$TMP/git.sh" "$TMP/image.sh" 2>&1
}
calls() { cat "$TMP/calls"; }

echo "== image mode =="
rm -rf "${TMP:?}/etc"
out="$(run BARKPARK_IMAGE=ghcr.io/frikkern/barkpark:0.2.30)"
check "a named image is pulled and kept" 'grep -q "^IMAGE=ghcr.io/frikkern/barkpark:0.2.30 RC=0$" <<<"$out" && grep -qx "docker pull -q ghcr.io/frikkern/barkpark:0.2.30" <<<"$(calls)"'
check "image.env records the named image" '[ "$(cat "$TMP/etc/image.env")" = "BARKPARK_IMAGE=ghcr.io/frikkern/barkpark:0.2.30" ]'
check "image mode runs no git and no build" '! grep -q "^git \|^docker build" <<<"$(calls)"'

out="$(run BARKPARK_IMAGE=ghcr.io/frikkern/barkpark:0.2.30 FAKE_PRESENT=ghcr.io/frikkern/barkpark:0.2.30)"
check "an image already on the box is not pulled again" '! grep -q "pull" <<<"$(calls)" && grep -q "RC=0$" <<<"$out"'

rm -rf "${TMP:?}/etc"
out="$(run FAKE_LABEL=0.2.31)"
check "a new box with no ref takes the release :latest names" 'grep -q "^IMAGE=ghcr.io/frikkern/barkpark:0.2.31 RC=0$" <<<"$out"'
check "it pulls :latest, reads its version label and pulls that tag" 'grep -qx "docker pull -q ghcr.io/frikkern/barkpark:latest" <<<"$(calls)" && grep -q "org.opencontainers.image.version" <<<"$(calls)" && grep -qx "docker pull -q ghcr.io/frikkern/barkpark:0.2.31" <<<"$(calls)"'
check "image.env pins the version, not latest" '[ "$(cat "$TMP/etc/image.env")" = "BARKPARK_IMAGE=ghcr.io/frikkern/barkpark:0.2.31" ]'

out="$(run FAKE_LABEL=0.2.99)"
check "a re-run with no ref keeps the image in image.env" 'grep -q "^IMAGE=ghcr.io/frikkern/barkpark:0.2.31 RC=0$" <<<"$out" && ! grep -q ":latest" <<<"$(calls)" && grep -q "keeping" <<<"$out"'

out="$(run BARKPARK_IMAGE=ghcr.io/frikkern/barkpark:0.2.32)"
check "a named image replaces the one in image.env" '[ "$(cat "$TMP/etc/image.env")" = "BARKPARK_IMAGE=ghcr.io/frikkern/barkpark:0.2.32" ]'

rm -rf "${TMP:?}/etc"
out="$(run FAKE_LABEL=)"
check "a :latest with no version label fails and names BARKPARK_IMAGE" 'grep -q "RC=1$" <<<"$out" && grep -q "set BARKPARK_IMAGE" <<<"$out" && [ ! -e "$TMP/etc/image.env" ]'

out="$(run BARKPARK_IMAGE=ghcr.io/frikkern/barkpark:0.2.30 FAKE_PULL_FAIL=1)"
check "a failed pull fails the step and writes no image.env" 'grep -q "RC=1$" <<<"$out" && [ ! -e "$TMP/etc/image.env" ]'

echo "== from source =="
rm -rf "${TMP:?}/etc"
out="$(run BARKPARK_FROM_SOURCE=main BARKPARK_IMAGE=ghcr.io/frikkern/barkpark:0.2.30)"
c="$(calls)"
check "from source builds a local image named by the commit" 'grep -q "^IMAGE=barkpark:src-0123456789ab RC=0$" <<<"$out"'
check "it fetches the ref through bp_git with depth 1" 'grep -qx "git fetch -q --depth 1 https://github.com/FRIKKern/barkpark.git main" <<<"$c" && grep -qx "git -C $TMP/src checkout -q FETCH_HEAD" <<<"$c"'
check "it builds api/Dockerfile from the fetched tree" 'grep -q "^docker build -f $TMP/src/api/Dockerfile -t barkpark:src-0123456789ab --build-arg BARKPARK_BUILD_COMMIT=0123456789abcdef0123456789abcdef01234567 .* $TMP/src$" <<<"$c"'
check "from source never pulls and never names ghcr.io" '! grep -q "pull\|ghcr.io" <<<"$c"'
check "BARKPARK_FROM_SOURCE wins over BARKPARK_IMAGE" '[ "$(cat "$TMP/etc/image.env")" = "BARKPARK_IMAGE=barkpark:src-0123456789ab" ]'

out="$(run BARKPARK_FROM_SOURCE=main FAKE_PRESENT=barkpark:src-0123456789ab)"
check "a re-run of the same commit does not build again" '! grep -q "^docker build" <<<"$(calls)" && grep -q "already built" <<<"$out"'

rm -rf "${TMP:?}/etc"
out="$(run BARKPARK_FROM_SOURCE=v9.9.9 FAKE_FETCH_FAIL=1)"
check "a ref that cannot be fetched fails, names the git call and builds nothing" 'grep -q "RC=1$" <<<"$out" && grep -q "git fetch failed" <<<"$out" && ! grep -q "^docker build" <<<"$(calls)" && [ ! -e "$TMP/etc/image.env" ]'

out="$(run BARKPARK_FROM_SOURCE=main FAKE_BUILD_FAIL=1)"
check "a failed build fails the step" 'grep -q "RC=1$" <<<"$out" && [ ! -e "$TMP/etc/image.env" ]'

echo "== media move and the unit =="
APP="$TMP/app"
mkdir -p "$APP/api/uploads/ds"
printf 'x' > "$APP/api/uploads/ds/a.png"
APP_DIR="$APP" MEDIA_DIR="$APP/uploads" bash -c 'set -euo pipefail; chown() { :; }; . "$1"' _ "$TMP/media.sh" > /dev/null
check "a source-built VM's api/uploads moves to the media directory" '[ -f "$APP/uploads/ds/a.png" ] && [ ! -e "$APP/api/uploads" ]'
mkdir -p "$APP/api/uploads"
APP_DIR="$APP" MEDIA_DIR="$APP/uploads" bash -c 'set -euo pipefail; chown() { :; }; . "$1"' _ "$TMP/media.sh" > /dev/null
check "an existing media directory is never replaced" '[ -f "$APP/uploads/ds/a.png" ] && [ -d "$APP/api/uploads" ]'

unit="$(awk '/^cat > \/etc\/systemd\/system\/barkpark.service/{on=1} on{print} /^SVCEOF$/{exit}' "$ROOT/deploy.sh")"
check "the unit reads the image ref from image.env" 'grep -q "^EnvironmentFile=\$IMAGE_ENV$" <<<"$unit"'
check "the unit runs that ref with the host network, the .env and the media mount" 'grep -q "^ExecStart=/usr/bin/docker run --rm --name barkpark --network host --env-file \$APP_DIR/.env -v \$MEDIA_DIR:/app/uploads .*\\\\\${BARKPARK_IMAGE}$" <<<"$unit"'
check "docker-buildx and git are installed only for a build from source" 'grep -q "^\[ -n \"\${BARKPARK_FROM_SOURCE:-}\" \] && _pkgs=\"\$_pkgs git docker-buildx\"$" "$ROOT/deploy.sh"'

if [ "$fails" -ne 0 ]; then echo "deploy-image: $fails failed"; exit 1; fi
echo "deploy-image: all checks passed"
