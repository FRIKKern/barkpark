#!/usr/bin/env bash
#
# which-gates.test.sh — the harness for scripts/which-gates.sh.
#
# THREE THINGS, and the third is the one that matters (task-cb42bf8ab0539891):
#
#   A  the PR #16608 file set — the diff that reddened two REQUIRED contexts
#      because its gate list came from the lane instead of the workflows —
#      answers Cloud gate DISPATCHED and Console gate DISPATCHED.
#   B  api/lib/barkpark/tasks.ex alone answers Cloud/Console SKIPPED and
#      Elixir gate DISPATCHED.
#   C  A FAILED READ IS NEVER BYTE-IDENTICAL TO A SKIP. With one primitive
#      RENAMED AWAY in a scratch copy of the tree, the wrapper must exit
#      non-zero and print a `CANNOT READ:` line naming the missing primitive,
#      and must NOT print a verdict row for it. Without this arm, a wrapper
#      that swallowed a missing primitive as `false` would pass A and B.
#
# The mutation runs against a COPY of the tree (WHICH_GATES_ROOT), never the
# checkout, and the copy's mutation is asserted APPLIED before it is trusted —
# a mutation that did not apply is not a catch, it is a green for the wrong
# reason.
#
# EXIT: 0 all pass · 1 at least one fail · 2 cannot measure.

set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SELF_DIR/.." && pwd)"
SCRIPT="$SELF_DIR/which-gates.sh"

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $*"
}
no() {
  fail=$((fail + 1))
  echo "  FAIL $*"
}
die() {
  echo "which-gates.test: REFUSING — $*" >&2
  exit 2
}

[ -r "$SCRIPT" ] || die "scripts/which-gates.sh is not readable at $SCRIPT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/which-gates-test.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# ── the two file sets, verbatim from the row ────────────────────────────────
cat >"$TMP/set-a" <<'EOF'
cloud/priv/static/app.js
cloud/priv/static/__app.test.mjs
cloud/priv/static/__refusal_copy_census.mjs
cloud/test/barkpark_cloud/console_reader_census_test.exs
EOF
cat >"$TMP/set-b" <<'EOF'
api/lib/barkpark/tasks.ex
EOF

run() { # run <root> <paths-file> -> stdout+stderr in $out, status in $status
  out="$(WHICH_GATES_ROOT="$1" bash "$SCRIPT" --stdin <"$2" 2>&1)"
  status=$?
}

# `Cloud gate  DISPATCHED` with any run of spaces between: assert the WORD, not
# the column width, so a formatting change does not read as a behaviour change.
says() { printf '%s\n' "$out" | grep -Eq "^$1[[:space:]]+$2([[:space:]]|$)"; }

# ── case 1: the #16608 file set ─────────────────────────────────────────────
echo "case 1: the PR #16608 file set dispatches Cloud and Console"
run "$ROOT" "$TMP/set-a"
[ $status -eq 0 ] && ok "exit 0" || no "exit $status, wanted 0 — output: $out"
says "Cloud gate" DISPATCHED && ok "Cloud gate DISPATCHED" || no "Cloud gate not DISPATCHED — output: $out"
says "Console gate" DISPATCHED && ok "Console gate DISPATCHED" || no "Console gate not DISPATCHED — output: $out"
printf '%s\n' "$out" | grep -q '(required)' && ok "required contexts marked from .github/required-checks.json" || no "no (required) marker — output: $out"

# ── case 2: an api-only change ──────────────────────────────────────────────
echo "case 2: api/lib/barkpark/tasks.ex skips Cloud and Console, dispatches Elixir"
run "$ROOT" "$TMP/set-b"
[ $status -eq 0 ] && ok "exit 0" || no "exit $status, wanted 0 — output: $out"
says "Cloud gate" SKIPPED && ok "Cloud gate SKIPPED" || no "Cloud gate not SKIPPED — output: $out"
says "Console gate" SKIPPED && ok "Console gate SKIPPED" || no "Console gate not SKIPPED — output: $out"
printf '%s\n' "$out" | grep -Eq '^Elixir gate \[test\][[:space:]]+DISPATCHED' && ok "Elixir gate [test] DISPATCHED" || no "Elixir gate [test] not DISPATCHED — output: $out"

# ── case 3: the wrapper carries no path set of its own ──────────────────────
# DERIVED, not a hand-list: take the first path segment of every glob the
# primitives DECLARE, and require none of them to appear in the wrapper. The
# two infrastructure roots the wrapper is REQUIRED to read are the allowlist,
# and they are named here rather than inferred so this arm cannot quietly widen.
echo "case 3: which-gates.sh carries none of the primitives' declared path roots"
segments="$(
  {
    "$ROOT/scripts/go-path-escape-check.sh" --print-set 2>/dev/null
    "$ROOT/scripts/cloud-path-escape-check.sh" --print-set cloud 2>/dev/null
    "$ROOT/scripts/console-path-escape-check.sh" --print-set console 2>/dev/null
    "$ROOT/scripts/elixir-path-escape-check.sh" --print-set test 2>/dev/null
  } | sed -E 's|/.*||' | sed '/^$/d' | grep -Ev '^(\*\*|\.github|scripts)$' | sort -u
)"
if [ -z "$segments" ]; then
  no "could not derive any declared path root from the primitives' --print-set — this arm would be vacuous"
else
  leaked=""
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    if grep -qE "(^|[^A-Za-z0-9_./-])${seg}/" "$SCRIPT"; then leaked="$leaked $seg"; fi
  done <<EOF
