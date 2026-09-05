#!/usr/bin/env bash
# relandcheck-diff-producer.test.sh — the escape harness reland-check.yml never had.
#
# THE BUG THIS EXISTS FOR
#
# `.github/workflows/reland-check.yml`'s "Compute changed files" step builds the
# file set the re-land scanner reasons over. It built it with the plain
# producer:
#
#     git diff --name-only "${BASE_SHA}...HEAD" > /tmp/changed.txt
#
# which drops files SILENTLY in two measured shapes:
#
#   • a path containing a double quote is printed QUOTED (`"docs/we\"ird.md"`),
#     even under core.quotepath=false — so the scanner is handed a literal that
#     names no file on disk and the change is simply never considered;
#   • rename detection prints only the DESTINATION, so a file renamed OUT of a
#     watched tree disappears from the changed set altogether.
#
# Both produce a GREEN advisory over a scan that never looked. The wave-10
# dispatchers (elixir.yml, cloud.yml, console-harness.yml, security.yml,
# go-tests.yml) closed exactly this with `-c core.quotepath=false diff -z
# --name-only --no-renames … | tr '\0' '\n'`; reland-check.yml carried the
# pre-fix shape and had no harness to notice.
#
# WHAT THIS HARNESS DOES
#
# It EXTRACTS the step body out of the live reland-check.yml and EXECUTES it
# against real git fixtures, so it cannot paraphrase what CI runs. Then it
# MUTATES a copy of the workflow back to the pre-fix producer line and proves
# both cases go RED — a harness that has never been shown to fail is not a
# harness, it is a green line.
#
# The ONLY substitution made to the extracted body is the hardcoded output path
# `/tmp/changed.txt` -> "$T_CHANGED", so concurrent runs do not collide. The git
# command itself — the whole subject — is executed verbatim.
#
# Exit 2 = HARNESS UNAVAILABLE (python3 or PyYAML missing). Never a pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/reland-check.yml"
STEP_NAME="Compute changed files"

