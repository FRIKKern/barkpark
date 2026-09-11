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

# THE CLOUD GATE PRINTS TWO ROWS — `[cloud]` and `[census]`. cloud.yml's
# dispatcher answers two path sets off one primitive, so the wrapper's
# disambiguator (one primitive, more than one call site) names the set. The
# `[census]` half only became VISIBLE to the scan when the dispatchers pinned
# their path-set script to the merge ref (task-3a81e68f7027ca98): before that
# the literal-only call-site pattern silently missed the here-string form, and
# the Cloud gate's cheaper tier was dispatched with nothing reporting it.
#
# THE CENSUS TIER DERIVES ITS CORPUS FROM A FILE IN THE TREE, so any scratch
# tree the wrapper is pointed at must carry that file — otherwise `--match
# census` REFUSES (exit 2), the wrapper reports CANNOT READ, and an INCOMPLETE
# FIXTURE reads as a broken instrument.
CENSUS_DECL="$(bash "$ROOT/scripts/cloud-path-escape-check.sh" --census-source)"
[ -n "$CENSUS_DECL" ] || die "cloud-path-escape-check.sh --census-source printed nothing — cannot populate the scratch trees"
carry_census_decl() { # carry_census_decl <tree-root>
  mkdir -p "$1/$(dirname "$CENSUS_DECL")" || die "cannot build $1/$(dirname "$CENSUS_DECL")"
  cp "$ROOT/$CENSUS_DECL" "$1/$CENSUS_DECL" || die "cannot copy the census declaration into $1"
}
has() { printf '%s\n' "$out" | grep -E "$1" >/dev/null; }

# ── case 1: the #16608 file set ─────────────────────────────────────────────
echo "case 1: the PR #16608 file set dispatches Cloud and Console"
run "$ROOT" "$TMP/set-a"
[ $status -eq 0 ] && ok "exit 0" || no "exit $status, wanted 0 — output: $out"
says "Cloud gate \[cloud\]" DISPATCHED && ok "Cloud gate DISPATCHED" || no "Cloud gate not DISPATCHED — output: $out"
says "Console gate" DISPATCHED && ok "Console gate DISPATCHED" || no "Console gate not DISPATCHED — output: $out"
has '\(required\)' && ok "required contexts marked from .github/required-checks.json" || no "no (required) marker — output: $out"

# ── case 2: an api-only change ──────────────────────────────────────────────
echo "case 2: api/lib/barkpark/tasks.ex skips Cloud and Console, dispatches Elixir"
run "$ROOT" "$TMP/set-b"
[ $status -eq 0 ] && ok "exit 0" || no "exit $status, wanted 0 — output: $out"
says "Cloud gate \[cloud\]" SKIPPED && ok "Cloud gate SKIPPED" || no "Cloud gate not SKIPPED — output: $out"
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
carry_census_decl "$MUT"

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
says "Cloud gate \[cloud\]" DISPATCHED && ok "the surviving primitives still answer" || no "the mutation took the whole run down — output: $out"

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
carry_census_decl "$RANGE_TREE"
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
says "Cloud gate \[cloud\]" DISPATCHED && ok "the Cloud gate still reads DISPATCHED (the rows are unchanged)" || no "Cloud gate row lost — output: $out"
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
# WHAT THIS ARM ASSERTS, AND WHY IT CHANGED (2026-09-10, task-1cea7edd271d588b).
# It used to demand `CANNOT READ` + a non-zero exit for a census with no
# `@name <integer>` pin. That premise was falsified by a file on main:
# metrics_envelope_reader_census_test.exs (#17169) reads the same Go package
# and asserts over its json tags with SET comparisons inside the test bodies —
# it never had an attribute pin to lose. Under the old rule the deriver exited
# 1 for EVERY Go diff, and its own harness read that as a Console-gate bug.
# A file's content cannot distinguish "the pins were deleted" from "the pins
# were never written", so the property that IS provable is asserted instead:
# the note still fires, and it never prints a pin it did not read.
[ $status -eq 0 ] && ok "exit 0 — an unpinned census is a SHAPE, not a failed read" || no "exit $status with the pins stripped — output: $out"
has '^PAYLOAD CENSUS COUPLING' && ok "the coupling still fires with the pins stripped (it is the DISPATCH that matters)" || no "the note vanished with the pins stripped — output: $out"
has "@go_tag_pinned $REAL_PIN" && no "it printed @go_tag_pinned $REAL_PIN over a census that no longer carries it — the value is remembered, not read" || ok "no stale pin value survived the strip"
has "^ {6}\\($CENSUS_FILE_REL:\\)" && no "it printed a BLANK pin row for the stripped census" || ok "no blank pin row invented for the stripped census"

# 8c: the census has NEITHER a pin nor a register. It is REPORTED as unpinned —
# never rendered as though it were pinned, and never silently dropped.
C8C="$TMP/c8c"
census_tree "$C8C"
regs_before="$(grep -cE '^[[:space:]]*@[a-z_]+ %\{[[:space:]]*$' "$C8C/$CENSUS_FILE_REL")"
grep -vE '^[[:space:]]*@[a-z_]+([[:space:]]+-?[0-9]+[[:space:]]*|[[:space:]]%\{[[:space:]]*)$' "$C8C/$CENSUS_FILE_REL" >"$C8C/$CENSUS_FILE_REL.t" && mv "$C8C/$CENSUS_FILE_REL.t" "$C8C/$CENSUS_FILE_REL"
pins_left="$(grep -cE '^[[:space:]]*@[a-z_]+[[:space:]]+-?[0-9]+[[:space:]]*$' "$C8C/$CENSUS_FILE_REL" || true)"
regs_left="$(grep -cE '^[[:space:]]*@[a-z_]+ %\{[[:space:]]*$' "$C8C/$CENSUS_FILE_REL" || true)"
if [ "$regs_before" -gt 0 ] && [ "$pins_left" -eq 0 ] && [ "$regs_left" -eq 0 ]; then
  ok "mutation APPLIED: every pin AND every register ($regs_before) stripped from the scratch census"
