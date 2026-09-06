#!/usr/bin/env bash
# deploy-rebuild.test.sh — hermetic behavior matrix for scripts/deploy-rebuild.sh.
#
# NO real mix, systemd, network, or service is allowed to run: the engine is
# executed in a throwaway repo with every dangerous command faked on PATH, in
# the fetch-prebuilt.test.sh idiom. The arms this file exists to keep red-able
# (task-273d965359c14e7d — the dooodo 0.2.26 crashloop):
#
#   1. ecto.migrate RUNS, on the NEW code (MIX_BUILD_ROOT=_build_next), while
#      the OLD build is still in api/_build/prod (pre-swap) and BEFORE any
#      `systemctl restart barkpark` — deleting the migrate line must red here.
#   2. a FAILED migrate fails CLOSED: exit 13, the swap never happens (old
#      sentinel still serving), NO restart, and the status record says
#      phase=migrate outcome=failed.
#   3. a successful run's pre-restart record says phase=restart outcome=applied
#      (the flight-recorder contract: written BEFORE the restart line, because
#      the restart SIGTERMs the engine's own cgroup and nothing after it runs).
#   4. a failed BUILD keeps its historical semantics: exit 1, no migrate, no
#      swap, no restart — and now also records phase=build outcome=failed.
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
  mkdir -p "$root/scripts" "$root/api/_build/prod"
  cp -f "$HERE/deploy-rebuild.sh" "$root/scripts/"
  printf 'old-build\n' > "$root/api/_build/prod/SENTINEL"
}

# Fakes. Every invocation is appended to CALL_LOG so ORDER is assertable.
# The fake mix:
#   * logs the build root AND what api/_build/prod is serving at call time,
#     so "migrate ran on the new code while the old build was still in place"
#     is a single grep, not an inference;
#   * `compile` materializes $MIX_BUILD_ROOT/prod with a new-build sentinel
#     (what the real compile does, minimally) so the engine's mv can succeed;
#   * `ecto.migrate` exits $FAKE_MIGRATE_RC (default 0);
#   * `compile` exits $FAKE_COMPILE_RC (default 0).
make_fakes() {
  local dir="$1"
  mkdir -p "$dir"

  cat > "$dir/mix" <<'EOF'
#!/usr/bin/env bash
serving="$(cat _build/prod/SENTINEL 2>/dev/null || echo none)"
echo "mix $* root=${MIX_BUILD_ROOT:-unset} serving=$serving" >> "$CALL_LOG"
case "${1:-}" in
  compile)
    rc="${FAKE_COMPILE_RC:-0}"
    if [ "$rc" = 0 ]; then
      mkdir -p "${MIX_BUILD_ROOT:-_build}/prod"
      printf 'new-build\n' > "${MIX_BUILD_ROOT:-_build}/prod/SENTINEL"
    fi
    exit "$rc" ;;
  ecto.migrate) exit "${FAKE_MIGRATE_RC:-0}" ;;
esac
exit 0
EOF

  cat > "$dir/git" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "rev-parse" ] && { echo deadbeefcafe; exit 0; }
echo "git $*" >> "$CALL_LOG"
exit 0
EOF

  # systemctl: log every call; report the barkpark unit ACTIVE so the engine
  # takes its restart arm (via the fake sudo, which re-dispatches to this fake).
  cat > "$dir/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALL_LOG"
exit 0
EOF

  cat > "$dir/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALL_LOG"
exec "$@"
EOF

  # curl: the POST-RESTART HEALTH PROBE (the engine's "restarted and answering"
  # claim descends from this, not from systemctl's acceptance). Answers 200 by
  # default so the happy path stays happy; FAKE_HTTP_CODE flips it for the
  # RESTART UNVERIFIED arm below. A `-w %{http_code}` curl prints the code on
  # stdout, which is what the engine reads.
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$CALL_LOG"
code="${FAKE_HTTP_CODE:-200}"
[ "$code" = "dead" ] && exit 7
printf '%s' "$code"
exit 0
EOF

  # flock: macOS has no flock(1); the engine only needs it to succeed.
  # go/make/install: the non-fatal arms — log and succeed, build nothing.
  local name
  for name in flock go make install; do
    cat > "$dir/$name" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$CALL_LOG"
