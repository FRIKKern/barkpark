#!/usr/bin/env bash
#
# build-prebuilt.sh — compile the prod api/_build ONCE in CI and package it as a
# precompiled artifact so boxes never compile at deploy time (task
# precompiled-artifacts). Runs in the CI runner on a FRESH checkout, so the
# clean-from-scratch build honors Golden Rule #1 — the box just SWAPS the result
# in instead of recompiling.
#
# Output (into $1, default ./artifact):
#   api-build.tar.zst          — tar(api/_build/prod + api/deps), zstd-compressed
#   api-build.tar.zst.sha256   — its checksum (the box verifies before swapping)
#   stamp.json                 — {sha, elixir, otp, erts, arch}: the EXACT runtime
#                                this build is valid for. The box applies the
#                                artifact ONLY on an exact stamp match, else it
#                                falls back to an on-box compile (never worse).
#
# The runner MUST have the repo-pinned OTP+Elixir (.tool-versions) installed and
# `zstd` available.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-artifact}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

SHA="$(git rev-parse HEAD)"

command -v zstd >/dev/null || { echo "build-prebuilt: zstd is required" >&2; exit 1; }

echo "[build-prebuilt] compiling api/ (MIX_ENV=prod, clean checkout) for $SHA"
(
  cd api
  export MIX_ENV=prod
  mix deps.get
  mix deps.compile
  mix compile
)

# The exact runtime this compiled BEAM is valid on. The box checks all three
# (elixir, erts, arch) — erts+elixir together pin bytecode compatibility, arch
# pins the native NIFs (bcrypt, etc.).
ELIXIR_V="$(elixir --version | sed -n 's/^Elixir \([0-9][0-9.]*\).*/\1/p' | head -1)"
OTP_V="$(erl -noshell -eval 'io:fwrite("~s", [erlang:system_info(otp_release)]), halt().')"
ERTS_V="$(erl -noshell -eval 'io:fwrite("~s", [erlang:system_info(version)]), halt().')"
ARCH="$(uname -m)"

cat > "$OUT/stamp.json" <<JSON
{"sha":"$SHA","elixir":"$ELIXIR_V","otp":"$OTP_V","erts":"$ERTS_V","arch":"$ARCH"}
JSON

# Package the compiled build + the dep sources (mix wants deps/ present at boot
# even though it runs the compiled ebin). Include the stamp INSIDE too, so the
# extracted tree is self-describing.
cp "$OUT/stamp.json" api/_build/prod/.barkpark-stamp.json
tar -C api -cf - _build/prod deps | zstd -15 -T0 -f -o "$OUT/api-build.tar.zst"
rm -f api/_build/prod/.barkpark-stamp.json

sha256sum "$OUT/api-build.tar.zst" | cut -d' ' -f1 > "$OUT/api-build.tar.zst.sha256"

echo "[build-prebuilt] packaged $OUT/api-build.tar.zst"
echo "[build-prebuilt] stamp: $(cat "$OUT/stamp.json")"
echo "[build-prebuilt] size:  $(du -h "$OUT/api-build.tar.zst" | cut -f1)"