PASS=0
FAIL=0
ok()  { printf '  ok: %s\n' "$1"; PASS=$((PASS + 1)); }
no()  { printf '  FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

command -v python3 >/dev/null 2>&1 || {
  echo "HARNESS-UNAVAILABLE: python3 not on PATH — the workflow is yaml-PARSED, not grepped." >&2
  exit 2
}
python3 -c 'import yaml' 2>/dev/null || {
  echo "HARNESS-UNAVAILABLE: PyYAML missing (pip install pyyaml). A harness that cannot read" >&2
  echo "its subject must not certify it." >&2
  exit 2
}
[ -f "$WF" ] || { echo "HARNESS-UNAVAILABLE: $WF not found" >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/relandproducer.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

# ── extraction ───────────────────────────────────────────────────────────────

# extract_step <workflow.yml> <dest.sh> — fails loudly if the step is gone or
# renamed, rather than writing an empty file that would "pass" every case.
extract_step() {
  python3 - "$1" "$2" "$STEP_NAME" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = [s for j in wf["jobs"].values() for s in j.get("steps", [])
         if s.get("name") == sys.argv[3] and "run" in s]
if len(steps) != 1:
    sys.exit("expected exactly 1 step named %r with a run body, found %d"
             % (sys.argv[3], len(steps)))
body = steps[0]["run"].replace("/tmp/changed.txt", '"$T_CHANGED"')
open(sys.argv[2], "w").write(body)
PY
}

# ── fixtures ─────────────────────────────────────────────────────────────────

DR="$TMPROOT/repo"
mkdir -p "$DR/api/lib" "$DR/docs"
printf 'plain\n' >"$DR/api/lib/thing.ex"
# NON-EMPTY on purpose: git's rename detection needs a real similarity source,
# and an empty blob is not a rename worth the name.
printf 'moved-a\nmoved-b\nmoved-c\nmoved-d\n' >"$DR/api/lib/moved.ex"
printf 'guide\n' >"$DR/docs/guide.md"
git -C "$DR" init -q
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
BASE_SHA="$(git -C "$DR" rev-parse HEAD)"

# The quote-bearing path is written from a variable, never threaded through a
# nested quoting layer — this harness is ABOUT quote-bearing paths and a fixture
# that breaks on its own apostrophe proves nothing.
DQ_PATH='docs/we"ird.md'

branch() {  # branch <name>  — fresh branch off the base commit
  git -C "$DR" checkout -q -b "$1" "$BASE_SHA" 2>/dev/null \
    || git -C "$DR" checkout -q "$1"
}
commit() { git -C "$DR" add -A >/dev/null 2>&1
           git -C "$DR" -c user.email=t@t -c user.name=t commit -qm "$1" >/dev/null 2>&1; }

branch dquote
printf 'weird\n' >"$DR/$DQ_PATH"
commit dquote

branch renameout
git -C "$DR" mv api/lib/moved.ex docs/moved.ex >/dev/null 2>&1
commit renameout

# a base with NO common ancestor — the shape whose two-dot fallback wave 10
# forbade. An orphan branch shares no history with $BASE_SHA.
git -C "$DR" checkout -q --orphan noancestor >/dev/null 2>&1
git -C "$DR" rm -rq --cached . >/dev/null 2>&1 || true
rm -rf "${DR:?}/api" "${DR:?}/docs"
mkdir -p "$DR/api/lib"
printf 'z\n' >"$DR/api/lib/orphan.ex"
commit orphan

# ── the driver ───────────────────────────────────────────────────────────────

OUT="$TMPROOT/step.out"
CHANGED="$TMPROOT/changed.txt"

# run_step <step.sh> <branch> -> rc; leaves stdout+stderr in $OUT and the
# produced file set in $CHANGED.
run_step() {
  local step="$1" br="$2" rc=0
  git -C "$DR" checkout -q "$br"
  : >"$CHANGED"
  (cd "$DR" && env BASE_SHA="$BASE_SHA" T_CHANGED="$CHANGED" \
      bash --noprofile --norc "$step") >"$OUT" 2>&1 || rc=$?
  return "$rc"
}

# has_exact <path> — the produced set contains this path as a WHOLE LINE. A
# substring match would be satisfied by the quoted form `"docs/we\"ird.md"`,
# which is precisely the bug, so the comparison is line-exact.
has_exact() {
  local want="$1" line
  while IFS= read -r line; do [ "$line" = "$want" ] && return 0; done <"$CHANGED"
  return 1
}

echo "reland-check.yml — 'Compute changed files' producer, driven against real git"
echo

STEP="$TMPROOT/step-live.sh"
extract_step "$WF" "$STEP" || { echo "HARNESS-UNAVAILABLE: could not extract the step" >&2; exit 2; }

echo "case 1/5: the live producer keeps a DOUBLE-QUOTE path in the set"
rc=0; run_step "$STEP" dquote || rc=$?
if [ "$rc" -ne 0 ]; then
  no "the step exited $rc on an ordinary PR shape"; sed 's/^/        /' "$OUT" >&2
elif has_exact "$DQ_PATH"; then
  ok "$DQ_PATH survives, unquoted and unescaped"
else
  no "$DQ_PATH is NOT in the changed set — the scanner would never consider it"
  sed 's/^/        /' "$CHANGED" >&2
fi

echo
echo "case 2/5: the live producer keeps BOTH sides of a rename OUT of api/**"
rc=0; run_step "$STEP" renameout || rc=$?
if [ "$rc" -ne 0 ]; then
  no "the step exited $rc on a rename PR"; sed 's/^/        /' "$OUT" >&2
else
  has_exact "api/lib/moved.ex" \
    && ok "the rename SOURCE api/lib/moved.ex is present (--no-renames)" \
    || { no "api/lib/moved.ex vanished — code left api/** and the set does not say so"
         sed 's/^/        /' "$CHANGED" >&2; }
  has_exact "docs/moved.ex" \
    && ok "the rename DESTINATION docs/moved.ex is present too" \
    || no "docs/moved.ex missing — closing the source direction cost the obvious one"
fi

echo
echo "case 3/5: a base with NO common ancestor REFUSES — it never falls back to two-dot"
rc=0; run_step "$STEP" noancestor || rc=$?
body="$(cat "$OUT")"
[ "$rc" -ne 0 ] && ok "the step exits non-zero ($rc) instead of scoring a whole-repo set" \
                || no "the step exited 0 on a base sharing no history — the fallback is back"
case "$body" in *"::error::"*) ok "…with a GitHub ::error:: annotation" ;;
                *) no "…with no ::error:: annotation: $body" ;; esac
