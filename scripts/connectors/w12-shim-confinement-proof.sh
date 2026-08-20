#!/usr/bin/env bash
# w12-shim-confinement-proof.sh — the Connectors Wave-12 shim-confinement proof
# (D121/D122). BLACK-BOX, hermetic, provisions NO real sandbox.
#
# Wave 11 wired the `:cloud` profile; Wave 12 hardens its LOCAL boundary. The
# decisive verify finding: the remote boundary is already narrow (the turn exec
# carries EXACTLY one `--env ANTHROPIC_API_KEY` pair, and `vercel sandbox exec`
# forwards ONLY explicit `--env` pairs), but `run()` in cloud-sandbox-runner.mjs
# spawned the LOCAL `vercel` child with a FULL env inherit — a planted HOST_SECRET
# and the minted per-session BARKPARK_API_TOKEN were captured verbatim in that
# child's env. D121 adds an explicit allowlist (HOME/PATH/TMPDIR + VERCEL_*); this
# proof REVERSES the pre-fix leak and pins the launch contract.
#
# The proof drives the REAL cloud-sandbox-runner.mjs end to end with ZERO shim
# refactor (D122): `CLOUD_SANDBOX_VERCEL_BIN` points at a generated FAKE `vercel`
# that records every invocation's argv (NUL-delimited, so the multi-line in-sandbox
# script survives) and full env, and emulates just enough of create→exec→remove for
# the shim to complete. No real Vercel, no `timeout(1)` (absent on darwin — the
# shim self-terminates in <1s against the fake).
#
# Four assertions (charter D121/D122):
#   (a) the TURN exec argv carries EXACTLY one `--env` pair: ANTHROPIC_API_KEY=sk-test.
#   (b) HOST_SECRET and BARKPARK_API_TOKEN are ABSENT from every captured child env
#       (the allowlist reversing the pre-fix leak); ANTHROPIC_API_KEY too, since it
#       crosses as an explicit --env flag, never as an ambient var.
#   (c) the in-sandbox bash script isolates HOME=/tmp/bp-cloud-home + cd
#       /tmp/bp-cloud-cwd (D112).
#   (d) `--workspace global` AND a missing `--workspace` both exit 2 with ZERO
#       vercel invocations (the D110-style fail-closed principal gate, front-run).
#
# The TURN exec is located by its `-lc` argv token, NEVER by capture-file ordering:
# the no-snapshot fallback path adds an `npm i -g` exec that shifts numbering, and
# only the turn's `bash -lc <script>` carries `-lc`.
#
# See .claude/workflows/bp-connectors-charter.md (D116-D125) and the wave paper
# connectors-wave-12-2026-07-16. Sibling idioms: w11-isolated-turn-proof.sh
# (--check provisions nothing; EXIT-trap cleanup).
#
# Usage:
#   scripts/connectors/w12-shim-confinement-proof.sh --check   # lint the shim + print the plan, run NO subprocess
#   scripts/connectors/w12-shim-confinement-proof.sh           # hermetic black-box run (fake vercel; no real sandbox)
set -uo pipefail
export LC_ALL=C

SCRIPT_NAME="w12-shim-confinement-proof.sh"
CHARTER=".claude/workflows/bp-connectors-charter.md"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/cloud-sandbox-runner.mjs"

# The planted secrets that MUST be confined out of the local vercel child env.
HOST_SECRET_VAL="host-secret-must-not-leak"
BARKPARK_TOKEN_VAL="bp_tok_must_not_leak"
ANTHROPIC_KEY_VAL="sk-test"
WORKSPACE="w12-proof-ws"

CHECK_ONLY=0

