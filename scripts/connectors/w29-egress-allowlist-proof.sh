#!/usr/bin/env bash
# w29-egress-allowlist-proof.sh — the Connectors Wave-29 per-connector egress
# allowlist union proof (D238/D240/D241/D242). BLACK-BOX, hermetic, provisions
# NO real sandbox and opens NO real egress.
#
# W25 delivered the connector's credential INTO the cloud sandbox, but the W12
# lockdown's create shape (`--allowed-domain api.anthropic.com`) denies egress
# to every other host — a GitHub MCP server inside the sandbox cannot reach
# api.githubcopilot.com, so the credential was useless. Wave 29 widens egress
# PER CONNECTOR, minimally and declared: the Elixir side passes one repeated
# `--egress-host <host>` pre-`--` shim flag per host DECLARED by an INSTALLED
# connector; the shim unions those with the ALLOWED_DOMAIN base, dedupes, and
# emits ONE repeated `--allowed-domain <host>` pair per host at `vercel sandbox
# create` — SNAPSHOT path only (the no-snapshot fallback boots allow-all per
# D113c; the `--sandbox-id` reuse path skips create entirely). Two CLI hazards
# are load-bearing (D241): `--network-policy` must NEVER be co-emitted with
# `--allowed-domain` (the CLI throws), and hosts must NEVER be comma-joined
# (the CLI parses that as ONE malformed domain).
#
# Same technique as w12/w14/w25: `CLOUD_SANDBOX_VERCEL_BIN` points the REAL
# cloud-sandbox-runner.mjs at a generated FAKE `vercel` that records every
# invocation's argv (NUL-delimited) and echoes an id on `sandbox create`. No
# real Vercel, no GNU timeout (absent on darwin — the shim self-terminates
# against the fake). The create capture is located by CONTENT (argv predicates),
# never by file order.
#
# Assertions — SET-EQUALITY on the multiset of values following
# `--allowed-domain` tokens in the create capture (sort+diff, NEVER containment
# — containment would pass a blanket allowlist that smuggles extra hosts):
#   LEG A  `--egress-host api.githubcopilot.com` ⇒ EXACTLY
#          {api.anthropic.com, api.githubcopilot.com} — the base plus the one
#          declared host, nothing else (no blanket, no cross-connector leak).
#   LEG B  no `--egress-host` ⇒ EXACTLY {api.anthropic.com} — the pre-W29
#          deny-all-except-anthropic baseline, byte-preserved.
#   LEG C  `--egress-host api.anthropic.com` (the base, repeated) ⇒ EXACTLY
#          {api.anthropic.com} ONCE — deduped, never a doubled flag.
#   ALL    `--network-policy` is ABSENT from the create argv (D241), and no
#          emitted value contains a comma (no comma-join).
#
# RED-FIRST: against the pre-W29 runner this proof FAILS at LEG A — the shim
# ignores the unknown `--egress-host` flag and the create carries only the base,
# so the set-equality check reds on the missing api.githubcopilot.com.
#
# See .claude/workflows/bp-connectors-charter.md (Wave 29) and the wave paper
# connectors-wave-29-2026-07-18. Sibling idioms: w12-shim-confinement-proof.sh,
# w14-session-sandbox-proof.sh, w25-credential-embed-proof.sh. The LIVE egress
# enforcement is Vercel Sandbox behavior riding the human gate
# connectors-hg-live-isolated-cloud-turn; this proof pins the ALLOWLIST
# DERIVATION at the config layer.
#
# Usage:
#   scripts/connectors/w29-egress-allowlist-proof.sh --check   # lint the shim + print the plan, run NO subprocess
#   scripts/connectors/w29-egress-allowlist-proof.sh           # hermetic black-box run (fake vercel)
set -uo pipefail
export LC_ALL=C

SCRIPT_NAME="w29-egress-allowlist-proof.sh"
CHARTER=".claude/workflows/bp-connectors-charter.md"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/cloud-sandbox-runner.mjs"

