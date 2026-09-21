#!/usr/bin/env bash
# Self-test for scripts/pds-charter-anchors-check.sh.
#
# Every arm names what it proves. The point of the paired arms is that
# "present in the file" is not "fires when it should": each RED arm mutates one
# thing and must red, each QUIET arm must stay green, and the REVERT arm
# reproduces the pre-fix charter text verbatim so the check is proven to catch
# the exact regression it was written for.
#
# Credential-free, target-free, no network. Usage: bash scripts/pds-charter-anchors-check_test.sh
#
# WIRED (task-4bbe6e0b761d58c5): this file, and the live checker beside it, both
# run on the `PDS census / parity / scratch-target harnesses` job in
# .github/workflows/shell-harnesses.yml. `scripts/pds-*.sh` is already a
# workflow-level path AND a roster row for that job, so an edit to either half
# — or to .claude/workflows/bp-pds-charter.md, also a row — dispatches the job.
# A revert of the charter anchors is now caught by CI, not only by hand.
#
# NO `printf ... | grep -q` IN AN ARM, and it is load-bearing. Every arm used to
# read `printf '%s' "$out" | grep -q 'X'`; under `set -o pipefail` grep -q exits
# on the first match, printf takes SIGPIPE, and the pipeline returns 141 — so an
# arm whose subject REDDED CORRECTLY reported FAIL. Measured before wiring on
# the unmodified tree: 3 of 5 runs red, the failing arm set varying run to run
# (4/5/11, then 5/11). A here-string has no producer process to kill. Arming a
# flaky harness is arming a broken one, so this had to be fixed in the same PR.
# Baseline: 32 passed, 0 failed (20 before arm E added arms 21-29; 29 before
# arms 30-32 pinned where the roster LIVES, task-67a7d8d5b2fd4482).

# shellcheck disable=SC2016  # backticks inside single quotes are literal citation syntax, not expansions
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/pds-charter-anchors-check.sh"
HARNESS='scripts/pds-pull-proof.sh'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail + 1)); }

# run <fixture-file> [env...] -> sets $out and $rc
run() { out="$(bash "$CHECK" "$1" 2>&1)"; rc=$?; }

# run_d <fixture-file> <dupe-ceiling> <unclassified-ceiling> -> sets $out and $rc
# Arm D's live ceilings are the CHARTER's (20 and 8), so a two-line fixture can
# never cross them. Every arm-D fixture therefore names its own ceilings; the
# fixture is what is under test, not the production baseline.
run_d() {
  out="$(PDS_ANCHOR_DUPE_CEILING="$2" PDS_ANCHOR_UNCLASSIFIED_CEILING="$3" bash "$CHECK" "$1" 2>&1)"
  rc=$?
}

# A fixture with N bare legacy citations padded in, so arm B can be exercised
# independently of arm A.
pad_bare() { # <count>
  local i=0
  while [ "$i" -lt "$1" ]; do printf 'legacy cite pds-pull-proof.sh:%s\n' "$((100 + i))"; i=$((i + 1)); done
}

# The same, for arm C's FILE-LESS `:NNN` form. Deliberately a DIFFERENT padder:
# arm B's pattern requires the filename and arm C's requires its absence, so one
# fixture can never satisfy both and a gain in one form cannot mask a loss in
# the other.
pad_fileless() { # <count>
  local i=0
  while [ "$i" -lt "$1" ]; do printf 'file-less cite (`:%s`)\n' "$((100 + i))"; i=$((i + 1)); done
}

# ── ARM 1 (QUIET): the real charter on the real tree must pass ───────────────
run "$REPO_ROOT/.claude/workflows/bp-pds-charter.md"
if [ "$rc" -eq 0 ]; then ok "ARM 1 QUIET — the live charter passes"
else bad "ARM 1 QUIET — the live charter passes" "$out"; fi

# ── ARM 2 (RED): an anchor whose literal is no longer in the file ────────────
{ printf 'anchor: `%s`@`this string is not in the harness, 7f3a91`\n' "$HARNESS"; pad_bare 15; } > "$TMP/rotted.md"
run "$TMP/rotted.md"
if [ "$rc" -ne 0 ] && grep -q 'ROTTED' <<<"$out"; then ok "ARM 2 RED — a rotted anchor reds (ROTTED)"
else bad "ARM 2 RED — a rotted anchor reds (ROTTED)" "rc=$rc $out"; fi

