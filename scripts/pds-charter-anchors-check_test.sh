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

# A fixture with N bare legacy citations padded in, so arm B can be exercised
# independently of arm A.
pad_bare() { # <count>
  local i=0
  while [ "$i" -lt "$1" ]; do printf 'legacy cite pds-pull-proof.sh:%s\n' "$((100 + i))"; i=$((i + 1)); done
}

# ── ARM 1 (QUIET): the real charter on the real tree must pass ───────────────
run "$REPO_ROOT/.claude/workflows/bp-pds-charter.md"
if [ "$rc" -eq 0 ]; then ok "ARM 1 QUIET — the live charter passes"
else bad "ARM 1 QUIET — the live charter passes" "$out"; fi

# ── ARM 2 (RED): an anchor whose literal is no longer in the file ────────────
{ printf 'anchor: `%s`@`this string is not in the harness, 7f3a91`\n' "$HARNESS"; pad_bare 15; } > "$TMP/rotted.md"
run "$TMP/rotted.md"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'ROTTED'; then ok "ARM 2 RED — a rotted anchor reds (ROTTED)"
else bad "ARM 2 RED — a rotted anchor reds (ROTTED)" "rc=$rc $out"; fi

# ── ARM 3 (RED): an anchor matching more than one line is ambiguous ──────────
{ printf 'anchor: `%s`@`  return 1`\n' "$HARNESS"; pad_bare 15; } > "$TMP/ambig.md"
run "$TMP/ambig.md"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'AMBIGUOUS'; then ok "ARM 3 RED — a multi-match anchor reds (AMBIGUOUS)"
else bad "ARM 3 RED — a multi-match anchor reds (AMBIGUOUS)" "rc=$rc $out"; fi

# ── ARM 4 (RED): a line-wrapped anchor must not silently vanish ──────────────
{ printf 'anchor: `%s`@`spent_now=$((spent\n + 1))`\n' "$HARNESS"; pad_bare 15; } > "$TMP/wrapped.md"
run "$TMP/wrapped.md"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'MALFORMED'; then ok "ARM 4 RED — a wrapped anchor reds (MALFORMED)"
else bad "ARM 4 RED — a wrapped anchor reds (MALFORMED)" "rc=$rc $out"; fi

# ── ARM 5 (RED): a NEW bare line citation breaks the ratchet ─────────────────
pad_bare 16 > "$TMP/overceiling.md"
run "$TMP/overceiling.md"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'ceiling'; then ok "ARM 5 RED — a new bare pds-pull-proof.sh:NNN cite reds (arm B)"
else bad "ARM 5 RED — a new bare pds-pull-proof.sh:NNN cite reds (arm B)" "rc=$rc $out"; fi

# ── ARM 6 (QUIET): FEWER bare citations is progress, never a red ─────────────
pad_bare 3 > "$TMP/underceiling.md"
run "$TMP/underceiling.md"
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'PROGRESS'; then ok "ARM 6 QUIET — improvement prints PROGRESS and exits 0"
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
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'anchors checked ..... 0'; then
  ok "ARM 9 REVERT — the pre-fix text carries ZERO checkable anchors (the defect this PR removes)"
else bad "ARM 9 REVERT — the pre-fix text carries ZERO checkable anchors" "rc=$rc $out"; fi

# ── ARM 10 (QUIET/CONTROL): the shipped D92+D93 text carries FOUR ────────────
{ sed -n '/PDS-D92 — The headroom gate/,/aggregate quiet, not BEAM freshness/p' \
    "$REPO_ROOT/.claude/workflows/bp-pds-charter.md"; pad_bare 15; } > "$TMP/shipped.md"
run "$TMP/shipped.md"
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'anchors checked ..... 4'; then
  ok "ARM 10 CONTROL — the shipped D92/D93 text carries exactly 4 resolving anchors"
else bad "ARM 10 CONTROL — the shipped D92/D93 text carries exactly 4 resolving anchors" "rc=$rc $out"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'RESULT: PASS\n'
