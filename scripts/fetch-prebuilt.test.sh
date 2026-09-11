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

# The stamp gate is the safety core and every field build-prebuilt.sh publishes
# must be gated — including `otp`, which was published and read by nobody. These
# arms serve the stamp so the run REACHES the gate: a fake curl answers the
# stamp.json fetch (and only that) while every later curl still lands in the
# danger log, and fake elixir/erl/uname give the box a fixed, known runtime.
#
# The MATCH arm is the non-vacuous control: it proves the fixture actually walks
# past all four comparisons (it dies at the tarball download instead). The
# MISMATCH arm is mutation-proved — delete the `otp` line from fetch-prebuilt.sh
# and it fails, because the run then reaches "artifact download failed".
echo "== stamp gate: every published stamp field is gated =="

STAMP_FAKE="$TMP/stampbin"
mkdir -p "$STAMP_FAKE"
cp -f "$FAKE"/* "$STAMP_FAKE/"

cat > "$STAMP_FAKE/curl" <<'EOF'
#!/usr/bin/env bash
url=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="${2:-}"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */stamp.json)
    [ -n "$out" ] && printf '%s' "$STAMP_JSON" > "$out"
    exit 0
    ;;
esac
echo "curl $url" >> "$DANGER_LOG"
exit 97
EOF

cat > "$STAMP_FAKE/elixir" <<'EOF'
#!/usr/bin/env bash
echo "Erlang/OTP ${BOX_OTP:-27} [erts-${BOX_ERTS:-15.2.7}]"
echo "Elixir ${BOX_ELIXIR:-1.18.3} (compiled with Erlang/OTP ${BOX_OTP:-27})"
EOF

cat > "$STAMP_FAKE/erl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *otp_release*) printf '%s' "${BOX_OTP:-27}"; exit 0 ;;
  esac
done
printf '%s' "${BOX_ERTS:-15.2.7}"
EOF

cat > "$STAMP_FAKE/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${BOX_ARCH:-x86_64}"
EOF
chmod +x "$STAMP_FAKE"/*

run_stamped() {
  local root="$1" out="$2" stamp="$3"
  env PATH="$STAMP_FAKE:/usr/bin:/bin" DANGER_LOG="$DANGER_LOG" STAMP_JSON="$stamp" \
    bash "$root/scripts/fetch-prebuilt.sh" deadbeef > "$out" 2>&1
}

MATCHING='{"sha":"deadbeef","elixir":"1.18.3","otp":"27","erts":"15.2.7","arch":"x86_64"}'
OTP_OFF='{"sha":"deadbeef","elixir":"1.18.3","otp":"26","erts":"15.2.7","arch":"x86_64"}'

STAMPED="$TMP/stamped"
make_repo "$STAMPED"
before="$(snapshot "$STAMPED")"

: > "$DANGER_LOG"
run_stamped "$STAMPED" "$TMP/stamp-match.out" "$MATCHING"
rc=$?
check "CONTROL: a fully matching stamp walks PAST the gate to the download" \
  "[ '$rc' = 1 ] && grep -qF '[fetch-prebuilt] fallback to on-box compile: artifact download failed' '$TMP/stamp-match.out'"
check "CONTROL: no runtime mismatch is reported for a matching stamp" \
  "! grep -qE 'fallback to on-box compile: (elixir|otp|erts|arch|stamp sha) mismatch' '$TMP/stamp-match.out'"

: > "$DANGER_LOG"
run_stamped "$STAMPED" "$TMP/stamp-otp.out" "$OTP_OFF"
rc=$?
check "an otp mismatch falls back (exit 1)" "[ '$rc' = 1 ]"
check "an otp mismatch is NAMED as otp, not swallowed" \
  "grep -qF \"[fetch-prebuilt] fallback to on-box compile: otp mismatch (artifact '26' vs box '27')\" '$TMP/stamp-otp.out'"
check "an otp mismatch never downloads the tarball" \
  "! grep -q 'api-build.tar.zst' '$DANGER_LOG'"
check "stamp-gate arms swapped nothing" "[ \"\$(snapshot '$STAMPED')\" = \"$before\" ]"

if [ "$fails" -ne 0 ]; then
  echo "fetch-prebuilt tests: $fails failure(s)" >&2
  exit 1
fi
echo "fetch-prebuilt tests: PASS"
