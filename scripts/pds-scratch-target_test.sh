#!/usr/bin/env bash
# Offline test for scripts/pds-scratch-target.sh — drives the REAL verbs
# (env / status / teardown) against two fake scratch roots, with a stub
# `barkpark` binary so nothing real is ever stopped. Modelled on
# deploy/instance-deploy_test.sh.
#
# WHAT IT PINS (PDS-D318 — the strand, reproduced end to end before the fix):
#   - two live roots BOTH stay resolvable: a second `up` no longer clobbers the
#     one global pointer, because the REGISTRY has one entry per root
#   - with two live, the read verbs REFUSE WITH A LIST instead of silently
#     picking the most recent one (the pick is what stranded the other)
#   - tearing down one root leaves the OTHER reachable by every verb with no
#     BARKPARK_HOME set — this is the exact line the pre-fix script failed:
#     `env`/`status`/`teardown` all died with "no scratch target known" while
#     root A was still standing, fully live
#   - teardown NAMES the survivors with their ports, and scopes its glob count
#     to "under the default /tmp/pds.* pattern" rather than claiming "all"
#   - the registry prunes an entry whose root vanished, so the map cannot lie
#
# HOW `up` IS SIMULATED: `up` needs mix + a full prod compile, so it is not run.
# The test writes exactly what `up` writes as its map update — the one-line
# pointer write AND the one-line registry entry (content = the canonical root,
# which is how registry entries are matched) — plus a scratch.env of the same
# shape. Every OTHER verb under test is the real one, unmodified.
#
# NO CI COVERAGE: nothing under .github/workflows runs scripts/pds-*. This is a
# LOCAL harness test. Run it by hand:  bash scripts/pds-scratch-target_test.sh
#
# PDS_SCRATCH_TEST_SCRIPT points the whole file at a different copy of the
# script — that is how the pre-fix demonstration is taken (point it at
# `git show HEAD:scripts/pds-scratch-target.sh` and watch these cases go RED).

set -uo pipefail

HERE="$(cd -P -- "$(dirname -- "$0")" && pwd)"
SCRIPT="${PDS_SCRATCH_TEST_SCRIPT:-$HERE/pds-scratch-target.sh}"

fails=0
pass() { printf '  PASS: %s\n' "$*"; }
fail() { printf '  FAIL: %s\n' "$*"; fails=$((fails + 1)); }
hr()   { printf -- '---- %s\n' "$*"; }

contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

check_contains() { # $1 label · $2 needle · $3 haystack
  if contains "$2" "$3"; then pass "$1"; else fail "$1 — '$2' not found in output"; fi
}
check_lacks() { # $1 label · $2 needle · $3 haystack
  if contains "$2" "$3"; then fail "$1 — '$2' IS present in output"; else pass "$1"; fi
}
check_eq() { # $1 label · $2 expected · $3 actual
  if [ "$2" = "$3" ]; then pass "$1 ($3)"; else fail "$1 — expected '$2', got '$3'"; fi
}

[ -f "$SCRIPT" ] || { printf 'no script at %s\n' "$SCRIPT" >&2; exit 2; }

TMP="$(mktemp -d /tmp/pds-st.XXXX)"
trap '[ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"' EXIT

# The registry is derived from the pointer, so pinning the pointer into $TMP
# keeps this whole test off the host's real /tmp/pds-scratch-target.last map.
export PDS_SCRATCH_POINTER="$TMP/pointer.last"
REGISTRY_DIR="$PDS_SCRATCH_POINTER.d"

# A stub `barkpark`. teardown calls `$BARKPARK_BIN stop`, whose real form falls
# back to killing whatever listens on $PORT — the last thing a test may do.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/barkpark" <<'STUB'
#!/usr/bin/env bash
printf 'stub-barkpark %s (BARKPARK_HOME=%s PORT=%s)\n' "$1" "${BARKPARK_HOME:-}" "${PORT:-}"
exit 0
STUB
chmod +x "$TMP/bin/barkpark"
export PDS_SCRATCH_BARKPARK_BIN="$TMP/bin/barkpark"