WORKSPACE="w29-proof-ws"
FAKE_CREATE_ID="sb_fake_w29_egress"
BASE_DOMAIN="api.anthropic.com"
GITHUB_HOST="api.githubcopilot.com"
# The claude segment every leg passes after `--` (the D109 argv shape).
CLAUDE_ARGS=(--input-format stream-json --output-format stream-json --include-partial-messages --verbose --permission-mode plan)

CHECK_ONLY=0

usage() {
  cat <<EOF
$SCRIPT_NAME — Connectors Wave-29 per-connector egress allowlist proof (D238-D242).

  --check    node --check the shim + print the plan; runs NO shim subprocess and
             spawns NO vercel (real or fake).
  --help     this text.

With no flag it runs the HERMETIC black-box proof: a generated fake \`vercel\`
records argv per call, and the REAL $SHIM is driven for the three set-equality
legs (A github-widened, B baseline-preserved, C base-repeated-deduped). NO real
Vercel sandbox, NO real egress.

Charter: $CHARTER (Wave 29, D238/D240/D241/D242).
EOF
}

case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  "") CHECK_ONLY=0 ;;
  *)
    echo "ERROR: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

# ── Scratch tree teardown (fires on any exit, incl. error / Ctrl-C). ───────────
WORK=""
cleanup() {
  local rc=$?
  set +e
  [ -n "$WORK" ] && rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

lint() {
  echo "==> lint: node --check $SHIM"
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: 'node' not found on PATH." >&2
    exit 1
  fi
  node --check "$SHIM" || { echo "ERROR: shim failed node --check" >&2; exit 1; }
  echo "    OK: shim lints."
}

print_plan() {
  cat <<EOF
$SCRIPT_NAME — PLAN

A full (non --check) run is hermetic — it provisions NO real sandbox:

  1. Generate a fake \`vercel\` that records each invocation's argv
     (NUL-delimited) and echoes '$FAKE_CREATE_ID' on 'sandbox create'.

  2. Drive the REAL shim (snapshot path forced, so the create carries the
     egress lock) for three legs and locate the create capture by CONTENT:

     LEG A  WIDENED: --egress-host $GITHUB_HOST ⇒ the create's
            --allowed-domain multiset is EXACTLY {$BASE_DOMAIN, $GITHUB_HOST}.
     LEG B  BASELINE: no --egress-host ⇒ EXACTLY {$BASE_DOMAIN} — the pre-W29
            deny-all-except-anthropic shape, byte-preserved.
     LEG C  DEDUP: --egress-host $BASE_DOMAIN (base repeated) ⇒ EXACTLY
            {$BASE_DOMAIN} once, never a doubled flag.

     Every leg additionally asserts --network-policy is ABSENT from the create
     argv (D241 — the CLI throws on the combination) and that no emitted value
     contains a comma (a comma-join parses as ONE malformed domain).

  3. Pin the W29 mechanism markers in the shim source (regression tripwires).

All comparisons are SET-EQUALITY (sort+diff), never containment. No GNU timeout
is used; the shim self-terminates against the fake. Scratch tree removed on exit.
EOF
}

# ── Generate the fake `vercel`: records argv, echoes an id on create. ──────────
make_fake_vercel() {
  local capdir="$1" path="$2"
  cat >"$path" <<FAKE
#!/usr/bin/env bash
# Fake \`vercel\` for the W29 egress-allowlist proof. Records this invocation's
# argv (NUL-delimited), then emulates just enough for the shim to proceed.
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
# Emulate: create echoes an id.
is_sandbox=0; is_create=0
for a in "\$@"; do
  [ "\$a" = "sandbox" ] && is_sandbox=1
  [ "\$a" = "create" ] && is_create=1
done
if [ "\$is_sandbox" = 1 ] && [ "\$is_create" = 1 ]; then
  echo "$FAKE_CREATE_ID"
fi
exit 0
FAKE
  chmod +x "$path"
}

# ── argv predicates over NUL-delimited capture files (w12/w14/w25 idioms). ─────
read_argv() {
  local f="$1"
  CAP_TOKENS=()
  local tok
  while IFS= read -r -d '' tok; do
    CAP_TOKENS+=("$tok")
  done <"$f"
}

argv_has_all() {
  local f="$1"
  shift
  local t
  for t in "$@"; do
    grep -zxq -e "$t" "$f" || return 1
  done
  return 0
}

# Echo the single real `sandbox create` capture in a capture dir, located by
# CONTENT (never file order). Fails if zero or >1.
find_create_capture() {
  local capdir="$1" found="" f
  for f in "$capdir"/argv.*; do
    [ -e "$f" ] || continue
    if argv_has_all "$f" sandbox create && ! grep -zxq -e '--help' "$f"; then
      [ -n "$found" ] && return 2
      found="$f"
    fi
  done
  [ -n "$found" ] || return 1
  echo "$found"
}

# ── The load-bearing assertion: SET-EQUALITY on --allowed-domain values. ───────
# Args: <leg-label> <create-capture> <expected-host>...
# Collects the value following EVERY --allowed-domain token (multiset — a
# doubled host survives into the comparison) and diffs the sorted multiset
# against the sorted expected list. Containment is deliberately NOT used: a
# blanket allowlist smuggling extra hosts must red here.
assert_allowed_domains() {
  local label="$1" capfile="$2"
  shift 2
  # (D241) --network-policy must never ride the same create as --allowed-domain.
  if grep -zxq -e '--network-policy' "$capfile"; then
    fail "$label: --network-policy co-emitted on the create argv (D241: the vercel CLI throws on the combination)"
  fi
  read_argv "$capfile"
  local vals=() i
  for ((i = 0; i < ${#CAP_TOKENS[@]}; i++)); do
    if [ "${CAP_TOKENS[$i]}" = "--allowed-domain" ]; then
      [ $((i + 1)) -lt ${#CAP_TOKENS[@]} ] || fail "$label: trailing --allowed-domain with no value"
      vals+=("${CAP_TOKENS[$((i + 1))]}")
    fi
  done
  local v
  for v in "${vals[@]:-}"; do
    case "$v" in
      *,*) fail "$label: --allowed-domain value '$v' contains a comma — a comma-join parses as ONE malformed domain" ;;
    esac
  done
  local got want
  got="$(printf '%s\n' "${vals[@]:-}" | sed '/^$/d' | sort)"
  want="$(printf '%s\n' "$@" | sort)"
  if [ "$got" != "$want" ]; then
    fail "$label: --allowed-domain multiset is {$(printf '%s' "$got" | tr '\n' ' ')} — expected EXACTLY {$(printf '%s' "$want" | tr '\n' ' ')} (set-equality, never containment)"
  fi
}

# ── Drive the REAL shim once. Sets globals CAP / OUT / ERR / TMP / RC. ─────────
# Args: <leg-label> [pre-`--` shim flags...]
drive() {
  local label="$1"
  shift
  local leg="$WORK/$label"
  CAP="$leg/cap"
  OUT="$leg/out"
  ERR="$leg/err"
  TMP="$leg/tmp"
  local fake="$leg/vercel"
  mkdir -p "$CAP" "$TMP"
  make_fake_vercel "$CAP" "$fake"

  local user_frame='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"say ok"}]}}'
  printf '%s\n' "$user_frame" |
    ANTHROPIC_API_KEY="sk-test" \
      CLOUD_SANDBOX_VERCEL_BIN="$fake" \
      CLOUD_SANDBOX_SNAPSHOT="snap_fake_w29" \
      TMPDIR="$TMP" \
      node "$SHIM" --workspace "$WORKSPACE" "$@" -- "${CLAUDE_ARGS[@]}" \
      >"$OUT" 2>"$ERR"
  RC=$?
  echo "    ($label) shim exit=$RC, $(find "$CAP" -name 'argv.*' | wc -l | tr -d ' ') vercel invocation(s)."
}

run_proof() {
  WORK="$(mktemp -d)"
  local create_cap

  # ── LEG A: WIDENED — one declared connector host joins the base. ─────────────
  echo "==> LEG A (widened): --egress-host $GITHUB_HOST ⇒ exactly {$BASE_DOMAIN, $GITHUB_HOST} ..."
  drive legA --egress-host "$GITHUB_HOST"
  [ "$RC" -eq 0 ] || fail "legA: shim exited nonzero ($RC) — stderr: $(tail -3 "$ERR" | tr '\n' ' ')"
  create_cap="$(find_create_capture "$CAP")" || fail "legA: no single 'sandbox create' capture (rc=$?)"
  assert_allowed_domains legA "$create_cap" "$BASE_DOMAIN" "$GITHUB_HOST"
  echo "    PASS: create carries EXACTLY {$BASE_DOMAIN, $GITHUB_HOST} — no blanket, no extra host."

  # ── LEG B: BASELINE — no --egress-host ⇒ the pre-W29 shape, byte-preserved. ──
  echo "==> LEG B (baseline): no --egress-host ⇒ exactly {$BASE_DOMAIN} ..."
  drive legB
  [ "$RC" -eq 0 ] || fail "legB: shim exited nonzero ($RC) — stderr: $(tail -3 "$ERR" | tr '\n' ' ')"
  create_cap="$(find_create_capture "$CAP")" || fail "legB: no single 'sandbox create' capture (rc=$?)"
  assert_allowed_domains legB "$create_cap" "$BASE_DOMAIN"
  echo "    PASS: deny-all-except-anthropic baseline preserved — exactly {$BASE_DOMAIN}."

  # ── LEG C: DEDUP — the base repeated via --egress-host emits ONCE. ───────────
  echo "==> LEG C (dedup): --egress-host $BASE_DOMAIN (base repeated) ⇒ exactly {$BASE_DOMAIN} once ..."
  drive legC --egress-host "$BASE_DOMAIN"
  [ "$RC" -eq 0 ] || fail "legC: shim exited nonzero ($RC) — stderr: $(tail -3 "$ERR" | tr '\n' ' ')"
  create_cap="$(find_create_capture "$CAP")" || fail "legC: no single 'sandbox create' capture (rc=$?)"
  assert_allowed_domains legC "$create_cap" "$BASE_DOMAIN"
  echo "    PASS: base repeated dedupes to a single --allowed-domain $BASE_DOMAIN."

  # ── Regression tripwires: the W29 mechanism markers in the shim source. ──────
  echo "==> marker pins: the W29 mechanism is present in the shim source ..."
  grep -q -- '--egress-host' "$SHIM" || fail "shim lost the --egress-host flag (W29, D238)"
  grep -q 'egressHosts' "$SHIM" || fail "shim lost the egressHosts union (W29, D240)"
  echo "    PASS: --egress-host / egressHosts markers present."
}

main() {
  echo "== Connectors Wave-29 per-connector egress allowlist proof =="
  echo "== charter: $CHARTER (Wave 29, D238/D240/D241/D242) =="
  lint

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    print_plan
    echo ""
    echo "--check OK: shim linted, plan printed, nothing spawned."
    return 0
  fi

  run_proof
  echo ""
  echo "== PROVEN: a declared --egress-host widens the SNAPSHOT create to EXACTLY"
  echo "==         the base ∪ declared hosts (set-equality, repeated --allowed-domain"
  echo "==         pairs, deduped, never --network-policy alongside, never comma-joined);"
  echo "==         with no --egress-host the deny-all-except-anthropic baseline is preserved. =="
  echo "== The LIVE egress enforcement rides the human gate connectors-hg-live-isolated-cloud-turn. =="
}

main