# ── ARM 3 (RED): an anchor matching more than one line is ambiguous ──────────
{ printf 'anchor: `%s`@`  return 1`\n' "$HARNESS"; pad_bare 15; } > "$TMP/ambig.md"
run "$TMP/ambig.md"
if [ "$rc" -ne 0 ] && grep -q 'AMBIGUOUS' <<<"$out"; then ok "ARM 3 RED — a multi-match anchor reds (AMBIGUOUS)"
else bad "ARM 3 RED — a multi-match anchor reds (AMBIGUOUS)" "rc=$rc $out"; fi

# ── ARM 4 (RED): a line-wrapped anchor must not silently vanish ──────────────
{ printf 'anchor: `%s`@`spent_now=$((spent\n + 1))`\n' "$HARNESS"; pad_bare 15; } > "$TMP/wrapped.md"
run "$TMP/wrapped.md"
if [ "$rc" -ne 0 ] && grep -q 'MALFORMED' <<<"$out"; then ok "ARM 4 RED — a wrapped anchor reds (MALFORMED)"
else bad "ARM 4 RED — a wrapped anchor reds (MALFORMED)" "rc=$rc $out"; fi

# ── ARM 5 (RED): a NEW bare line citation breaks the ratchet ─────────────────
pad_bare 16 > "$TMP/overceiling.md"
run "$TMP/overceiling.md"
if [ "$rc" -ne 0 ] && grep -q 'ceiling' <<<"$out"; then ok "ARM 5 RED — a new bare pds-pull-proof.sh:NNN cite reds (arm B)"
else bad "ARM 5 RED — a new bare pds-pull-proof.sh:NNN cite reds (arm B)" "rc=$rc $out"; fi

# ── ARM 6 (QUIET): FEWER bare citations is progress, never a red ─────────────
pad_bare 3 > "$TMP/underceiling.md"
run "$TMP/underceiling.md"
if [ "$rc" -eq 0 ] && grep -q 'PROGRESS' <<<"$out"; then ok "ARM 6 QUIET — improvement prints PROGRESS and exits 0"
else bad "ARM 6 QUIET — improvement prints PROGRESS and exits 0" "rc=$rc $out"; fi

# ── ARM 7 (QUIET): a good anchor plus unrelated prose stays green ────────────
{ printf 'prose that mentions nothing.\n'
  printf 'anchor: `%s`@`spent_now=$((spent + 1))`\n' "$HARNESS"
  printf 'more unrelated prose, edited freely.\n'; pad_bare 15; } > "$TMP/good.md"
run "$TMP/good.md"
if [ "$rc" -eq 0 ]; then ok "ARM 7 QUIET — a resolving anchor + unrelated edits stay green"
else bad "ARM 7 QUIET — a resolving anchor + unrelated edits stay green" "$out"; fi

# ── ARM 8 (QUIET): the documented `<path>` placeholder is not an anchor ──────
{ printf 'the form is `<path>`@`<literal>`\n'; pad_bare 15; } > "$TMP/placeholder.md"
run "$TMP/placeholder.md"
if [ "$rc" -eq 0 ]; then ok "ARM 8 QUIET — the <path> placeholder is skipped, not chased"
else bad "ARM 8 QUIET — the <path> placeholder is skipped, not chased" "$out"; fi

# ── ARM 9 (RED, THE REVERT ARM): the pre-fix D92/D93 text, verbatim ──────────
# This is the exact wording this PR replaced. If someone reverts the charter
# edit, the bare :1330/:1334/:562/:661 citations come back, arm B's count goes
# to 17 over a ceiling of 15... except those bare cites carry no filename, so
# they are NOT counted — which is precisely why the REAL regression signal is
# arm A: the four anchors disappear and nothing resolves them. So this arm
# asserts the thing that actually distinguishes the two states: the reverted
# text yields ZERO parsed anchors.
{ cat <<'PRE'
- **PDS-D92** A failed gate (b) `return 1`s at `:1330` BEFORE `spent_now=$((spent + 1))` at `:1334`.
- **PDS-D93** pouncing breaks gate (a) (`DEPLOYED_SHA` is pinned once at `:562`) AND step 0b (`:661`).
PRE
  pad_bare 15; } > "$TMP/reverted.md"