else
  die "the apparatus-stripping mutation did not apply (pins $pins_left, registers $regs_left of $regs_before) — this arm would be vacuous"
fi
out="$(WHICH_GATES_ROOT="$C8C" bash "$C8C/scripts/which-gates.sh" --stdin <"$TMP/set-go" 2>&1)"
status=$?
[ $status -eq 0 ] && ok "exit 0 over a census with no pin apparatus at all" || no "exit $status — output: $out"
has '^ {6}NO ATTRIBUTE PIN' && ok "the unpinned census is REPORTED as unpinned, not silently rendered as pinned" || no "no NO ATTRIBUTE PIN line for a census with no apparatus — output: $out"
has 'its committed pins, read out of that file just now' &&
  { printf '%s\n' "$out" | grep -A2 "payload_key_set_census_test.exs (@" | grep -E '@[a-z_]+ +[0-9]+' >/dev/null &&
    no "it named a pin on a census that has none — output: $out" || ok "no pin named for the apparatus-less census"; } ||
  ok "no pin named for the apparatus-less census"

# ── case 9: A QUOTED COMMAND IS NOT A CALL SITE ────────────────────────────
# THE REGRESSION THIS ARM EXISTS FOR (2026-09-10, task-1cea7edd271d588b).
# PR #17141 gave console-harness.yml's dispatcher a refusal message that NAMES
# the primitive and its flag inside an `echo "::error::…"`. That is not a
# comment, so the old scan counted it as a SECOND call site: the Console gate
# printed TWICE, and — because the label disambiguator fires when one primitive
# has more than one call site — both rows came out `Console gate [console]`.
# Cases 1, 2 and 5 all went red looking for a `Console gate` row, in a job that
# blocks nothing, for a day. Two halves, and the second is the one that matters.
echo "case 9: a QUOTED command is not a dispatch call site"
run "$ROOT" "$TMP/set-a"
consoles="$(printf '%s\n' "$out" | grep -cE '^Console gate' || true)"
[ "$consoles" -eq 1 ] && ok "exactly ONE Console gate row over the real tree (a quoted command adds none)" || no "$consoles Console gate rows — output: $out"
has '^Console gate[[:space:]]+DISPATCHED' && ok "and it is labelled 'Console gate', not disambiguated by a phantom second set" || no "no bare 'Console gate' label — output: $out"

# THE MUTATION. Turn the real invocation into prose — the same shape the refusal
# message already has — and demand the row DISAPPEAR. Without this the fix above
# could be a scan that simply de-duplicates, which would still print a row for a
# workflow that dispatches nothing.
C9="$TMP/c9"
census_tree "$C9"
C9_WF="$C9/.github/workflows/console-harness.yml"
# THE PINNED SHAPE (task-3a81e68f7027ca98): the dispatcher shells
# `bash "$pin_script" --match console`, and the primitive's literal name lives
# in the step's `pin_script=` assignment. The mutation turns THAT invocation
# into prose and leaves both mentions — the assignment and the refusal message
# — standing, so the arm still discriminates invocation from mention.
inv_before="$(grep -cF 'bash "$pin_script" --match console' "$C9_WF" || true)"
[ "$inv_before" -eq 1 ] || die "expected exactly 1 pinned invocation in console-harness.yml, found $inv_before — this arm's mutation has no target"
sed -E 's;bash "\$pin_script" (--match console);echo "would run scripts/console-path-escape-check.sh \1";' "$C9_WF" >"$C9_WF.t" && mv "$C9_WF.t" "$C9_WF"
inv_after="$(grep -cF 'bash "$pin_script" --match console' "$C9_WF" || true)"
mention_after="$(grep -cF 'scripts/console-path-escape-check.sh --match console' "$C9_WF" || true)"
if [ "$inv_after" -eq 0 ] && [ "$mention_after" -gt 0 ]; then
  ok "mutation APPLIED: the invocation is gone, $mention_after quoted MENTION(s) of it remain"
else
  die "the invocation mutation did not apply (invocations $inv_after, mentions $mention_after) — this arm would be vacuous"
fi
out="$(WHICH_GATES_ROOT="$C9" bash "$C9/scripts/which-gates.sh" --stdin <"$TMP/set-a" 2>&1)"
has '^Console gate' && no "a workflow that only MENTIONS the primitive still printed a Console gate row — the scan reads prose as dispatch: $out" || ok "no Console gate row from mentions alone — the scan reads INVOCATIONS"
says "Cloud gate \[cloud\]" DISPATCHED && ok "the surviving dispatchers still answer under the mutation" || no "the mutation took out more than its target — output: $out"

# ── the tally ───────────────────────────────────────────────────────────────
echo
echo "# pass $pass / # fail $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
