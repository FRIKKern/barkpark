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
#
# NO `grep -q` ON A PIPE, anywhere in this file. `-q` exits at the first match
# and the writing `printf` takes SIGPIPE; under `set -o pipefail` the pipeline
# then reports 141 and a TRUE assertion reads as a FAIL. It is load- and
# length-dependent, so it stays hidden until the output grows. `>/dev/null`
# drains instead: same verdict, no signal.
says() { printf '%s\n' "$out" | grep -E "^$1[[:space:]]+$2([[:space:]]|$)" >/dev/null; }
has() { printf '%s\n' "$out" | grep -E "$1" >/dev/null; }

# ── case 1: the #16608 file set ─────────────────────────────────────────────
echo "case 1: the PR #16608 file set dispatches Cloud and Console"
run "$ROOT" "$TMP/set-a"
[ $status -eq 0 ] && ok "exit 0" || no "exit $status, wanted 0 — output: $out"
says "Cloud gate" DISPATCHED && ok "Cloud gate DISPATCHED" || no "Cloud gate not DISPATCHED — output: $out"
says "Console gate" DISPATCHED && ok "Console gate DISPATCHED" || no "Console gate not DISPATCHED — output: $out"
has '\(required\)' && ok "required contexts marked from .github/required-checks.json" || no "no (required) marker — output: $out"

# ── case 2: an api-only change ──────────────────────────────────────────────
echo "case 2: api/lib/barkpark/tasks.ex skips Cloud and Console, dispatches Elixir"
run "$ROOT" "$TMP/set-b"
[ $status -eq 0 ] && ok "exit 0" || no "exit $status, wanted 0 — output: $out"
says "Cloud gate" SKIPPED && ok "Cloud gate SKIPPED" || no "Cloud gate not SKIPPED — output: $out"
says "Console gate" SKIPPED && ok "Console gate SKIPPED" || no "Console gate not SKIPPED — output: $out"
has '^Elixir gate \[test\][[:space:]]+DISPATCHED' && ok "Elixir gate [test] DISPATCHED" || no "Elixir gate [test] not DISPATCHED — output: $out"

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
has '^CANNOT READ: scripts/console-path-escape-check\.sh' && ok "CANNOT READ names the missing primitive" || no "no CANNOT READ line naming console-path-escape-check.sh — output: $out"
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
has '^CANNOT READ: git range' && ok "an unresolvable range says CANNOT READ, not SKIPPED" || no "no CANNOT READ line for an unresolvable range — output: $out"