run "$TMP/reverted.md"
if [ "$rc" -eq 0 ] && grep -q 'anchors checked ..... 0' <<<"$out"; then
  ok "ARM 9 REVERT — the pre-fix text carries ZERO checkable anchors (the defect this PR removes)"
else bad "ARM 9 REVERT — the pre-fix text carries ZERO checkable anchors" "rc=$rc $out"; fi

# ── ARM 10 (QUIET/CONTROL): the shipped D92+D93 text carries FOUR ────────────
{ sed -n '/PDS-D92 — The headroom gate/,/aggregate quiet, not BEAM freshness/p' \
    "$REPO_ROOT/.claude/workflows/bp-pds-charter.md"; pad_bare 15; } > "$TMP/shipped.md"
run "$TMP/shipped.md"
if [ "$rc" -eq 0 ] && grep -q 'anchors checked ..... 4' <<<"$out"; then
  ok "ARM 10 CONTROL — the shipped D92/D93 text carries exactly 4 resolving anchors"
else bad "ARM 10 CONTROL — the shipped D92/D93 text carries exactly 4 resolving anchors" "rc=$rc $out"; fi


# ── ARM 11 (RED): a NEW file-less `:NNN` citation breaks arm C's ratchet ─────
# 642 = the shipped ceiling (641) + 1. The fixture carries NO filename-bearing
# cite, so arm B sees 0 and cannot be what reds here.
{ pad_fileless 642; } > "$TMP/fileless_over.md"
run "$TMP/fileless_over.md"
if [ "$rc" -ne 0 ] && grep -q 'file-less `:NNN` citation was added' <<<"$out"; then
  ok "ARM 11 RED — a new file-less \`:NNN\` cite reds (arm C)"
else bad "ARM 11 RED — a new file-less \`:NNN\` cite reds (arm C)" "rc=$rc $out"; fi

# ── ARM 12 (QUIET): FEWER file-less citations is progress, never a red ───────
{ pad_fileless 3; pad_bare 15; } > "$TMP/fileless_under.md"
run "$TMP/fileless_under.md"
if [ "$rc" -eq 0 ] && grep -q 'file-less citations are down to 3' <<<"$out"; then
  ok "ARM 12 QUIET — improvement prints PROGRESS for arm C and exits 0"
else bad "ARM 12 QUIET — improvement prints PROGRESS for arm C and exits 0" "rc=$rc $out"; fi

# ── ARM 13 (RED, THE REVERT ARM): the pre-fix D101/D116 text, verbatim ──────
# The exact citations this PR removed. Every one of them is file-less, so arm B
# never counted them and arm C's ceiling is not crossed by six — which is the
# whole point: the signal that distinguishes reverted from shipped is arm A,
# and the reverted text parses ZERO anchors.
{ cat <<'PRE'
- **PDS-D101** `canonical_order` (`:2177-2191`) enforces ladder order only WITHIN one process, and
  reuses a parked bundle for 0 attempts when the sha held (`:1249-1261`).
- **PDS-D116** `canonical_order()` (`:2240`) plus step 4's PULL_BUNDLE-this-run guard (`:1665`) —
  not `step_6`, whose only cross-step precondition is `PULL_BUNDLE` (`:2003`); `run_steps` (`:2256`).
PRE
  pad_bare 15; } > "$TMP/reverted_d101.md"
run "$TMP/reverted_d101.md"
if [ "$rc" -eq 0 ] && grep -q 'anchors checked ..... 0' <<<"$out"; then
  ok "ARM 13 REVERT — the pre-fix D101/D116 text carries ZERO checkable anchors"
else bad "ARM 13 REVERT — the pre-fix D101/D116 text carries ZERO checkable anchors" "rc=$rc $out"; fi