case "$body" in *"no merge base"*) ok "…naming the no-common-ancestor condition" ;;
                *) no "…never naming the condition: $body" ;; esac
case "$body" in *"two-dot"*) ok "…and naming the fallback it refuses" ;;
                *) no "…never naming the refused two-dot fallback" ;; esac

# ── the mutation: the pre-fix producer must go RED on both shapes ────────────
#
# Restore the exact line reland-check.yml carried before this fix, on a COPY,
# and prove the two cases above fail. The anchor is asserted to match EXACTLY
# ONCE and the mutated copy asserted to DIFFER — a mutation that never applied
# yields a red that means nothing, and a green that means less.

echo
echo "case 4/5: MUTATION — the pre-fix producer restored; both shapes must go RED"
MUT="$TMPROOT/reland-prefix.yml"
python3 - "$WF" "$MUT" <<'PY'
import sys
s = open(sys.argv[1]).read()
new = ('          git -c core.quotepath=false diff -z --name-only --no-renames '
       '"${BASE_SHA}...HEAD" \\\n            | tr \'\\0\' \'\\n\' > /tmp/changed.txt || {\n')
old = '          git diff --name-only "${BASE_SHA}...HEAD" > /tmp/changed.txt || {\n'
n = s.count(new)
if n != 1:
    sys.exit("MUTATION ANCHOR matched %d times, wanted exactly 1 — the producer line "
             "no longer looks as this harness expects; fix the anchor, do not "
             "loosen it." % n)
out = s.replace(new, old)
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(sys.argv[2], "w").write(out)
PY
mrc=$?
if [ "$mrc" -ne 0 ]; then
  no "the mutation could not be applied — case 4 proves nothing"
else
  ok "the mutation applied (anchor matched exactly once, file differs)"
  MSTEP="$TMPROOT/step-prefix.sh"
  if ! extract_step "$MUT" "$MSTEP"; then
    no "could not extract the step from the mutated copy"
  else
    rc=0; run_step "$MSTEP" dquote || rc=$?
    if [ "$rc" -eq 0 ] && has_exact "$DQ_PATH"; then
      no "the PRE-FIX producer kept the double-quote path — this harness cannot detect the bug"
    else
      ok "pre-fix: $DQ_PATH is absent from the set (the false-green, reproduced)"
    fi
    rc=0; run_step "$MSTEP" renameout || rc=$?
    if [ "$rc" -eq 0 ] && has_exact "api/lib/moved.ex"; then
      no "the PRE-FIX producer kept the rename source — this harness cannot detect the bug"
    else
      ok "pre-fix: api/lib/moved.ex is absent from the set (the false-green, reproduced)"
    fi
  fi
fi

echo
echo "case 5/5: NON-VACUITY — the extracted body actually produced a file set"
if [ -s "$CHANGED" ] || { rc=0; run_step "$STEP" dquote || rc=$?; [ -s "$CHANGED" ]; }; then
  ok "the driver produces a non-empty changed set, so the cases above judged something"
else
  no "every case ran against an EMPTY set — the harness is vacuous"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "OK — reland-check.yml's changed-file producer keeps quote-bearing paths and rename sources."