usage() {
  cat <<EOF
$SCRIPT_NAME — Connectors Wave-12 shim-confinement proof (env allowlist, D121/D122).

  --check    node --check the shim, verify the allowlist markers, print the plan;
             runs NO shim subprocess and spawns NO vercel (real or fake).
  --help     this text.

With no flag it runs the HERMETIC black-box proof: a generated fake \`vercel\`
records argv+env per call, the REAL $SHIM is driven end to end with planted
HOST_SECRET/BARKPARK_API_TOKEN/ANTHROPIC_API_KEY, and four confinement assertions
are checked from the captures. NO real Vercel sandbox is ever created.

Charter: $CHARTER (D121/D122).
EOF
}

case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  "") CHECK_ONLY=0 ;;
  *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

# ── Scratch tree + teardown (fires on any exit, incl. error / Ctrl-C). ─────────
WORK=""
cleanup() {
  local rc=$?
  set +e
  [ -n "$WORK" ] && rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT

lint() {
  echo "==> lint: node --check $SHIM"
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: 'node' not found on PATH." >&2; exit 1
  fi
  node --check "$SHIM" || { echo "ERROR: shim failed node --check" >&2; exit 1; }

  echo "==> lint: shim carries the D121 env allowlist (not a full inherit)"
  # The allowlist must be present AND wired into the spawn. A regression that drops
  # `env: vercelChildEnv()` from run() re-opens the leak, so pin both.
  if ! grep -q "vercelChildEnv" "$SHIM"; then
    echo "ERROR: shim lost vercelChildEnv() — the D121 allowlist is gone" >&2; exit 1
  fi
  if ! grep -q "env: vercelChildEnv()" "$SHIM"; then
    echo "ERROR: run() no longer applies vercelChildEnv() — the vercel child would inherit full env" >&2; exit 1
  fi
  echo "    OK: shim lints, allowlist wired into the local vercel spawn."
}

print_plan() {
  cat <<EOF
$SCRIPT_NAME — PLAN

A full (non --check) run is hermetic — it provisions NO real sandbox:

  1. Generate a fake \`vercel\` at \$WORK/vercel that, per invocation, records argv
     (NUL-delimited) + env to \$WORK/cap/, echoes a fake sandbox id on 'sandbox
     create', and exits 0 otherwise.

  2. Drive the REAL shim with the fake and PLANTED secrets:
       HOST_SECRET=<x> BARKPARK_API_TOKEN=<x> ANTHROPIC_API_KEY=$ANTHROPIC_KEY_VAL \\
       CLOUD_SANDBOX_VERCEL_BIN=\$WORK/vercel TMPDIR=\$WORK/tmp \\
         node $SHIM --workspace $WORKSPACE -- \\
           --input-format stream-json --output-format stream-json \\
           --include-partial-messages --verbose --permission-mode plan
     (fed one stream-json user frame on stdin).

  3. ASSERT from the captures:
       (a) the TURN exec (the argv with a '-lc' token) carries EXACTLY one --env:
           ANTHROPIC_API_KEY=$ANTHROPIC_KEY_VAL.
       (b) HOST_SECRET / BARKPARK_API_TOKEN / ANTHROPIC_API_KEY are ABSENT from
           every captured child env (allowlist reverses the pre-fix leak).
       (c) the in-sandbox bash script isolates HOME=/tmp/bp-cloud-home + cd
           /tmp/bp-cloud-cwd.

  4. Re-run with --workspace global, and again with NO --workspace: both must
     exit 2 and produce ZERO fake-vercel invocations (fail-closed principal gate).

No GNU timeout is used; the shim self-terminates against the fake. Scratch tree is
removed on exit.
EOF
}

# ── Generate the fake `vercel` CLI: records argv+env, emulates create→exec→remove ─
make_fake_vercel() {
  local capdir="$1" path="$2"
  cat >"$path" <<FAKE
#!/usr/bin/env bash
# Fake \`vercel\` for the W12 confinement proof. Records this invocation's argv
# (NUL-delimited) + env, then emulates just enough for the shim to proceed.
set -u
capdir="$capdir"
mkdir -p "\$capdir"
# Monotonic per-invocation index via an exclusive-create counter (calls are serial).
n=0
while ! ( set -o noclobber; : >"\$capdir/lock.\$n" ) 2>/dev/null; do
  n=\$((n + 1))
done
# argv: one NUL-terminated record per token (survives the multi-line -lc script).
: >"\$capdir/argv.\$n"
for a in "\$@"; do
  printf '%s\0' "\$a" >>"\$capdir/argv.\$n"
done
# env: one KEY=VALUE per line (values here are single-line test vars).
env >"\$capdir/env.\$n"
# Emulate: 'sandbox create ...' must echo an id the shim parses; all else exits 0.
is_create=0; is_sandbox=0
for a in "\$@"; do
  [ "\$a" = "sandbox" ] && is_sandbox=1
  [ "\$a" = "create" ] && is_create=1
done
if [ "\$is_sandbox" = 1 ] && [ "\$is_create" = 1 ]; then
  echo "sb_fake_w12_confinement"
fi
exit 0
FAKE
  chmod +x "$path"
}

# Read a NUL-delimited argv capture file into the global array CAP_TOKENS.
read_argv() {
  local f="$1"
  CAP_TOKENS=()
  local tok
  while IFS= read -r -d '' tok; do
    CAP_TOKENS+=("$tok")
  done <"$f"
}

fail() { echo "FAIL: $1" >&2; exit 1; }

run_proof() {
  WORK="$(mktemp -d)"
  local capdir="$WORK/cap"
  local fake="$WORK/vercel"
  local tmp="$WORK/tmp"
  mkdir -p "$capdir" "$tmp"
  make_fake_vercel "$capdir" "$fake"

  local user_frame='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"say ok"}]}}'
  local shim_err="$WORK/shim.err"

  echo "==> driving the REAL shim against the fake vercel (planted secrets) ..."
  # env -i would strip PATH the fake needs; instead we ADD the planted secrets on
  # top of the current env and confirm the ALLOWLIST (not env stripping) confines
  # them — that is the honest test of the shim's own confinement.
  printf '%s\n' "$user_frame" | \
    HOST_SECRET="$HOST_SECRET_VAL" \
    BARKPARK_API_TOKEN="$BARKPARK_TOKEN_VAL" \
    ANTHROPIC_API_KEY="$ANTHROPIC_KEY_VAL" \
    CLOUD_SANDBOX_VERCEL_BIN="$fake" \
    TMPDIR="$tmp" \
    node "$SHIM" --workspace "$WORKSPACE" -- \
      --input-format stream-json --output-format stream-json \
      --include-partial-messages --verbose --permission-mode plan \
      >/dev/null 2>"$shim_err"
  local rc=$?
  echo "    shim exit=$rc (the result frame, not exit code, is the auth source of truth — W11)"

  # There must be at least one captured invocation (create happened).
  local argvs=("$capdir"/argv.*)
  if [ ! -e "${argvs[0]}" ]; then
    echo "    --- shim stderr ---" >&2; sed 's/^/    /' "$shim_err" >&2
    fail "the shim made ZERO vercel invocations — the turn never dispatched"
  fi
  echo "    captured $(printf '%s\n' "$capdir"/argv.* | wc -l | tr -d ' ') vercel invocation(s)."

  # ── Locate the TURN exec by its '-lc' token (NOT by ordering — the fallback npm
  #    install exec shifts numbering). ─────────────────────────────────────────
  local turn_file="" f
  for f in "$capdir"/argv.*; do
    if grep -zxqe '-lc' "$f"; then
      turn_file="$f"
      break
    fi
  done
  [ -n "$turn_file" ] || fail "no turn exec found (no argv capture carried a '-lc' token)"
  echo "==> turn exec located by '-lc' token: $(basename "$turn_file")"

  read_argv "$turn_file"

  # (a) EXACTLY one --env pair, and it is ANTHROPIC_API_KEY=sk-test.
  local env_pairs=() i script=""
  for ((i = 0; i < ${#CAP_TOKENS[@]}; i++)); do
    if [ "${CAP_TOKENS[$i]}" = "--env" ]; then
      env_pairs+=("${CAP_TOKENS[$((i + 1))]}")
    fi
    if [ "${CAP_TOKENS[$i]}" = "-lc" ]; then
      script="${CAP_TOKENS[$((i + 1))]}"
    fi
  done
  echo "==> (a) turn exec --env list ..."
  if [ "${#env_pairs[@]}" -ne 1 ]; then
    fail "(a) expected EXACTLY one --env pair, got ${#env_pairs[@]}: ${env_pairs[*]:-<none>}"
  fi
  if [ "${env_pairs[0]}" != "ANTHROPIC_API_KEY=$ANTHROPIC_KEY_VAL" ]; then
    fail "(a) --env pair is '${env_pairs[0]}', expected 'ANTHROPIC_API_KEY=$ANTHROPIC_KEY_VAL'"
  fi
  echo "    PASS: EXACTLY [ANTHROPIC_API_KEY=$ANTHROPIC_KEY_VAL]"

  # (b) planted secrets ABSENT from EVERY captured child env.
  echo "==> (b) planted secrets absent from every captured vercel child env ..."
  local leaked
  for var in HOST_SECRET BARKPARK_API_TOKEN ANTHROPIC_API_KEY; do
    if leaked="$(grep -l "^${var}=" "$capdir"/env.* 2>/dev/null)"; then
      echo "    leaked in: $leaked" >&2
      fail "(b) $var leaked into the vercel child env — the allowlist did not confine it"
    fi
  done
  # And prove the allowlist POSITIVELY forwards what vercel needs (HOME/PATH present).
  grep -q "^PATH=" "$capdir"/env.* || fail "(b) PATH missing from the vercel child env — allowlist too tight, vercel cannot run"
  echo "    PASS: HOST_SECRET / BARKPARK_API_TOKEN / ANTHROPIC_API_KEY absent; PATH forwarded."

  # (c) in-sandbox script isolates HOME + cwd.
  echo "==> (c) in-sandbox script confines HOME + cwd (D112) ..."
  [ -n "$script" ] || fail "(c) no bash script captured after the '-lc' token"
  printf '%s' "$script" | grep -q "export HOME='/tmp/bp-cloud-home'" \
    || fail "(c) script does not export HOME=/tmp/bp-cloud-home"
  printf '%s' "$script" | grep -q "cd '/tmp/bp-cloud-cwd'" \
    || fail "(c) script does not cd into /tmp/bp-cloud-cwd"
  echo "    PASS: export HOME=/tmp/bp-cloud-home + cd /tmp/bp-cloud-cwd"

  # (d) principal gate: global + missing --workspace exit 2, ZERO vercel calls.
  echo "==> (d) fail-closed principal gate (--workspace global / missing) ..."
  assert_gate_rejects "global-workspace" --workspace global -- --permission-mode plan
  assert_gate_rejects "missing-workspace" -- --permission-mode plan
  echo "    PASS: both exit 2 with zero vercel invocations."
}

# Run the shim with a FRESH capture dir + fake vercel and assert: exit 2, no calls.
assert_gate_rejects() {
  local label="$1"; shift
  local gd="$WORK/gate-$label"
  local gcap="$gd/cap" gfake="$gd/vercel" gtmp="$gd/tmp"
  mkdir -p "$gcap" "$gtmp"
  make_fake_vercel "$gcap" "$gfake"

  local frame='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"say ok"}]}}'
  printf '%s\n' "$frame" | \
    HOST_SECRET="$HOST_SECRET_VAL" \
    BARKPARK_API_TOKEN="$BARKPARK_TOKEN_VAL" \
    ANTHROPIC_API_KEY="$ANTHROPIC_KEY_VAL" \
    CLOUD_SANDBOX_VERCEL_BIN="$gfake" \
    TMPDIR="$gtmp" \
    node "$SHIM" "$@" >/dev/null 2>"$gd/err"
  local rc=$?
  [ "$rc" -eq 2 ] || fail "(d/$label) expected exit 2, got $rc"
  if compgen -G "$gcap/argv.*" >/dev/null; then
    fail "(d/$label) shim invoked vercel before the principal gate (found argv captures)"
  fi
  echo "    ok ($label): exit 2, zero vercel invocations."
}

main() {
  echo "== Connectors Wave-12 shim-confinement proof =="
  echo "== charter: $CHARTER (D121/D122) =="
  lint

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    print_plan
    echo ""
    echo "--check OK: shim linted, allowlist wired, plan printed, nothing spawned."
    return 0
  fi

  run_proof
  echo ""
  echo "== PROVEN: the local vercel child is env-confined (allowlist reverses the leak);"
  echo "==         turn exec carries exactly one --env ANTHROPIC_API_KEY; HOME/cwd isolated;"
  echo "==         principal gate fails closed with zero vercel calls. =="
  echo "== The LIVE host-denial observation rides the human gate connectors-hg-live-isolated-cloud-turn. =="
}

main