exit 0
EOF
  done
  chmod +x "$dir"/*
}

# The engine prepends /root/.asdf/... and /usr/local/go/bin to PATH; the fake
# dir stays ahead of /usr/bin:/bin for everything we fake, and a host's real
# /usr/local/go/bin/go would only feed the engine's NON-FATAL go arms — but the
# assertions below never depend on the go/make lines, only on mix + systemctl.
run_engine() {
  local root="$1" out="$2"
  shift 2
  env PATH="$FAKE:/usr/bin:/bin" CALL_LOG="$CALL_LOG" "$@" \
    bash "$root/scripts/deploy-rebuild.sh" > "$out" 2>&1
}

line_no() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }

FAKE="$TMP/fakebin"
make_fakes "$FAKE"
CALL_LOG="$TMP/calls.log"

echo "== happy path: migrate on new code, pre-swap, pre-restart; record says applied =="
HAPPY="$TMP/happy"
make_repo "$HAPPY"
: > "$CALL_LOG"
run_engine "$HAPPY" "$TMP/happy.out"
rc=$?
check "exit 0" "[ '$rc' = 0 ]"
check "ecto.migrate ran" "grep -q '^mix ecto.migrate ' '$CALL_LOG'"
check "migrate ran on the NEW code (root=_build_next)" \
  "grep -q '^mix ecto.migrate root=_build_next ' '$CALL_LOG'"
check "migrate ran BEFORE the swap (old build still serving at migrate time)" \
  "grep -q '^mix ecto.migrate .* serving=old-build$' '$CALL_LOG'"
mig="$(line_no "$CALL_LOG" '^mix ecto.migrate ')"
res="$(line_no "$CALL_LOG" '^sudo systemctl restart barkpark$')"
check "service restart happened" "[ -n '$res' ]"
check "migrate ran BEFORE the restart" "[ -n '$mig' ] && [ -n '$res' ] && [ '$mig' -lt '$res' ]"
check "swap happened (new build serving)" \
  "[ \"\$(cat '$HAPPY/api/_build/prod/SENTINEL')\" = new-build ]"
check "status record exists" "[ -f '$HAPPY/.deploy-status.json' ]"
check "record says phase=restart outcome=applied (written pre-restart)" \
  "grep -q '\"phase\":\"restart\",\"outcome\":\"applied\"' '$HAPPY/.deploy-status.json'"
check "record carries the sha" "grep -q '\"sha\":\"deadbeefcafe\"' '$HAPPY/.deploy-status.json'"
check "the post-restart health probe was actually TAKEN" \
  "grep -q '^curl .*api/schemas' '$CALL_LOG'"
check "the probe ran AFTER the restart" \
  "[ \"\$(line_no '$CALL_LOG' '^curl ')\" -gt \"\$(line_no '$CALL_LOG' '^sudo systemctl restart barkpark$')\" ]"
check "the receipt cites the measured 200, not systemd's acceptance" \
  "grep -qF 'Done. Service restarted and answering' '$TMP/happy.out'"

echo "== restart accepted, app never answers: typed exit 15, NO 'restarted' claim =="
UNVER="$TMP/unverified"
make_repo "$UNVER"
: > "$CALL_LOG"
run_engine "$UNVER" "$TMP/unverified.out" FAKE_HTTP_CODE=dead BP_HEALTH_ATTEMPTS=2 BP_HEALTH_SLEEP=0
rc=$?
check "exit is the typed restart-unverified 15" "[ '$rc' = 15 ]"
check "the restart WAS issued (fixture control — this is not a build failure)" \
  "grep -q '^sudo systemctl restart barkpark$' '$CALL_LOG'"
check "the swap still happened (the new build IS installed)" \
  "[ \"\$(cat '$UNVER/api/_build/prod/SENTINEL')\" = new-build ]"
check "it does NOT claim the service is up" \
  "! grep -qF 'Service restarted and answering' '$TMP/unverified.out'"
check "it names the unverified restart" \
  "grep -qF 'RESTART UNVERIFIED' '$TMP/unverified.out'"
check "the record says phase=restart outcome=unverified" \
  "grep -q '\"phase\":\"restart\",\"outcome\":\"unverified\"' '$UNVER/.deploy-status.json'"

echo "== failed migrate: exit 13, NO swap, NO restart, record says migrate failed =="
MIGFAIL="$TMP/migfail"
make_repo "$MIGFAIL"
: > "$CALL_LOG"
run_engine "$MIGFAIL" "$TMP/migfail.out" FAKE_MIGRATE_RC=7
rc=$?
check "exit is typed 13" "[ '$rc' = 13 ]"
check "old build still serving (swap aborted)" \
  "[ \"\$(cat '$MIGFAIL/api/_build/prod/SENTINEL')\" = old-build ]"
check "NO service restart" "! grep -q 'systemctl restart barkpark' '$CALL_LOG'"
check "failure message says old code keeps serving" \
  "grep -qF 'MIGRATE FAILED — swap aborted; api/_build/prod (old code) is untouched and keeps serving. NOT restarting.' '$TMP/migfail.out'"
check "record says phase=migrate outcome=failed" \
  "grep -q '\"phase\":\"migrate\",\"outcome\":\"failed\"' '$MIGFAIL/.deploy-status.json'"

echo "== failed build: exit 1, NO migrate, NO swap, NO restart, record says build failed =="
BUILDFAIL="$TMP/buildfail"
make_repo "$BUILDFAIL"
: > "$CALL_LOG"
run_engine "$BUILDFAIL" "$TMP/buildfail.out" FAKE_COMPILE_RC=1
rc=$?
check "exit is typed 1" "[ '$rc' = 1 ]"
check "NO migrate after a failed build" "! grep -q '^mix ecto.migrate ' '$CALL_LOG'"
check "old build still serving" \
  "[ \"\$(cat '$BUILDFAIL/api/_build/prod/SENTINEL')\" = old-build ]"
check "NO service restart" "! grep -q 'systemctl restart barkpark' '$CALL_LOG'"
check "record says phase=build outcome=failed" \
  "grep -q '\"phase\":\"build\",\"outcome\":\"failed\"' '$BUILDFAIL/.deploy-status.json'"

echo "== slot box: typed refusal before any side effect (unchanged contract) =="
SLOT="$TMP/slot"
make_repo "$SLOT"
mkdir -p "$SLOT/.slots"
: > "$CALL_LOG"
run_engine "$SLOT" "$TMP/slot.out"
rc=$?
check "exit is typed 3" "[ '$rc' = 3 ]"
check "no command ran" "[ ! -s '$CALL_LOG' ]"
check "no status record on a refused box" "[ ! -f '$SLOT/.deploy-status.json' ]"

if [ "$fails" -ne 0 ]; then
  echo "deploy-rebuild tests: $fails failure(s)" >&2
  exit 1
fi
echo "deploy-rebuild tests: PASS"
