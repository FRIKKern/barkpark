#!/usr/bin/env bash
# cp-ops.test.sh — scripts/cp-ops.sh against .github/workflows/cp-ops.yml.
#
# Usage: bash scripts/cp-ops.test.sh            run every clause
#        bash scripts/cp-ops.test.sh --regen    rewrite the golden from the
#                                               CURRENT script (an arm edit)
#
# task-2ea65cb8f1c71a2a. Before this file, deleting a cp-ops arm (menu option +
# case branch) reddened nothing. Three clauses:
#
#   A  PARITY, BOTH WAYS. The workflow_dispatch choice list and the script's
#      top-level case arms are the same set. An option with no arm dispatches
#      into `unknown operation`; an arm with no option is dead code nobody can
#      reach. Either half alone is a red that NAMES the operation.
#   B  CONTROLS FOR A. A copy of the workflow with one option deleted, and a
#      copy of the script with one arm deleted, must each red clause A — so a
#      parser that returns the empty set on both sides cannot pass as "equal".
#   C  GOLDEN. Every case below runs the real script with a stub `ssh` first on
#      PATH (and CP_OPS_DRY_RUN=1, so no key is written). The stub prints its
#      argv and says what arrived on stdin; the run's output + exit code must
#      equal scripts/fixtures/cp-ops/golden.txt, which was captured from the
#      ORIGINAL workflow `run:` block (origin/main 6d6804020) before the arms
#      moved. That is the byte-for-byte proof: same validation verdicts, same
#      ssh argv, same quoting, same runner-side vs remote-side expansion.
#      Every choice option must also be exercised by at least one case.
#
# Hermetic: no network, no ssh, no secrets; mktemp only. Exit 0 = all green.
# shellcheck disable=SC2016 # literal $(…) inputs and a literal "$OP" pattern are the point
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
WORKFLOW="${CP_OPS_WORKFLOW:-.github/workflows/cp-ops.yml}"
SCRIPT="${CP_OPS_SCRIPT:-scripts/cp-ops.sh}"
RUNNER="${CP_OPS_RUNNER:-$SCRIPT}"
GOLDEN="scripts/fixtures/cp-ops/golden.txt"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }

# ── parsers ─────────────────────────────────────────────────────────────────
# The choice list: the `- item` lines directly under the ONE `options:` key.
choice_list() {
  local n
  n=$(grep -c '^ *options: *$' "$1" || true)
  [ "$n" = 1 ] || { echo "PARSE-ERROR: $1 has $n options: keys, want 1" >&2; return 1; }
  awk '/^ *options: *$/ {f=1; next}
       f && /^ *- / {sub(/^ *- */, ""); sub(/ *$/, ""); print; next}
       f {exit}' "$1" | sort
}
# The script's arms: labels at the top-level case's indent (two spaces). The
# nested `case "$UNIT"` in box-logs sits deeper and is not an operation; `*)`
# is the unknown-operation arm.
script_arms() {
  grep -E '^  [a-z][a-z0-9-]*\)$' "$1" | sed -E 's/^  ([a-z0-9-]+)\)$/\1/' | sort
}

# parity WORKFLOW SCRIPT — prints one line per mismatch, returns 1 on any.
parity() {
  local list arms rc=0 op
  list=$(choice_list "$1") || return 1
  arms=$(script_arms "$2")
  [ -n "$list" ] || { echo "EMPTY choice list in $1"; return 1; }
  [ -n "$arms" ] || { echo "EMPTY arm set in $2"; return 1; }
  for op in $(comm -23 <(printf '%s\n' "$list") <(printf '%s\n' "$arms")); do
    echo "in the choice list, NOT in the script: $op"; rc=1
  done
  for op in $(comm -13 <(printf '%s\n' "$list") <(printf '%s\n' "$arms")); do
    echo "in the script, NOT in the choice list: $op"; rc=1
  done
  return "$rc"
}

