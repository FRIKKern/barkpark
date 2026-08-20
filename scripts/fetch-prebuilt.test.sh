#!/usr/bin/env bash
# Hermetic safety regression for fetch-prebuilt.sh. No real network, artifact
# swap, rebuild, or service command is allowed to run.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

TMP="$(mktemp -d)"
cleanup() { find "$TMP" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

make_repo() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/api/_build/prod" "$root/api/deps"
  cp -f "$HERE/fetch-prebuilt.sh" "$root/scripts/"
  cp -f "$HERE/apply-update.sh" "$root/scripts/"
  cp -f "$HERE/deploy-rebuild.sh" "$root/scripts/"
  printf 'prod-sentinel\n' > "$root/api/_build/prod/SENTINEL"
  printf 'deps-sentinel\n' > "$root/api/deps/SENTINEL"
}

make_fakes() {
  local dir="$1"
  mkdir -p "$dir"

  cat > "$dir/git" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "rev-parse" ] && { echo deadbeef; exit 0; }
exit 1
EOF

  local name
  for name in curl zstd tar sha256sum flock mv find systemctl sudo make; do
    cat > "$dir/$name" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$DANGER_LOG"
exit 97
EOF
  done
  chmod +x "$dir"/*
}

snapshot() {
  shasum -a 256 \
    "$1/api/_build/prod/SENTINEL" \
    "$1/api/deps/SENTINEL"
}

run_script() {
  local root="$1" script="$2" out="$3"
  shift 3
  env PATH="$FAKE:/usr/bin:/bin" DANGER_LOG="$DANGER_LOG" \
    bash "$root/scripts/$script" "$@" > "$out" 2>&1
}

FAKE="$TMP/fakebin"
make_fakes "$FAKE"
DANGER_LOG="$TMP/danger.log"

echo "== slot layout: direct fetch refuses before every side effect =="
DIRECT="$TMP/direct"
make_repo "$DIRECT"
mkdir -p "$DIRECT/.slots"
before="$(snapshot "$DIRECT")"
: > "$DANGER_LOG"
run_script "$DIRECT" fetch-prebuilt.sh "$TMP/direct.out" deadbeef
rc=$?
check "direct exit is typed 3" "[ '$rc' = 3 ]"
check "direct message names blue/green deployer" \
  "grep -qF '[fetch-prebuilt] blue/green slot layout detected — use deploy/instance-deploy.sh' '$TMP/direct.out'"
check "direct dangerous-command log is empty" "[ ! -s '$DANGER_LOG' ]"
check "direct sentinels are byte-identical" "[ \"\$(snapshot '$DIRECT')\" = \"$before\" ]"

echo "== slot layout: apply-update caller also fails closed =="
CALLER="$TMP/caller"
make_repo "$CALLER"
mkdir -p "$CALLER/.slots"
before="$(snapshot "$CALLER")"
: > "$DANGER_LOG"
run_script "$CALLER" apply-update.sh "$TMP/caller.out"
rc=$?
check "caller exit is typed 3" "[ '$rc' = 3 ]"
check "caller surfaces the fetch-prebuilt slot refusal" \
  "grep -qF '[fetch-prebuilt] blue/green slot layout detected — use deploy/instance-deploy.sh' '$TMP/caller.out'"
check "caller dangerous-command log is empty" "[ ! -s '$DANGER_LOG' ]"
check "caller sentinels are byte-identical" "[ \"\$(snapshot '$CALLER')\" = \"$before\" ]"

echo "== non-slot behavior remains unchanged =="
PLAIN="$TMP/plain"
make_repo "$PLAIN"
: > "$DANGER_LOG"
run_script "$PLAIN" fetch-prebuilt.sh "$TMP/usage.out"
rc=$?
check "no-argument invocation remains exit 1" "[ '$rc' = 1 ]"
check "no-argument invocation keeps usage text" \
  "grep -qF '[fetch-prebuilt] usage: fetch-prebuilt.sh <sha>' '$TMP/usage.out'"
check "usage path invokes no dangerous command" "[ ! -s '$DANGER_LOG' ]"

: > "$DANGER_LOG"
run_script "$PLAIN" fetch-prebuilt.sh "$TMP/fallback.out" deadbeef
rc=$?
check "unavailable artifact remains exit 1" "[ '$rc' = 1 ]"
check "unavailable artifact keeps fallback text" \
  "grep -qF '[fetch-prebuilt] fallback to on-box compile:' '$TMP/fallback.out'"
check "non-slot path reached only the fake curl" \
  "[ \"\$(wc -l < '$DANGER_LOG' | tr -d ' ')\" = 1 ] && grep -q '^curl ' '$DANGER_LOG'"

if [ "$fails" -ne 0 ]; then
  echo "fetch-prebuilt tests: $fails failure(s)" >&2
  exit 1
fi
echo "fetch-prebuilt tests: PASS"