# ── cases 6-8: the payload-census coupling note (task-5ddbd0702c213aec) ─────
# A Go-only diff dispatches an ELIXIR suite because an Elixir census greps the
# Go package and pins its json-tag vocabulary with `==`. The rows above say the
# Cloud gate is DISPATCHED; these arms are about the wrapper also saying WHY,
# and about it saying so only when a tag actually moved.
#
# Every arm runs against a scratch tree (WHICH_GATES_ROOT), never the checkout,
# and every mutation is asserted APPLIED before its verdict is trusted.
census_tree() { # census_tree <dir> — a scratch repo the wrapper can answer over
  mkdir -p "$1/scripts" "$1/.github/workflows" || die "cannot build $1"
  cp "$ROOT"/scripts/*-path-escape-check.sh "$1/scripts/" || die "no primitives to copy"
  cp "$SCRIPT" "$1/scripts/" || die "cannot copy the wrapper"
  cp "$ROOT"/.github/workflows/*.yml "$1/.github/workflows/" || die "no workflows to copy"
  cp "$ROOT/.github/required-checks.json" "$1/.github/" || die "cannot copy the required-checks spec"
  mkdir -p "$1/cloud" "$1/internal" || die "cannot build the subject trees in $1"
  cp -R "$ROOT/cloud/test" "$1/cloud/test" || die "cannot copy the Elixir test tree"
  cp -R "$ROOT/internal/cloudclient" "$1/internal/cloudclient" || die "cannot copy the Go package"
}

CENSUS_FILE_REL="cloud/test/barkpark_cloud/payload_key_set_census_test.exs"
GO_FILE_REL="internal/cloudclient/client.go"
[ -r "$ROOT/$CENSUS_FILE_REL" ] || die "$CENSUS_FILE_REL is absent — cases 6-8 would be vacuous"
[ -r "$ROOT/$GO_FILE_REL" ] || die "$GO_FILE_REL is absent — cases 6-8 would be vacuous"

# The pin value is READ, never written down here — the same discipline the
# wrapper is being tested for. A hand-copied 340 in this file would rot.
REAL_PIN="$(grep -E '^[[:space:]]*@go_tag_pinned[[:space:]]+[0-9]+[[:space:]]*$' "$ROOT/$CENSUS_FILE_REL" | awk '{print $2}')"
case "$REAL_PIN" in
'' | *[!0-9]*) die "could not read @go_tag_pinned out of $CENSUS_FILE_REL — every arm below would be vacuous" ;;
esac
FAKE_PIN=$((REAL_PIN + 659))

echo "case 6: the note is DERIVED from the census — two census states, two reports"
C6="$TMP/c6"
census_tree "$C6"
printf '%s\n' "$GO_FILE_REL" >"$TMP/set-go"

out="$(WHICH_GATES_ROOT="$C6" bash "$C6/scripts/which-gates.sh" --stdin <"$TMP/set-go" 2>&1)"
status=$?
[ $status -eq 0 ] && ok "exit 0 over a Go path" || no "exit $status — output: $out"
has '^PAYLOAD CENSUS COUPLING' && ok "the coupling is announced from the Go side" || no "no coupling note for a Go path — output: $out"
has "$CENSUS_FILE_REL" && ok "the note names the census file" || no "the note does not name the census — output: $out"
has "@go_tag_pinned $REAL_PIN" && ok "the note reports the pin at its REAL value ($REAL_PIN)" || no "the note does not carry @go_tag_pinned $REAL_PIN — output: $out"
has '@go_tag_sites[[:space:]]+a [0-9]+-row register' && ok "the multiplicity register is reported with its row count" || no "no @go_tag_sites row count — output: $out"
state_one="$out"

# THE DISCRIMINATION. Move the pin on the scratch census and demand a DIFFERENT
# report. A checker that prints the same sentence either way read nothing.
python_free_bump() { sed -E "s|^([[:space:]]*@go_tag_pinned)[[:space:]]+[0-9]+[[:space:]]*$|\1 $FAKE_PIN|" "$1" >"$1.bumped" && mv "$1.bumped" "$1"; }
python_free_bump "$C6/$CENSUS_FILE_REL" || die "could not rewrite the scratch census"
if grep -qE "^[[:space:]]*@go_tag_pinned[[:space:]]+${FAKE_PIN}[[:space:]]*$" "$C6/$CENSUS_FILE_REL" &&
  ! grep -qE "^[[:space:]]*@go_tag_pinned[[:space:]]+${REAL_PIN}[[:space:]]*$" "$C6/$CENSUS_FILE_REL"; then
  ok "mutation APPLIED: the scratch census pins $FAKE_PIN, not $REAL_PIN"
else
  die "the pin mutation did not apply — refusing to report a verdict from an unmutated census"
fi

out="$(WHICH_GATES_ROOT="$C6" bash "$C6/scripts/which-gates.sh" --stdin <"$TMP/set-go" 2>&1)"
has "@go_tag_pinned $FAKE_PIN" && ok "the moved pin is reported as $FAKE_PIN" || no "the note did not follow the census — output: $out"
has "@go_tag_pinned $REAL_PIN" && no "the note still prints $REAL_PIN after the census moved — it is not reading the file" || ok "the stale value is gone"
[ "$out" != "$state_one" ] && ok "the two census states produce DIFFERENT reports" || no "byte-identical report across two census states — the note is a decoration"

echo "case 7: NEGATIVE ARM — a Go change that moves no json tag prints nothing"
C7="$TMP/c7"
census_tree "$C7"
(
  cd "$C7" || exit 2
  git init -q . && git add -A && git -c user.name=t -c user.email=t@t commit -qm base
) >/dev/null 2>&1 || die "could not build the throwaway repo for case 7"

# A real behaviour change in the Go package with no tag added, removed or
# renamed. THE ANCHOR IS DERIVED, never a line this file writes down: the first
# `const X = <n> * time.Second` in the package, whose value is doubled. A
# hand-written anchor would `die` the day someone edits that constant, which is
# a harness that reds on innocent edits rather than on regressions.
before="$(grep -c 'json:"' "$C7/$GO_FILE_REL")"
knob="$(grep -oE '^const [A-Za-z_]+ = [0-9]+ \* time\.Second$' "$C7/$GO_FILE_REL" | head -1)"
[ -n "$knob" ] || die "no 'const X = <n> * time.Second' in $GO_FILE_REL — the no-tag arm has no derived anchor"
knob_name="$(printf '%s' "$knob" | awk '{print $2}')"
knob_val="$(printf '%s' "$knob" | awk '{print $4}')"
sed -E "s|^const ${knob_name} = ${knob_val} \\* time.Second$|const ${knob_name} = $((knob_val * 2)) * time.Second|" "$C7/$GO_FILE_REL" >"$C7/$GO_FILE_REL.t" && mv "$C7/$GO_FILE_REL.t" "$C7/$GO_FILE_REL"
after="$(grep -c 'json:"' "$C7/$GO_FILE_REL")"
if (cd "$C7" && ! git diff --quiet -- "$GO_FILE_REL"); then
  ok "mutation APPLIED: the Go package changed"
else
  die "the no-tag Go edit did not apply — this arm would be vacuous"
fi
[ "$before" = "$after" ] && ok "and it moved NO json tag line ($before before, $after after)" || die "the no-tag edit moved a tag line — it cannot test the negative arm"
(cd "$C7" && git add -A && git -c user.name=t -c user.email=t@t commit -qm notag) >/dev/null 2>&1 || die "could not commit the no-tag change"

out="$(WHICH_GATES_ROOT="$C7" bash "$C7/scripts/which-gates.sh" 'HEAD~1..HEAD' 2>&1)"
status=$?
[ $status -eq 0 ] && ok "exit 0" || no "exit $status — output: $out"
says "Cloud gate" DISPATCHED && ok "the Cloud gate still reads DISPATCHED (the rows are unchanged)" || no "Cloud gate row lost — output: $out"
has '^PAYLOAD CENSUS COUPLING' && no "the note fired on a Go change with no tag delta — it will be ignored inside a week" || ok "no coupling note: nothing in the census can have moved"

# And the same tree, ONE tag added, MUST fire — or the arm above proves nothing:
# silence is only evidence next to a demonstrated noise. The insertion point is
# DERIVED too: after the FIRST json-tagged line in the package, whatever it is.
first_tag_line="$(grep -nE 'json:"[^"]+"' "$C7/$GO_FILE_REL" | head -1 | sed 's|:.*||')"
[ -n "$first_tag_line" ] || die "no json-tagged line in $GO_FILE_REL — the positive half has no derived insertion point"
awk -v at="$first_tag_line" 'NR==at{print; print "\tWhichGatesScratch string `json:\"which_gates_scratch\"`"; next} {print}' "$C7/$GO_FILE_REL" >"$C7/$GO_FILE_REL.t" && mv "$C7/$GO_FILE_REL.t" "$C7/$GO_FILE_REL"
if grep -q 'json:"which_gates_scratch"' "$C7/$GO_FILE_REL"; then
  ok "mutation APPLIED: one json tag added to the scratch Go package"
else
  die "the tag mutation did not apply — the positive half of this arm would be vacuous"
fi
(cd "$C7" && git add -A && git -c user.name=t -c user.email=t@t commit -qm addtag) >/dev/null 2>&1 || die "could not commit the tag change"
out="$(WHICH_GATES_ROOT="$C7" bash "$C7/scripts/which-gates.sh" 'HEAD~1..HEAD' 2>&1)"
has '^PAYLOAD CENSUS COUPLING' && ok "one added tag DOES fire it — the negative arm is a discrimination, not silence" || no "a real tag addition did not fire the note — output: $out"
has 'added \[which_gates_scratch\]  removed \[\]' && ok "the delta names the tag it saw" || no "the delta does not name suspended_since — output: $out"

echo "case 8: NON-VACUITY — a census it cannot read is never a silent pass"
C8="$TMP/c8"
census_tree "$C8"
mv "$C8/cloud/test" "$C8/cloud/test-renamed-away" || die "the mutation could not be applied"
if [ ! -d "$C8/cloud/test" ] && [ -d "$C8/cloud/test-renamed-away" ]; then
  ok "mutation APPLIED: the Elixir test tree is gone from the scratch tree"
else
  die "the rename did not apply — refusing to report a verdict from an unmutated tree"
fi
out="$(WHICH_GATES_ROOT="$C8" bash "$C8/scripts/which-gates.sh" --stdin <"$TMP/set-go" 2>&1)"
status=$?
[ $status -ne 0 ] && ok "exit $status (non-zero) with the census tree renamed away" || no "exit 0 — a vanished census passed silently: $out"
has '^CANNOT READ: .*cloud/test' && ok "CANNOT READ names the tree it could not read" || no "no CANNOT READ naming the test tree — output: $out"
has '^PAYLOAD CENSUS COUPLING' && no "it printed a coupling note with no census to read it from" || ok "no note invented over a missing census"

# the second half: the census is THERE, but its pin symbols are not.
C8B="$TMP/c8b"
census_tree "$C8B"
pins_before="$(grep -cE '^[[:space:]]*@[a-z_]+[[:space:]]+-?[0-9]+[[:space:]]*$' "$C8B/$CENSUS_FILE_REL")"
grep -vE '^[[:space:]]*@[a-z_]+[[:space:]]+-?[0-9]+[[:space:]]*$' "$C8B/$CENSUS_FILE_REL" >"$C8B/$CENSUS_FILE_REL.t" && mv "$C8B/$CENSUS_FILE_REL.t" "$C8B/$CENSUS_FILE_REL"
pins_after="$(grep -cE '^[[:space:]]*@[a-z_]+[[:space:]]+-?[0-9]+[[:space:]]*$' "$C8B/$CENSUS_FILE_REL" || true)"
if [ "$pins_before" -gt 0 ] && [ "$pins_after" -eq 0 ]; then
  ok "mutation APPLIED: $pins_before pin symbols removed from the scratch census, 0 remain"
else
  die "the pin-stripping mutation did not apply ($pins_before -> $pins_after) — this arm would be vacuous"
fi
out="$(WHICH_GATES_ROOT="$C8B" bash "$C8B/scripts/which-gates.sh" --stdin <"$TMP/set-go" 2>&1)"
status=$?
[ $status -ne 0 ] && ok "exit $status (non-zero) with the pin symbols absent" || no "exit 0 — a census with no pins passed silently: $out"
has "^CANNOT READ: $CENSUS_FILE_REL" && ok "CANNOT READ names the census whose pins vanished" || no "no CANNOT READ naming the pin-less census — output: $out"

# ── the tally ───────────────────────────────────────────────────────────────
echo
echo "# pass $pass / # fail $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