# ── ARM 14 (QUIET/CONTROL): the shipped D101+D116 text carries EIGHT ─────────
# Eight, not seven, since the 2026-09-18 sweep (pds-bl-charter-line-refs-stale)
# turned PDS-D113's last bare `pds-pull-proof.sh:NNN` cite into a content
# anchor: the slice now carries ZERO surviving bare cites, so pad_bare 14 sits
# one under arm B's ceiling of 15. This count is the slice's, read from the
# live charter — bump it when a D101..D116 citation is re-anchored, never pad.
{ sed -n '/PDS-D101 — Anything touching rungs/,/arm C ratchets the file-less/p' \
    "$REPO_ROOT/.claude/workflows/bp-pds-charter.md"; pad_bare 14; } > "$TMP/shipped_d101.md"
run "$TMP/shipped_d101.md"
if [ "$rc" -eq 0 ] && grep -q 'anchors checked ..... 8' <<<"$out"; then
  ok "ARM 14 CONTROL — the shipped D101/D116 text carries exactly 8 resolving anchors"
else bad "ARM 14 CONTROL — the shipped D101/D116 text carries exactly 8 resolving anchors" "rc=$rc $out"; fi

# ── ARM 15 (RED, arm D): the same number DEFINED TWICE in list form ──────────
{ printf -- '- **PDS-D900 — FIRST DEFINITION.** x\n- **PDS-D900 — SECOND DEFINITION.** y\n'; pad_bare 15; } > "$TMP/dupe_list.md"
run_d "$TMP/dupe_list.md" 0 0
if [ "$rc" -ne 0 ] && grep -q 'PDS-D identifiers are defined twice' <<<"$out"; then
  ok "ARM 15 RED — a duplicated D-number in LIST form reds (arm D)"
else bad "ARM 15 RED — a duplicated D-number in LIST form reds (arm D)" "rc=$rc $out"; fi

# ── ARM 16 (RED, arm D): the HEADING form — the lens the first draft missed ──
# This arm is the whole reason arm D uses pds-record-parity.sh's definition
# lens. A list-item-only pattern reads the `### PDS-D<n>` half as invisible and
# reports a reassuring 0 duplicates on a charter that has one.
{ printf -- '### PDS-D900 — FIRST DEFINITION, HEADING FORM.\n- **PDS-D900 — SECOND DEFINITION.** y\n'; pad_bare 15; } > "$TMP/dupe_head.md"
run_d "$TMP/dupe_head.md" 0 0
if [ "$rc" -ne 0 ] && grep -q 'PDS-D identifiers are defined twice' <<<"$out"; then
  ok "ARM 16 RED — a duplicated D-number in HEADING form reds (arm D lens)"
else bad "ARM 16 RED — a duplicated D-number in HEADING form reds (arm D lens)" "rc=$rc $out"; fi

# ── ARM 17 (QUIET/CONTROL, arm D): two DISTINCT numbers, both forms, no red ──
# Without this, arms 15 and 16 are satisfiable by a check that reds on any two
# definitions at all.
{ printf -- '### PDS-D900 — ONE DECISION.\n- **PDS-D901 — ANOTHER DECISION.** y\n'; pad_bare 15; } > "$TMP/dupe_none.md"
run_d "$TMP/dupe_none.md" 0 0
if [ "$rc" -eq 0 ] && grep -q 'duplicate D-numbers . 0' <<<"$out"; then
  ok "ARM 17 CONTROL — two DISTINCT numbers in both forms stay green (arm D)"
else bad "ARM 17 CONTROL — two DISTINCT numbers in both forms stay green (arm D)" "rc=$rc $out"; fi

# ── ARM 18 (RED, arm D): a definition with no em-dash discriminator ──────────
# The lens must not be able to go blind quietly: a definition written with the
# wrong separator is invisible to the duplicate count, so it is COUNTED and
# ratcheted instead of ignored.
{ printf -- '- **PDS-D900 - WRONG SEPARATOR, A HYPHEN.** x\n'; pad_bare 15; } > "$TMP/undiscriminated.md"
run_d "$TMP/undiscriminated.md" 0 0
if [ "$rc" -ne 0 ] && grep -q 'definition-shaped lines carry no' <<<"$out"; then
  ok "ARM 18 RED — a definition with no discriminator reds (arm D unclassified)"
