#!/usr/bin/env bash
#
# fetch-prebuilt.sh <sha> — box-side: fetch + swap the CI-precompiled build for
# <sha> IF it exactly matches this box's runtime, so a deploy is a fast fetch +
# swap instead of a ~3-minute on-box compile (task precompiled-artifacts).
#
# Exit 0  — the box now runs the precompiled build for <sha> (no compile).
# Exit 1  — ANY reason to fall back to an on-box compile: no artifact for the sha
#           (404, CI hasn't finished / api unchanged), a runtime-stamp mismatch,
#           a checksum failure, or an extract/swap error. The caller
#           (apply-update.sh) then runs deploy-rebuild.sh — so this is NEVER worse
#           than compiling; it only ever makes the happy path fast.
# Exit 3  — blue/green slot layout detected; the slot deployer owns all writes.
#
# The stamp gate is the safety core: a build compiled on a different Elixir/erts/
# arch than this box is REFUSED (bytecode/NIF incompatibility), never swapped in.
set -uo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"

if [ -d "$REPO/.slots" ]; then
  echo "[fetch-prebuilt] blue/green slot layout detected — use deploy/instance-deploy.sh" >&2
  exit 3
fi

SHA="${1:-}"
[ -n "$SHA" ] || { echo "[fetch-prebuilt] usage: fetch-prebuilt.sh <sha>" >&2; exit 1; }

REPO_SLUG="${BARKPARK_ARTIFACT_REPO:-FRIKKern/barkpark}"
BASE="https://github.com/$REPO_SLUG/releases/download/build-$SHA"

export PATH="/root/.asdf/bin:/root/.asdf/shims:$PATH"
[ -f /root/.asdf/asdf.sh ] && . /root/.asdf/asdf.sh 2>/dev/null || true

fallback() { echo "[fetch-prebuilt] fallback to on-box compile: $*" >&2; exit 1; }

command -v zstd >/dev/null 2>&1 || fallback "zstd not installed"
command -v curl >/dev/null 2>&1 || fallback "curl not installed"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. Fetch the tiny stamp FIRST — a cheap 404 / mismatch check before the big tar.
curl -fsSL --retry 2 "$BASE/stamp.json" -o "$tmp/stamp.json" 2>/dev/null \
  || fallback "no precompiled artifact for $SHA (404 — api unchanged, or CI not done)"

# 2. Gate on an EXACT runtime match (elixir + erts + arch). A stamp field the box
# can't read → treat as mismatch (fall back) rather than risk a bad swap.
stamp_get() { python3 -c "import json;print(json.load(open('$tmp/stamp.json')).get('$1',''))" 2>/dev/null; }
box_elixir="$(elixir --version 2>/dev/null | sed -n 's/^Elixir \([0-9][0-9.]*\).*/\1/p' | head -1)"
box_erts="$(erl -noshell -eval 'io:fwrite("~s",[erlang:system_info(version)]),halt().' 2>/dev/null)"
box_arch="$(uname -m)"

[ "$(stamp_get sha)" = "$SHA" ] || fallback "stamp sha mismatch"
[ -n "$box_elixir" ] && [ "$(stamp_get elixir)" = "$box_elixir" ] || fallback "elixir mismatch (artifact '$(stamp_get elixir)' vs box '$box_elixir')"
[ -n "$box_erts" ] && [ "$(stamp_get erts)" = "$box_erts" ] || fallback "erts mismatch (artifact '$(stamp_get erts)' vs box '$box_erts')"
[ "$(stamp_get arch)" = "$box_arch" ] || fallback "arch mismatch (artifact '$(stamp_get arch)' vs box '$box_arch')"

# 3. Download the build + verify the checksum.
curl -fsSL --retry 2 "$BASE/api-build.tar.zst" -o "$tmp/api-build.tar.zst" 2>/dev/null || fallback "artifact download failed"
curl -fsSL --retry 2 "$BASE/api-build.tar.zst.sha256" -o "$tmp/want.sha256" 2>/dev/null || fallback "checksum fetch failed"
have="$(sha256sum "$tmp/api-build.tar.zst" | cut -d' ' -f1)"
[ "$have" = "$(cat "$tmp/want.sha256")" ] || fallback "checksum mismatch"

# 4. Extract aside, then swap — under the SAME repo-local lock deploy-rebuild uses
# (ONE writer of api/_build at a time). Any failure here falls back to a compile.
mkdir -p "$tmp/x"
zstd -dc "$tmp/api-build.tar.zst" 2>/dev/null | tar -C "$tmp/x" -xf - 2>/dev/null || fallback "extract failed"
[ -d "$tmp/x/_build/prod" ] && [ -d "$tmp/x/deps" ] || fallback "artifact missing _build/prod or deps"

exec 8>"$REPO/.deploy-build.lock"
flock 8

rm -rf api/_build/prod.old api/deps.old
[ -d api/_build/prod ] && mv api/_build/prod api/_build/prod.old
[ -d api/deps ] && mv api/deps api/deps.old
mkdir -p api/_build
mv "$tmp/x/_build/prod" api/_build/prod
mv "$tmp/x/deps" api/deps

# Make the compiled artifacts NEWER than the (already ff'd) sources so mix's
# mtime check reads "up to date" and `mix phx.server` boots WITHOUT recompiling.
# (Digests already match — same sha — so even without this it would not truly
# recompile; the touch just skips the digest re-check.)
find api/_build/prod api/deps -exec touch {} + 2>/dev/null || true
rm -rf api/_build/prod.old api/deps.old

echo "[fetch-prebuilt] applied precompiled build for $SHA — no on-box compile"

# 5. Restart LAST (mirrors deploy-rebuild: nothing meaningful after the restart).
if systemctl is-active barkpark >/dev/null 2>&1; then
  echo "[fetch-prebuilt] restarting barkpark..."
  sudo systemctl restart barkpark
  echo "[fetch-prebuilt] done."
else
  echo "[fetch-prebuilt] barkpark not running; start with: systemctl start barkpark"
fi
exit 0