# ── the golden cases ────────────────────────────────────────────────────────
STUB="$WORK/bin"
mkdir -p "$STUB"
cat > "$STUB/ssh" <<'STUBEOF'
#!/usr/bin/env bash
# Stub ssh: print argv verbatim, then what arrived on stdin. Never connects.
printf '>>> ssh argc=%d\n' "$#"
i=0
for a in "$@"; do printf -- '--- argv[%d]\n%s\n' "$i" "$a"; i=$((i + 1)); done
in=$(mktemp); cat > "$in"
if [ -s "$in" ] && cmp -s "$in" deploy/site-runtime-install.sh; then
  echo '--- stdin: deploy/site-runtime-install.sh (byte-identical)'
else
  printf -- '--- stdin: %d bytes\n' "$(wc -c < "$in" | tr -d ' ')"
fi
rm -f "$in"
STUBEOF
chmod +x "$STUB/ssh"

UUID=0123abcd-4567-89ab-cdef-0123456789ab
# run_case NAME OP [VAR=value ...] — one golden record.
run_case() {
  local name="$1" op="$2" rc=0
  shift 2
  printf '=== case %s: op=%s' "$name" "$op"
  local kv; for kv in "$@"; do printf ' [%s]' "$kv"; done
  printf '\n'
  env -i PATH="$STUB:$PATH" HOME="${HOME:-/tmp}" LC_ALL=C \
    CP_OPS_DRY_RUN=1 DEPLOY_SSH_KEY=dummy-key \
    CP_HOST=cp.example.invalid GUERRILLA_HOST=guerrilla.example.invalid \
    TEAM= NEEDLE= BOX_IP= ARTIFACT_REPO= ARTIFACT_REF= UNIT= FILE_PATH= \
    OP="$op" "$@" bash "$RUNNER" "$op" < /dev/null 2>&1 || rc=$?
  printf '=== exit %d\n' "$rc"
}

all_cases() {
  run_case grant-forever/ok grant-forever TEAM="$UUID"
  run_case grant-forever/not-uuid grant-forever TEAM='x"); System.halt()'
  run_case cp-app-logs/tail cp-app-logs
  run_case cp-app-logs/needle cp-app-logs NEEDLE=req_ABC-123
  run_case cp-app-logs/bad-needle cp-app-logs "NEEDLE=a'b;c"
  run_case guerrilla-logs-grep/ok guerrilla-logs-grep NEEDLE=F1a2b3c4
  run_case guerrilla-logs-grep/empty guerrilla-logs-grep
  run_case guerrilla-db-probe/ok guerrilla-db-probe NEEDLE='$(ignored)'
  run_case site-runtime-install/ok site-runtime-install BOX_IP=10.0.0.7
  run_case site-runtime-install/bad-ip site-runtime-install 'BOX_IP=10.0.0.7;id'
  run_case site-artifact-fetch/ok site-artifact-fetch BOX_IP=10.0.0.7 ARTIFACT_REPO=acme/site.web ARTIFACT_REF=feature/x-1
  run_case site-artifact-fetch/bad-repo site-artifact-fetch BOX_IP=10.0.0.7 'ARTIFACT_REPO=acme/site;id' ARTIFACT_REF=main
  run_case site-artifact-fetch/bad-ref site-artifact-fetch BOX_IP=10.0.0.7 ARTIFACT_REPO=acme/site 'ARTIFACT_REF=main$(id)'
  run_case box-logs/ok box-logs BOX_IP=10.0.0.7 UNIT=barkpark-runtime
  run_case box-logs/bad-unit box-logs BOX_IP=10.0.0.7 UNIT=sshd
  run_case builder-token-fix/ok builder-token-fix BOX_IP=10.0.0.7
  run_case box-file-tail/ok box-file-tail BOX_IP=10.0.0.7 FILE_PATH=/var/log/barkpark-builder/build-1.log
  run_case box-file-tail/escape box-file-tail BOX_IP=10.0.0.7 FILE_PATH=/var/log/barkpark-builder/../../etc/shadow
  run_case caddy-repair/ok caddy-repair BOX_IP=10.0.0.7
  run_case box-probe/ok box-probe BOX_IP=10.0.0.7
  run_case box-probe/bad-ip box-probe BOX_IP=box.example
  run_case box-prune/ok box-prune BOX_IP=10.0.0.7
  run_case box-unit-repair/list box-unit-repair BOX_IP=10.0.0.7
  run_case box-unit-repair/unit box-unit-repair BOX_IP=10.0.0.7 UNIT=barkpark-slot@b
  run_case box-unit-repair/bad-unit box-unit-repair BOX_IP=10.0.0.7 'UNIT=caddy;id'
  run_case box-migrate/ok box-migrate BOX_IP=10.0.0.7
  run_case unknown-op nope
}