else bad "ARM 18 RED — a definition with no discriminator reds (arm D unclassified)" "rc=$rc $out"; fi

# ── ARM 19 (RED, arm D): the definitions FLOOR is a precondition ─────────────
# On the CANONICAL charter only. A floor above the true count stands in for the
# pattern breaking: without it, a broken pattern prints `duplicate D-numbers . 0`
# and reads as a pass.
out="$(PDS_ANCHOR_DEF_FLOOR=99999 bash "$CHECK" "$REPO_ROOT/.claude/workflows/bp-pds-charter.md" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'below the floor of 99999' <<<"$out"; then
  ok "ARM 19 RED — a definition count under the floor reds (arm D precondition)"
else bad "ARM 19 RED — a definition count under the floor reds (arm D precondition)" "rc=$rc $out"; fi

# ── ARM 20 (QUIET, arm D): the floor is SKIPPED off the canonical charter ────
# Paired with arm 19: the floor must be scoped, or every fixture above reds on
# it and arms 2-18 measure nothing.
{ printf -- '- **PDS-D900 — ONE DECISION.** x\n'; pad_bare 15; } > "$TMP/floor_skip.md"
out="$(PDS_ANCHOR_DEF_FLOOR=99999 bash "$CHECK" "$TMP/floor_skip.md" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'floor SKIPPED' <<<"$out"; then
  ok "ARM 20 QUIET — the floor is skipped off the canonical charter"
else bad "ARM 20 QUIET — the floor is skipped off the canonical charter" "rc=$rc $out"; fi

# ════════════════════════════════════════════════════════════════════════════
# ARM E — the trigger-coverage ratchet (task-73fc9e5d14308997).
#
# Arm E asks whether a path an anchor CITES can DISPATCH the job that checks the
# anchor. Every arm below runs against the REAL charter, because the anchors are
# the subject; what varies is the WORKFLOW arm E is pointed at, via
# PDS_ANCHOR_WORKFLOW. A fixture workflow is the only way to move coverage
# without editing .github/, which is not this script's fence.
CHARTER_REAL="$REPO_ROOT/.claude/workflows/bp-pds-charter.md"

# run_e <workflow> <gap-ceiling> -> sets $out and $rc
run_e() {
  out="$(PDS_ANCHOR_WORKFLOW="$1" PDS_ANCHOR_TRIGGER_GAP_CEILING="$2" \
        bash "$CHECK" "$CHARTER_REAL" 2>&1)"
  rc=$?
}

# A fixture workflow arm E can parse: BOTH halves, independently settable.
# <paths-glob> <roster-glob>
mk_wf() {
  printf 'on:\n  pull_request:\n    paths:\n      - "%s"\n  push:\n    branches: [main]\njobs:\n  changes:\n    steps:\n      - run: |\n          roster='"'"'\n          pds-harnesses %s\n'"'"'\n' "$1" "$2"
}

# ── ARM 21 (QUIET/CONTROL, arm E): total coverage stays GREEN ────────────────
# Paired with arm 22. Without this, arm 22 is satisfiable by an arm E that reds
# on every workflow it is ever shown — the "a control that fires on everything
# proves nothing" failure. `**` in BOTH halves covers every cited path, so the
# gap is 0 and the run must pass.
mk_wf '**' '**' > "$TMP/wf_full.yml"
run_e "$TMP/wf_full.yml" 11
if [ "$rc" -eq 0 ] && grep -q 'untriggerable cites . 0 ' <<<"$out"; then
  ok "ARM 21 CONTROL — a workflow covering every cited path scores 0 and stays green (arm E)"
else bad "ARM 21 CONTROL — a workflow covering every cited path scores 0 and stays green (arm E)" "rc=$rc $out"; fi