$segments
EOF
  n="$(printf '%s\n' "$segments" | wc -l | tr -d ' ')"
  if [ -z "$leaked" ]; then ok "no declared path root leaked into the wrapper ($n roots checked)"; else no "the wrapper carries declared path root(s):$leaked"; fi
fi

# ── case 4: THE MUTATION — a primitive renamed away ─────────────────────────
echo "case 4: a renamed-away primitive reads as CANNOT READ, never as SKIPPED"
MUT="$TMP/tree"
mkdir -p "$MUT/scripts" "$MUT/.github/workflows" || die "cannot build the scratch tree"
cp "$ROOT"/scripts/*-path-escape-check.sh "$MUT/scripts/" 2>/dev/null || die "no primitives to copy"
cp "$SCRIPT" "$MUT/scripts/" || die "cannot copy the wrapper"
cp "$ROOT"/.github/workflows/*.yml "$MUT/.github/workflows/" 2>/dev/null || die "no workflows to copy"
cp "$ROOT/.github/required-checks.json" "$MUT/.github/" || die "cannot copy the required-checks spec"

VICTIM="$MUT/scripts/console-path-escape-check.sh"
[ -f "$VICTIM" ] || die "the mutation target is absent from the scratch tree before the mutation"
mv "$VICTIM" "$VICTIM.renamed-away" || die "the mutation could not be applied"
# PROVE IT APPLIED. A mutation that did not land makes the assertion below a
# green for the wrong reason.
if [ ! -e "$VICTIM" ] && [ -e "$VICTIM.renamed-away" ]; then
  ok "mutation APPLIED: console-path-escape-check.sh is absent from the scratch tree"
else
  die "the mutation did not apply — refusing to report a verdict from an unmutated tree"
fi

out="$(WHICH_GATES_ROOT="$MUT" bash "$MUT/scripts/which-gates.sh" --stdin <"$TMP/set-a" 2>&1)"
status=$?
[ $status -ne 0 ] && ok "exit $status (non-zero) under the mutation" || no "exit 0 under the mutation — a failed read went unreported"
printf '%s\n' "$out" | grep -q '^CANNOT READ: scripts/console-path-escape-check\.sh' && ok "CANNOT READ names the missing primitive" || no "no CANNOT READ line naming console-path-escape-check.sh — output: $out"
says "Console gate" SKIPPED && no "the missing primitive printed as SKIPPED — the exact confusion this arm exists to forbid" || ok "no SKIPPED row for the missing primitive"
says "Cloud gate" DISPATCHED && ok "the surviving primitives still answer" || no "the mutation took the whole run down — output: $out"

# ── case 5: the git-range input, hermetically ───────────────────────────────
# The default input is a RANGE, not --stdin, and a range flows through a
# different arm of the script (git diff --no-renames, and the refusal when the
# range does not resolve). Exercised over a throwaway repo built from the same
# scratch tree, so it depends on no ref of the checkout it runs in.
echo "case 5: a git range answers the same as the equivalent --stdin set"
RANGE_TREE="$TMP/range"
mkdir -p "$RANGE_TREE/scripts" "$RANGE_TREE/.github/workflows" || die "cannot build the range tree"
cp "$ROOT"/scripts/*-path-escape-check.sh "$RANGE_TREE/scripts/" || die "no primitives to copy"
cp "$SCRIPT" "$RANGE_TREE/scripts/" || die "cannot copy the wrapper"
cp "$ROOT"/.github/workflows/*.yml "$RANGE_TREE/.github/workflows/" || die "no workflows to copy"
cp "$ROOT/.github/required-checks.json" "$RANGE_TREE/.github/" || die "cannot copy the required-checks spec"
(
  cd "$RANGE_TREE" || exit 2
  git init -q . && git add -A &&
    git -c user.name=t -c user.email=t@t commit -qm base
) >/dev/null 2>&1 || die "could not build the throwaway repo"
mkdir -p "$RANGE_TREE/cloud/priv/static"
echo "// a console static read" >"$RANGE_TREE/cloud/priv/static/app.js"
(
  cd "$RANGE_TREE" || exit 2
  git add -A && git -c user.name=t -c user.email=t@t commit -qm change
) >/dev/null 2>&1 || die "could not commit the change"

out="$(WHICH_GATES_ROOT="$RANGE_TREE" bash "$RANGE_TREE/scripts/which-gates.sh" 'HEAD~1..HEAD' 2>&1)"
status=$?
[ $status -eq 0 ] && ok "a resolvable range exits 0" || no "exit $status over HEAD~1..HEAD — output: $out"
says "Console gate" DISPATCHED && ok "the range input dispatches Console gate" || no "range input did not dispatch Console gate — output: $out"

out="$(WHICH_GATES_ROOT="$RANGE_TREE" bash "$RANGE_TREE/scripts/which-gates.sh" 'refs/remotes/origin/nope...HEAD' 2>&1)"
status=$?
[ $status -ne 0 ] && ok "an unresolvable range exits non-zero" || no "an unresolvable range exited 0 — it would print every gate as SKIPPED: $out"
printf '%s\n' "$out" | grep -q '^CANNOT READ: git range' && ok "an unresolvable range says CANNOT READ, not SKIPPED" || no "no CANNOT READ line for an unresolvable range — output: $out"

# ── the tally ───────────────────────────────────────────────────────────────
echo
echo "# pass $pass / # fail $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