if [ "${1:-}" = --regen ]; then
  mkdir -p "$(dirname "$GOLDEN")"
  all_cases > "$GOLDEN"
  echo "wrote $GOLDEN ($(grep -c '^=== case ' "$GOLDEN") cases, $(wc -c < "$GOLDEN" | tr -d ' ') bytes)"
  exit 0
fi
[ $# -eq 0 ] || { echo "usage: $0 [--regen]" >&2; exit 2; }

# ── A: parity, both ways ────────────────────────────────────────────────────
if out=$(parity "$WORKFLOW" "$SCRIPT"); then
  pass "A  choice list == script arms ($(choice_list "$WORKFLOW" | wc -l | tr -d ' ') operations)"
else
  fail "A  choice list != script arms:"; printf '        %s\n' "$out"
fi
if grep -Eq '^ +run: bash scripts/cp-ops\.sh "\$OP"$' "$WORKFLOW"; then
  pass 'A  the workflow step runs `bash scripts/cp-ops.sh "$OP"`'
else
  fail "A  $WORKFLOW does not run bash scripts/cp-ops.sh \"\$OP\""
fi

# ── B: controls — each half alone must red A, naming the operation ─────────
victim=$(script_arms "$SCRIPT" | tail -1)
grep -v -E "^ +- ${victim}\$" "$WORKFLOW" > "$WORK/wf-minus.yml"
if out=$(parity "$WORK/wf-minus.yml" "$SCRIPT"); then
  fail "B  option '$victim' deleted from the choice list, parity still GREEN"
elif grep -qx "in the script, NOT in the choice list: $victim" <<< "$out"; then
  pass "B  option '$victim' deleted from the choice list -> red: in the script, NOT in the choice list: $victim"
else
  fail "B  option deleted, red for the wrong reason: $out"
fi
grep -v -E "^  ${victim}\)\$" "$SCRIPT" > "$WORK/script-minus.sh"
if out=$(parity "$WORKFLOW" "$WORK/script-minus.sh"); then
  fail "B  arm '$victim' deleted from the script, parity still GREEN"
elif grep -qx "in the choice list, NOT in the script: $victim" <<< "$out"; then
  pass "B  arm '$victim' deleted from the script -> red: in the choice list, NOT in the script: $victim"
else
  fail "B  arm deleted, red for the wrong reason: $out"
fi

# ── C: golden — every arm's emitted ssh argv/stdin + verdict ────────────────
all_cases > "$WORK/actual.txt"
if [ ! -f "$GOLDEN" ]; then
  fail "C  golden missing: $GOLDEN"
elif cmp -s "$GOLDEN" "$WORK/actual.txt"; then
  pass "C  $(grep -c '^=== case ' "$GOLDEN") cases byte-identical to $GOLDEN"
else
  fail "C  output differs from $GOLDEN (an arm changed; if intended: --regen and review the diff)"
  diff -u "$GOLDEN" "$WORK/actual.txt" > "$WORK/golden.diff" || true
  head -60 "$WORK/golden.diff"
fi
# Each option is exercised by a case that reaches ssh.
for op in $(choice_list "$WORKFLOW"); do
  if awk -v op="$op" '$0 ~ "^=== case .*: op=" op "( |$)" {c=1; next}
                      c && /^>>> ssh / {hit=1}
                      /^=== exit / {c=0}
                      END {exit !hit}' "$WORK/actual.txt"; then
    :
  else
    fail "C  option '$op' has no golden case that reaches ssh"
  fi
done
[ "$FAILS" -gt 0 ] || pass "C  every choice option has a case that reaches ssh"

if [ "$FAILS" -gt 0 ]; then
  echo "cp-ops.test.sh: $FAILS FAILED"; exit 1
fi
echo "cp-ops.test.sh: all green"