# ── ARM 22 (RED, arm E): the ratchet fires when the gap EXCEEDS the ceiling ──
# This is the arm that fails if arm E's comparison is inverted, its ceiling
# deleted, or its verdict demoted to a PROGRESS line.
#
# RE-POINTED AT A FIXTURE 2026-09-18 (task-ceada0e53f6d2f1d), NOT DELETED. It
# used to run against the REAL .github/workflows/shell-harnesses.yml at ceiling
# 0, because the real gap was 11 and any ceiling below it reproduced the red.
# That repair put all eleven cited paths into both halves of the real workflow,
# so the real gap is 0 and the real workflow at ceiling 0 is now GREEN — this
# arm stopped reproducing its own subject. A RED arm that cannot red is a
# vacuous arm, so it moves to a fixture covering NOTHING: gap 15 (every cited
# path) against ceiling 0. The subject is arm E's comparison, which the fixture
# exercises exactly as the real workflow did; the real workflow's new 0 is
# asserted separately and in the other direction by ARM 29 below, so the pair
# still pins both sides.
mk_wf 'no/such/path/at/all' 'no/such/path/at/all' > "$TMP/wf_none.yml"
run_e "$TMP/wf_none.yml" 0
if [ "$rc" -ne 0 ] && grep -q 'cited path(s) cannot DISPATCH this check' <<<"$out"; then
  ok "ARM 22 RED — a gap above the ceiling reds (arm E ratchet)"
else bad "ARM 22 RED — a gap above the ceiling reds (arm E ratchet)" "rc=$rc $out"; fi

# ── ARM 23 (RED, arm E): the gap is named, not just counted ─────────────────
# A count alone gives the .github/ repair no worklist. board.ex is the path
# whose three rots in one day produced this arm; it must appear BY NAME. Reads
# arm 22's $out, so it rides the same fixture.
if [ "$rc" -ne 0 ] && grep -q 'api/lib/barkpark/tasks/board.ex' <<<"$out"; then
  ok "ARM 23 RED — the uncovered paths are named individually (arm E worklist)"
else bad "ARM 23 RED — the uncovered paths are named individually (arm E worklist)" "rc=$rc $out"; fi

# ── ARM 24 (RED, arm E): BOTH halves are required, not either ───────────────
# THE LOAD-BEARING ARM. GitHub needs the workflow-level `paths:` to DISPATCH and
# the roster row to SELECT the job; a path in one and not the other starts a run
# in which the job is skipped. An arm E that checked only the workflow paths
# would pass arms 21-23 unchanged and still be wrong. Here every path is in the
# workflow half (`**`) and only `scripts/pds-*.sh` is in the roster, so the
# uncovered rows must read `in workflow paths: yes` AND `roster: no`.
mk_wf '**' 'scripts/pds-*.sh' > "$TMP/wf_half.yml"
run_e "$TMP/wf_half.yml" 0
if [ "$rc" -ne 0 ] && grep -q 'in workflow paths: yes  in pds-harnesses roster: no' <<<"$out"; then
  ok "ARM 24 RED — a path in the workflow half but NOT the roster still counts as a gap (arm E AND)"
else bad "ARM 24 RED — a path in the workflow half but NOT the roster still counts as a gap (arm E AND)" "rc=$rc $out"; fi

# ── ARM 25 (RED, arm E): an EMPTY roster parse reds as UNCHECKED ────────────
# An absence is never caught by inspection. If the roster pattern stops
# matching, every path scores "uncovered" or the set scores empty — either way
# arm E measured nothing, and it must say so rather than print a number.
printf 'on:\n  pull_request:\n    paths:\n      - "**"\njobs: {}\n' > "$TMP/wf_noroster.yml"
run_e "$TMP/wf_noroster.yml" 11
if [ "$rc" -ne 0 ] && grep -q 'roster rows parsed EMPTY' <<<"$out"; then
  ok "ARM 25 RED — an empty roster parse reds as UNCHECKED, not as coverage (arm E precondition)"
else bad "ARM 25 RED — an empty roster parse reds as UNCHECKED, not as coverage (arm E precondition)" "rc=$rc $out"; fi

# ── ARM 26 (RED, arm E): an EMPTY workflow-paths parse reds as UNCHECKED ────
# The other half of the precondition, asserted separately: a single fixture can
# never break both parses at once, so one passing cannot vouch for the other.
printf 'on:\n  push:\n    branches: [main]\njobs:\n  changes:\n    steps:\n      - run: |\n          roster=\n          pds-harnesses scripts/pds-ledger-census.sh\n' > "$TMP/wf_nopaths.yml"
run_e "$TMP/wf_nopaths.yml" 11
if [ "$rc" -ne 0 ] && grep -q 'pull_request paths list parsed EMPTY' <<<"$out"; then
  ok "ARM 26 RED — an empty workflow-paths parse reds as UNCHECKED (arm E precondition)"