# Two ports nothing is listening on — teardown asserts both are released, and a
# port that some other process happens to hold would fail that assert honestly.
free_test_port() {
  local p i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    p=$(( 39000 + (RANDOM % 9000) ))
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 || { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# Everything `up` leaves behind for a later shell: the root, its scratch.env,
# the pointer (clobbered, exactly as `up` does) and its registry entry.
make_root() { # $1 = name  -> prints the canonical root
  local root canon port pg
  root="$TMP/$1"
  mkdir -p "$root/media"
  canon="$(cd -P -- "$root" && pwd)"
  port="$(free_test_port)" || { printf 'no free port\n' >&2; exit 2; }
  pg="$(free_test_port)"   || { printf 'no free port\n' >&2; exit 2; }
  cat > "$canon/scratch.env" <<EOF
# sourceable handle on this scratch personal-local target
export BARKPARK_HOME="$canon"
export BARKPARK_MEDIA_DIR="$canon/media"
export BARKPARK_PG_PORT="$pg"
export PORT="$port"
export PHX_HOST="localhost"
export PDS_SCRATCH_BASE="http://localhost:$port"
export PDS_SCRATCH_TOKEN="pds-scratch-fake"
export PDS_SCRATCH_TREE="$HERE/.."
export PDS_SCRATCH_DB="host=127.0.0.1 port=$pg dbname=barkpark user=barkpark"
EOF
  # `up`'s map update, verbatim in shape: the unconditional pointer write…
  printf '%s\n' "$canon" > "$PDS_SCRATCH_POINTER"
  # …and the registry entry (matched by CONTENT, so any filename is legal).
  mkdir -p "$REGISTRY_DIR"
  printf '%s\n' "$canon" > "$REGISTRY_DIR/$(printf '%s' "$canon" | cksum | awk '{print $1}')"
  printf '%s\n' "$canon"
}

port_of() { sed -n 's/^export PORT="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$1/scratch.env" | tail -1; }

printf 'pds-scratch-target_test — script under test: %s\n\n' "$SCRIPT"

# ── 1 · two live roots, and the read verbs refuse to guess ───────────────────
hr "1. two concurrent roots — the second up must not erase the first"
A="$(make_root rootA)"
B="$(make_root rootB)"
PORT_A="$(port_of "$A")"
PORT_B="$(port_of "$B")"
printf '  root A %s (PORT=%s)\n  root B %s (PORT=%s)\n' "$A" "$PORT_A" "$B" "$PORT_B"

out="$(bash "$SCRIPT" env 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  pass "with two live roots, \`env\` refuses instead of silently picking one (exit $rc)"
else
  fail "with two live roots, \`env\` picked one and exited 0 — this is the clobber: $(printf '%s' "$out" | head -3)"
fi
check_contains "the refusal names root A"        "$A"      "$out"
check_contains "the refusal names root B"        "$B"      "$out"
check_contains "the refusal carries A's port"    "PORT=$PORT_A" "$out"
check_contains "the refusal carries B's port"    "PORT=$PORT_B" "$out"
check_contains "the refusal says how to pick"    "BARKPARK_HOME=<root>" "$out"

# ── 2 · an explicit caller still wins ────────────────────────────────────────
hr "2. BARKPARK_HOME still resolves explicitly"
out="$(BARKPARK_HOME="$A" bash "$SCRIPT" env 2>&1)"; rc=$?
check_eq       "explicit \`env\` on root A exits 0" "0" "$rc"
check_contains "…and prints A's scratch.env"        "PORT=\"$PORT_A\"" "$out"

# ── 3 · tearing down B names the survivor instead of emptying the map ────────
hr "3. teardown of B — PASS, and the survivor is named with its port"
out="$(BARKPARK_HOME="$B" bash "$SCRIPT" teardown 2>&1)"; rc=$?
check_eq       "teardown of B exits 0"           "0" "$rc"
check_contains "teardown of B reports PASS"      "teardown: PASS" "$out"
if [ -d "$B" ]; then fail "root B still exists after teardown"; else pass "root B is gone"; fi
if [ -d "$A" ]; then pass "root A is untouched"; else fail "teardown of B removed root A"; fi
check_contains "teardown names the surviving root A"     "$A" "$out"
check_contains "…with its HTTP port"                     "PORT=$PORT_A" "$out"
check_contains "…and scopes the glob claim to the default pattern" \
               "under the default /tmp/pds.* pattern" "$out"
glob_line="$(printf '%s\n' "$out" | grep 'default /tmp/pds' || true)"
check_lacks    "…without claiming it counted ALL roots"  " all " "$glob_line"

# ── 4 · THE STRAND: the survivor is reachable by every verb, no env var ──────
hr "4. the survivor stays reachable with NO BARKPARK_HOME (the pre-fix strand)"
out="$(bash "$SCRIPT" env 2>&1)"; rc=$?
check_eq       "\`env\` resolves the survivor (exit 0)" "0" "$rc"
check_lacks    "…and does NOT say 'no scratch target known'" "no scratch target known" "$out"
check_contains "…it is root A's env"                    "PORT=\"$PORT_A\"" "$out"

out="$(bash "$SCRIPT" status 2>&1)"; rc=$?
check_eq       "\`status\` resolves the survivor (exit 0)" "0" "$rc"
check_contains "…and prints root A"                       "root:  $A" "$out"
check_contains "…reaching the (stubbed) barkpark binary"  "stub-barkpark status" "$out"

# `verify` is NOT driven here: its body needs a booted server and a MIX_ENV=dev
# `mix run`, which this offline test will not pay. What IS pinned is that it
# resolves through the SAME code path proven above — a STRUCTURAL check, and it
# is labelled as one rather than dressed up as a live proof.
# (grep -c, not grep -q: -q closes the pipe early, and under `pipefail` sed's
# SIGPIPE would then fail the test for a reason that has nothing to do with it.)
if [ "$(sed -n '/^cmd_verify()/,/^}/p' "$SCRIPT" | grep -c 'load_scratch_env' || true)" -ge 1 ]; then
  pass "STRUCTURAL: cmd_verify resolves via load_scratch_env -> resolve_home (its body is not driven offline)"
else
  fail "cmd_verify no longer resolves through load_scratch_env — its resolution is unproven here"
fi

# ── 5 · the last teardown, with no env var, and an honest empty state ────────
hr "5. teardown resolves the survivor too, then says the map is empty"
out="$(bash "$SCRIPT" teardown 2>&1)"; rc=$?
check_eq       "\`teardown\` with no BARKPARK_HOME exits 0" "0" "$rc"
check_contains "…and it tore down root A"                   "$A" "$out"
if [ -d "$A" ]; then fail "root A still exists after its teardown"; else pass "root A is gone"; fi
check_contains "…and reports no other registered target"    "no other scratch target is registered live" "$out"

out="$(bash "$SCRIPT" env 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then pass "with nothing live, \`env\` says so (exit $rc)"; else fail "\`env\` exited 0 with no live root"; fi
check_contains "…in the documented words"  "no scratch target known" "$out"

# ── 6 · the map prunes what vanished ─────────────────────────────────────────
hr "6. a root removed by hand is pruned from the registry, not reported live"
C="$(make_root rootC)"
D="$(make_root rootD)"
rm -rf "$D"
out="$(bash "$SCRIPT" env 2>&1)"; rc=$?
check_eq       "with one of two roots gone by hand, \`env\` resolves the other" "0" "$rc"
check_contains "…and it is root C"  "BARKPARK_HOME=\"$C\"" "$out"
check_lacks    "…root D is not offered" "$D" "$out"

printf '\n'
hr "$fails failure(s)"
if [ "$fails" -eq 0 ]; then
  printf 'SCRATCH TEST PASSED — two roots coexist, teardown names the survivor, and no verb strands it.\n'
  exit 0
fi
printf 'SCRATCH TEST FAILED (%d)\n' "$fails"
exit 1