else bad "ARM 26 RED — an empty workflow-paths parse reds as UNCHECKED (arm E precondition)" "rc=$rc $out"; fi

# ── ARM 27 (RED, arm E): a MISSING workflow reds as UNCHECKED ──────────────
# The third way arm E can go blind, and the cheapest to hit: a rename in
# .github/ leaves this script pointed at nothing.
run_e "$REPO_ROOT/.github/workflows/this-workflow-does-not-exist.yml" 11
if [ "$rc" -ne 0 ] && grep -q 'arm E is UNCHECKED — workflow not found' <<<"$out"; then
  ok "ARM 27 RED — a missing workflow reds as UNCHECKED (arm E precondition)"
else bad "ARM 27 RED — a missing workflow reds as UNCHECKED (arm E precondition)" "rc=$rc $out"; fi

# ── ARM 28 (QUIET/CONTROL, arm E): `*` must NOT span a path separator ──────
# Paired with arm 21, and it is why the globs are translated to regexes rather
# than run through a bash `case`: `case` patterns are not pathname expansion, so
# `*` there matches `/` and `scripts/pds-*.sh` would "cover" every .sh under a
# nested directory. Over-matching UNDER-counts the gap, the unsafe direction for
# a ratchet. `scripts/*` in both halves must therefore leave the nested
# api/, internal/ and docs/ citations uncovered rather than absorbing them.
# 10, NOT 11: `scripts/*` legitimately covers all five FLAT scripts/ citations,
# including the .py one that `scripts/pds-*.sh` misses on its extension. The arm
# asserts what the glob COVERS and what it does NOT in one number, so a
# translation that neutered `*` entirely would score 15 here and one that let it
# span `/` would score 5 — both fail this arm, in opposite directions.
mk_wf 'scripts/*' 'scripts/*' > "$TMP/wf_star.yml"
run_e "$TMP/wf_star.yml" 99
if [ "$rc" -eq 0 ] && grep -q 'untriggerable cites . 10 ' <<<"$out"; then
  ok "ARM 28 CONTROL — a single \052 does not span \057, so nested paths stay uncovered (arm E glob)"
else bad "ARM 28 CONTROL — a single \052 does not span \057, so nested paths stay uncovered (arm E glob)" "rc=$rc $out"; fi

# ── ARM 29 (QUIET/CONTROL, arm E): the REAL workflow's gap is 0 and stays 0 ──
# task-ceada0e53f6d2f1d. This is the LOCK on the repair, and the arm that reds
# if anyone deletes a cited path from either half of
# .github/workflows/shell-harnesses.yml. Arm 21 proves a TOTAL-coverage fixture
# scores 0; only this arm proves the SHIPPED workflow does — a fixture can never
# vouch for the file CI actually reads. It is also the other half of arm 22's
# pair: 22 reds on a fixture covering nothing, 29 greens on the real file, so
# neither is satisfiable by an arm E stuck at one verdict.
run_e "$REPO_ROOT/.github/workflows/shell-harnesses.yml" 0
if [ "$rc" -eq 0 ] && grep -q 'untriggerable cites . 0 ' <<<"$out"; then
  ok "ARM 29 CONTROL — the REAL shell-harnesses.yml covers every cited path at ceiling 0 (arm E lock)"
else bad "ARM 29 CONTROL — the REAL shell-harnesses.yml covers every cited path at ceiling 0 (arm E lock)" "rc=$rc $out"; fi

# ── ARMS 30-32 (arm E): the roster is found where the roster LIVES, not in one
# hardcoded filename (task-67a7d8d5b2fd4482).
#
# #19505 moved the `pds-harnesses <path>` rows OUT of the workflow and into
# scripts/shell-harness-dispatch.sh. Arm E read only the workflow, so @roster
# parsed EMPTY, the precondition fired, and 12 of the arms above reddened on
# main for four days with NO coverage verdict at all. Re-pointing the read at
# the new filename would have re-armed the identical trap for the next move.
#
# Arm E now FOLLOWS the sources: every `.sh` the workflow names, then anything
# those scripts `source`. These three arms pin that read in both directions
# through a fixture PAIR — same workflow, same script, the roster rows present
# in one and absent in the other — so neither is satisfiable by an arm E stuck
# at one verdict, and neither can pass by reading the real repo's dispatcher.
#
# mk_wf_dispatch <paths-glob> <script-basename>: a workflow that carries NO
# roster row of its own and names a script in its own directory.
mk_wf_dispatch() {
  printf 'on:\n  pull_request:\n    paths:\n      - "%s"\njobs:\n  changes:\n    steps:\n      - run: bash %s\n' "$1" "$2"
}

# ── ARM 30 (QUIET/CONTROL, arm E): a roster living in a SCRIPT is found ─────
# The repair itself. The workflow half is `**` (covers everything) and the
# roster half is `**` too, but ONLY inside the script — so a gap of 0 here is
# reachable only by an arm E that opened the script. An arm E reading the
# workflow alone scores UNCHECKED and fails this arm.
mk_wf_dispatch '**' 'disp30.sh' > "$TMP/wf_disp.yml"
printf '#!/usr/bin/env bash\nroster=\x27\npds-harnesses **\n\x27\n' > "$TMP/disp30.sh"
run_e "$TMP/wf_disp.yml" 0
if [ "$rc" -eq 0 ] && grep -q 'untriggerable cites . 0 ' <<<"$out"; then
  ok "ARM 30 CONTROL — roster rows carried by a script the workflow names are found (arm E source-following)"
else bad "ARM 30 CONTROL — roster rows carried by a script the workflow names are found (arm E source-following)" "rc=$rc $out"; fi

# ── ARM 31 (RED, arm E): the roster moving AGAIN reds, and NAMES what it read ─
# The regression guard. Same workflow, same script name, rows deleted from the
# script — i.e. the next #19505. The arm asserts more than the red: it asserts
# the message carries the file it looked in, so the next person gets a worklist
# instead of a silent zero. Without this arm, an arm E that resolved the roster
# from a hardcoded path would still pass arm 30.
mk_wf_dispatch '**' 'disp31.sh' > "$TMP/wf_disp_empty.yml"
printf '#!/usr/bin/env bash\necho no roster here\n' > "$TMP/disp31.sh"
run_e "$TMP/wf_disp_empty.yml" 0
if [ "$rc" -ne 0 ] && grep -q 'roster rows parsed EMPTY — read' <<<"$out" && grep -q 'disp31.sh' <<<"$out"; then
  ok "ARM 31 RED — a roster that moved out of every reachable source reds UNCHECKED naming the files read (arm E guard)"
else bad "ARM 31 RED — a roster that moved out of every reachable source reds UNCHECKED naming the files read (arm E guard)" "rc=$rc $out"; fi

# ── ARM 32 (RED, arm E): a script-carried roster can still LOSE ─────────────
# Arm 30 proves the script-carried roster can score 0. On its own that is
# satisfiable by an arm E that treats "found a script" as coverage. Here the
# script's roster covers nothing, so every cited path must come back a gap with
# `in workflow paths: yes  in pds-harnesses roster: no` — the verdict is still
# an AND of the two halves when the halves live in two different files.
mk_wf_dispatch '**' 'disp32.sh' > "$TMP/wf_disp_nocov.yml"
printf '#!/usr/bin/env bash\nroster=\x27\npds-harnesses no/such/path/at/all\n\x27\n' > "$TMP/disp32.sh"
run_e "$TMP/wf_disp_nocov.yml" 0
if [ "$rc" -ne 0 ] && grep -q 'in workflow paths: yes  in pds-harnesses roster: no' <<<"$out"; then
  ok "ARM 32 RED — a script-carried roster that covers nothing still reds as a gap (arm E AND, across files)"
else bad "ARM 32 RED — a script-carried roster that covers nothing still reds as a gap (arm E AND, across files)" "rc=$rc $out"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'RESULT: PASS\n'
