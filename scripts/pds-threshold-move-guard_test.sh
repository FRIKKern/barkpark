#!/usr/bin/env bash
# Offline harness for scripts/pds-threshold-move-guard.sh.
#
# WHAT IT PROVES, BY MUTATION RATHER THAN BY ASSERTION:
#   THE REFUSAL IS REAL — a watched cap moved with no statement in the PR body
#     reds (exit 1) and the verdict NAMES the literal, the old value and the new.
#   THE GUARD IS NOT A FREEZE — and this is the arm the task exists for. Arms 2
#     and 3 run against the SAME head tree, the same moved cap, the same base.
#     The ONLY difference is a line in the PR body, and the verdict flips from
#     REFUSED to PASS. A guard that could not show that pair would be a freeze
#     wearing a guard's name, and a freeze on a cap that legitimately moves gets
#     deleted the first week it costs someone a merge.
#   THE STATEMENT CANNOT BE FAKED CHEAPLY — a statement carrying both numbers and
#     no reason (arm 4) still reds, and one naming the WRONG old value (arm 5)
#     still reds. Otherwise `Threshold-move: x 1 -> 2` would be a rubber stamp
#     restating a diff the reader can already see.
#   IT CANNOT GO SILENTLY GREEN — three separate unreadable-input shapes (no body
#     at all, an unresolvable base ref, a body file that is not there) each exit 2
#     UNCHECKED with a message naming which input was missing. Arm 6.
#   IT READS MORE THAN ONE SHAPE — a `counts` roster bump (arm 7) and a `roster`
#     set that gains a member (arm 8) red on their own, so the coverage is not
#     one JSON extractor with seventeen decorative rows behind it.
#   IT DOES NOT FIRE ON PROSE — editing only the COMMENT header of a watched
#     baseline is NOT a threshold move (arm 9). A guard that reds on a re-worded
#     comment teaches authors to route around it.
#   THE GUARD'S OWN ROSTER IS GUARDED — dropping a watched path from the guard
#     silences the guard for that path in the same PR that drops it; that is the
#     row-9 hole of the c0 population ledger (`scripts/.silencer-counts` is the
#     ratchet's own roster and nothing ratchets it). Arm 10 reds on the drop and
#     arm 11 passes it once the body says why.
#   AND IT CATCHES THE ACTUAL INCIDENT — arm 12 runs the guard over the REAL
#     commit c3b0421cb (PR #9601), the one that raised
#     js/packages/react/.size-limit.json from 22.5 KB to 22.75 KB in the same
#     commit a criterion cited the 22.5 KB cap against. Not a case invented to
#     pass: the case that produced the task. It STANDS DOWN LOUDLY (naming why,
#     never silently) when the checkout is too shallow to hold that commit.
#
# HERMETIC: arms 1-11 build a throwaway git repo in $TMPDIR. No network, no
# ledger, no credential. Arm 12 is the only one that reads this repository, and
# it reads history only.
#
# Exit 0 = every arm passed. Any failure exits 1 and names the arm.
set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/scripts/pds-threshold-move-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails + 1)); }

[ -r "$GUARD" ] || { printf 'TEST HARNESS FAIL: %s is not readable\n' "$GUARD" >&2; exit 99; }

echo "pds-threshold-move-guard_test — the move is allowed; the SILENT move is not"

# ── the fixture repo ────────────────────────────────────────────────────────
FX="$TMP/fx"
mkdir -p "$FX/js/packages/react" "$FX/scripts" "$FX/cloud/priv/static/__preview__"
cd "$FX" || exit 99
git init -q .
git config user.email t@example.invalid
git config user.name  t
git config commit.gpgsign false

cap_json() { # $1 = the dist/index.mjs cap
  cat <<JSON
[
 {
  "name": "PortableText root import",
  "path": "dist/index.mjs",
  "import": "{ PortableText }",
  "limit": "1.3 KB",
  "gzip": true
 },
 {
  "name": "PortableDoc renderer — client entry (dist/index.mjs)",
  "path": "dist/index.mjs",
  "limit": "$1",
  "gzip": true
 }
]
JSON
}

silencer_counts() { # $1 = the tenant-scope-baseline count
  cat <<CNT
# .silencer-counts — the committed count roster.
tenant-scope-baseline $1
sobelow-skips 36
CNT
}

ceiling_file() { # remaining args = rostered paths
  printf '# go-format drift ceiling roster — the grandfathered gofmt-dirty Go files.\n'
  for p in "$@"; do printf '%s\n' "$p"; done
}

cap_json "22.5 KB"        > js/packages/react/.size-limit.json
silencer_counts 44        > scripts/.silencer-counts
ceiling_file              > .go-format-drift-ceiling
printf '# the authored-head floor.\n1345\n' > cloud/priv/static/__preview__/cssom-heads.baseline
git add -A && git commit -qm base
BASE="$(git rev-parse HEAD)"

run() { # run <PR_BODY> [extra args...]; prints output, sets RC
  local body="$1"; shift
  OUT="$(PR_BODY="$body" bash "$GUARD" --base "$BASE" --head HEAD "$@" 2>&1)"
  RC=$?
}

# ── 1. no move ──────────────────────────────────────────────────────────────
printf 'unrelated\n' > README.md
git add -A && git commit -qm "no threshold touched"
run "a PR that moves nothing"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'PASS: nothing watched moved'; then
  ok "no move -> exit 0, 'nothing watched moved'"
else
  bad "1 no-move" "rc=$RC, want 0 with 'nothing watched moved'. Output:
$OUT"
fi

# ── 2. a cap moves, the body says nothing ───────────────────────────────────
cap_json "22.75 KB" > js/packages/react/.size-limit.json
git add -A && git commit -qm "fix(react): a failed reference fetch is no longer a missing document"
HEAD_MOVED="$(git rev-parse HEAD)"
run "fix(react): a failed reference fetch is no longer a missing document"
RC_SILENT="$RC"; OUT_SILENT="$OUT"
if [ "$RC" = 1 ] \
   && printf '%s' "$OUT" | grep -q 'REFUSED  js/packages/react/.size-limit.json#limit#2 moved 22.5 KB -> 22.75 KB' ; then
  ok "a silent cap move -> exit 1, naming the literal and BOTH values"
else
  bad "2 silent-move" "rc=$RC, want 1 with a REFUSED line naming 22.5 KB -> 22.75 KB. Output:
$OUT"
fi

# ── 3. THE NOT-A-FREEZE ARM: same tree, same move, body states it ───────────
run 'fix(react): a failed reference fetch is no longer a missing document

Threshold-move: js/packages/react/.size-limit.json#limit#2 22.5 KB -> 22.75 KB — the error boundary adds 250 B; measured 22.7 KB, +0.98%, under the 2% regression bar.'
if [ "$RC" = 0 ] \
   && printf '%s' "$OUT" | grep -q 'STATED   js/packages/react/.size-limit.json#limit#2' \
   && printf '%s' "$OUT" | grep -q 'PASS: every watched literal that moved is stated'; then
  ok "THE SAME MOVE, STATED -> exit 0. The guard is not a freeze."
else
  bad "3 not-a-freeze" "rc=$RC, want 0 with STATED + PASS. THIS IS THE ARM THAT MATTERS: if a
     legitimate cap move cannot pass, the guard is a freeze and gets deleted. Output:
$OUT"
fi
# and the pair is only a proof if the two runs differed ONLY in the body
if [ "$RC_SILENT" = 1 ] && [ "$RC" = 0 ] && [ "$(git rev-parse HEAD)" = "$HEAD_MOVED" ]; then
  ok "arms 2 and 3 ran against the SAME head tree ($(git rev-parse --short HEAD)) — the body alone flipped the verdict"
else
  bad "3b pair-integrity" "arms 2 and 3 did not run against the same head tree, so the pair proves nothing
     (rc_silent=$RC_SILENT rc_stated=$RC head=$(git rev-parse HEAD) want=$HEAD_MOVED)"
fi

# ── 4. both numbers, no reason ──────────────────────────────────────────────
run 'Threshold-move: js/packages/react/.size-limit.json#limit#2 22.5 KB -> 22.75 KB'
if [ "$RC" = 1 ]; then
  ok "a statement with both numbers and NO reason still reds"
else
  bad "4 no-justification" "rc=$RC, want 1 — a bare restatement of the diff passed as a justification. Output:
$OUT"
fi

# ── 5. the wrong old value ──────────────────────────────────────────────────
run 'Threshold-move: js/packages/react/.size-limit.json#limit#2 21 KB -> 22.75 KB — a reason long enough to count as one.'
if [ "$RC" = 1 ]; then
  ok "a statement naming the WRONG old value still reds"
else
  bad "5 wrong-old" "rc=$RC, want 1 — the guard accepted a statement that misquotes the value it replaces. Output:
$OUT"
fi

# ── 6. unreadable inputs are UNCHECKED, never a green ───────────────────────
OUT="$(env -u PR_BODY -u PR_BODY_FILE bash "$GUARD" --base "$BASE" --head HEAD 2>&1)"; RC=$?
if [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'UNCHECKED: no PR body was supplied'; then
  ok "no PR body at all -> exit 2 UNCHECKED, naming the missing input"
else
  bad "6a no-body" "rc=$RC, want 2. Output:
$OUT"
fi
OUT="$(PR_BODY=x bash "$GUARD" --base definitely-not-a-ref-9f3a --head HEAD 2>&1)"; RC=$?
if [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'does not resolve to a commit'; then
  ok "an unresolvable base ref -> exit 2 UNCHECKED"
else
  bad "6b bad-ref" "rc=$RC, want 2. Output:
$OUT"
fi
OUT="$(bash "$GUARD" --base "$BASE" --head HEAD --pr-body "$TMP/absent-body.md" 2>&1)"; RC=$?
if [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'cannot be read'; then
  ok "a PR body file that is not there -> exit 2 UNCHECKED"
else
  bad "6c bad-body-file" "rc=$RC, want 2. Output:
$OUT"
fi

# ── 7. a second KIND: the counts roster ─────────────────────────────────────
git checkout -q -- . && git clean -qfd
cap_json "22.5 KB" > js/packages/react/.size-limit.json
silencer_counts 45 > scripts/.silencer-counts
git add -A && git commit -qm "raise the tenant-scope silencer count"
run "raise the tenant-scope silencer count"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'scripts/.silencer-counts#tenant-scope-baseline moved 44 -> 45'; then
  ok "a counts-roster bump (44 -> 45) reds on its own, keyed by NAME"
else
  bad "7 counts-kind" "rc=$RC, want 1 naming tenant-scope-baseline 44 -> 45. Output:
$OUT"
fi

# ── 8. a third KIND: a grandfather SET that gains a member ──────────────────
ceiling_file "internal/cli/dirty.go" > .go-format-drift-ceiling
git add -A && git commit -qm "grandfather one more gofmt-dirty file"
run "grandfather one more gofmt-dirty file"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q '\.go-format-drift-ceiling#entries moved 0 lines'; then
  ok "a waiver SET gaining a member reds (entries 0 -> 1, digest-keyed)"
else
  bad "8 roster-kind" "rc=$RC, want 1 naming .go-format-drift-ceiling#entries. Output:
$OUT"
fi

# ── 9. FALSE-POSITIVE CONTROL: prose is not a threshold ─────────────────────
BASE9="$(git rev-parse HEAD)"
printf '# the authored-head floor. Re-worded header, same number.\n# A second comment line.\n1345\n' \
  > cloud/priv/static/__preview__/cssom-heads.baseline
git add -A && git commit -qm "re-word a baseline's comment header"
OUT="$(PR_BODY="re-word a baseline's comment header" bash "$GUARD" --base "$BASE9" --head HEAD 2>&1)"; RC=$?
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'PASS: nothing watched moved'; then
  ok "editing ONLY a watched baseline's comment header is not a move"
else
  bad "9 prose-control" "rc=$RC, want 0 — the guard reds on re-worded prose, which teaches authors to route around it. Output:
$OUT"
fi

# ── 10/11. the guard's own roster is guarded ────────────────────────────────
mkdir -p scripts
# base: a copy of the guard carrying ONE extra watched path
# NOT sed: a literal \t in a BSD sed pattern is the letter t, and the roster is
# TAB-separated. The row is inserted AFTER the `WATCHED='"'"'...` opening line — that
# line'"'"'s $1 carries the assignment prefix, not the bare path, so matching the path
# on the first row silently matches nothing. The control below caught both bugs.
awk -F'\t' '
  { print }
  !ins && $1 ~ /^WATCHED=/ {
    printf "fixture/extra.baseline\tnumber\n"; ins = 1
  }
' "$GUARD" > scripts/pds-threshold-move-guard.sh
if ! grep -q '^fixture/extra.baseline	number$' scripts/pds-threshold-move-guard.sh; then
  bad "10-setup" "the fixture guard copy does not carry the extra roster path — arms 10/11 would measure nothing"
fi
chmod +x scripts/pds-threshold-move-guard.sh
git add -A && git commit -qm "land the guard with an extra watched path"
BASE10="$(git rev-parse HEAD)"
# head: the pristine guard — the extra path is DROPPED
cp "$GUARD" scripts/pds-threshold-move-guard.sh
chmod +x scripts/pds-threshold-move-guard.sh
git add -A && git commit -qm "drop a watched path"
OUT="$(PR_BODY="drop a watched path" bash ./scripts/pds-threshold-move-guard.sh --base "$BASE10" --head HEAD 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'REFUSED-DROP fixture/extra.baseline'; then
  ok "dropping a path from the guard's OWN roster reds (the row-9 hole)"
else
  bad "10 roster-drop" "rc=$RC, want 1 with REFUSED-DROP fixture/extra.baseline. Output:
$OUT"
fi
OUT="$(PR_BODY='drop a watched path

Threshold-watch-drop: fixture/extra.baseline — the file was deleted from the tree and no check reads it as a reference value any more.' \
  bash ./scripts/pds-threshold-move-guard.sh --base "$BASE10" --head HEAD 2>&1)"; RC=$?
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'STATED-DROP  fixture/extra.baseline'; then
  ok "the same drop, stated with a reason -> exit 0 (the drop arm is not a freeze either)"
else
  bad "11 stated-drop" "rc=$RC, want 0 with STATED-DROP. Output:
$OUT"
fi

# ── 12. THE ACTUAL INCIDENT, on real history ────────────────────────────────
cd "$REPO_ROOT" || exit 99
INCIDENT=c3b0421cb
if git rev-parse --verify --quiet "$INCIDENT^{commit}" >/dev/null 2>&1 \
   && git rev-parse --verify --quiet "$INCIDENT^^{commit}" >/dev/null 2>&1; then
  OUT="$(PR_BODY='fix(react): a failed reference fetch is no longer a missing document' \
    bash "$GUARD" --base "$INCIDENT^" --head "$INCIDENT" 2>&1)"; RC=$?
  if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'moved 22.5 KB -> 22.75 KB'; then
    ok "PR #9601 ($INCIDENT), the commit that produced this task, is REFUSED on real history"
  else
    bad "12 incident-replay" "rc=$RC, want 1 naming 22.5 KB -> 22.75 KB on the real commit. Output:
$OUT"
  fi
else
  printf '  STOOD DOWN  arm 12: %s or its parent is not in this checkout (a shallow clone).\n' "$INCIDENT"
  printf '              The incident replay did NOT run. It is not counted as a pass.\n'
fi

# ── 13-17. THE TWO fd-0 COUNT IDENTITIES (task-fb55d468c7dea75b) ────────────
# The literal sweep reads $WATCHED on fd 0 (`done <<< "$WATCHED"`), and inside
# it the key loop reads the before/after union the same way. $moved and
# $unstated are BOTH read off those loops, so a body child that steals stdin
# truncates one and the guard prints
#     PASS: nothing watched moved.
# in the same words a complete sweep uses. A path never reached is a threshold
# move never REFUSED, and this guard's whole job is to make that move visible.
#
# The roster count (18 rows) and the union count are read BEFORE the loops;
# they are the only quantities a short read cannot move.
#
#   13  CONTROL   a silent move of a LATER watched row is REFUSED, identities silent
#   14  OUTER SHORT  a drained fd 0 in the sweep body refuses "examined 1 of 18"
#   15  OUTER CUT    the same short read then prints PASS over a real move (defect)
#   16  INNER SHORT  a drained fd 0 in the KEY loop refuses "examined 1 of 2"
#   17  INNER CUT    the same short read then misses the second moved key (defect)
# ── THE MUTATION HELPERS (task-fb55d468c7dea75b) ─────────────────────────────
# A count identity is a guard over a defect nobody can trigger by hand, so the
# only way to show it MEANS anything is to build the defect: splice a
# stdin-draining child into the loop body and watch the guard refuse, then CUT
# the guard out of the same mutated copy and watch the old verdict come back.
# Both operate on a COPY; the live script is never touched.
#
# `cat >/dev/null` is the minimal honest specimen of the hazard: it is what a
# `gh` without `</dev/null`, an `ssh`, a `psql` or a `read` does to fd 0 — it
# consumes the remainder, so the loop ends after ONE iteration with exit 0 and
# nothing printed.
mut_splice() { # <src> <dst> <marker-name>
  awk -v m="# MUT-SPLICE: $3" '{ print } index($0, m) { print "cat >/dev/null" }' "$1" > "$2"
  grep -q '^cat >/dev/null$' "$2" || { printf 'mut_splice: marker %s not found in %s\n' "$3" "$1" >&2; return 2; }
}
mut_cut() { # <src> <dst> <block-name>
  awk -v a="# MUT-ANCHOR: $3" -v b="# MUT-END: $3" '
    index($0, a) { skip = 1; cut = 1 }
    !skip { print }
    index($0, b) { skip = 0 }
    END { if (!cut) exit 3 }' "$1" > "$2"
}
# Arm 12 left the shell in $REPO_ROOT to read real history. Everything below is
# hermetic again, so go back to the fixture repo FIRST — the first draft of
# these arms ran the guard against the real repo with the fixture's BASE sha and
# got six identical UNCHECKED verdicts, which is a uniform result and therefore
# a broken instrument, not six findings.
# EVERY git WRITE BELOW TAKES `git -C "$FX"`, and that is not style. The first
# draft of these arms wrote `git add -A && git commit` the way the arms above
# do, relying on the shell's cwd — and arm 12 had left it in $REPO_ROOT, so the
# fixture's cap files were written over the REAL ones and committed to the real
# repository. A harness that can commit to the tree it is testing is a hazard
# whatever its assertions say. `cd` too, so the guard resolves --base/--head in
# the fixture, but nothing here depends on it having worked.
cd "$FX" || exit 99
MUT="$TMP/mut"; mkdir -p "$MUT"
run_g() { # run_g <script> <PR_BODY>
  OUT="$(PR_BODY="$2" bash "$1" --base "$BASE" --head HEAD 2>&1)"; RC=$?
}

# Back to the base tree, then move a LATER watched row only: .silencer-counts is
# row 12 of 18, so a sweep that stops at row 1 cannot see it.
cap_json "22.5 KB"  > "$FX/js/packages/react/.size-limit.json"
silencer_counts 45  > "$FX/scripts/.silencer-counts"
# `|| true` and quiet: an earlier arm may already have left the tree at 45, and
# "nothing to commit" is not a failure — only the resulting sha matters here.
git -C "$FX" add -A && git -C "$FX" commit -qm "chore: bump the tenant-scope baseline" >/dev/null 2>&1 || true

run_g "$GUARD" "chore: bump the tenant-scope baseline"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'REFUSED  scripts/.silencer-counts#tenant-scope-baseline moved 44 -> 45' \
   && ! printf '%s' "$OUT" | grep -q 'SHORT SWEEP'; then
  ok "13 CONTROL — a silent move of a LATER watched row is REFUSED, both identities silent"
else
  bad "13 control-later-row" "rc=$RC, want 1 naming .silencer-counts 44 -> 45 with no SHORT SWEEP. Output:
$OUT"
fi

if mut_splice "$GUARD" "$MUT/outer-short.sh" watched-count-identity; then
  run_g "$MUT/outer-short.sh" "chore: bump the tenant-scope baseline"
  if [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'SHORT SWEEP — examined 1 of 18 watched path(s)' \
     && ! printf '%s' "$OUT" | grep -q '^PASS:'; then
    ok "14 OUTER SHORT — a drained fd 0 refuses naming both numbers (1 of 18), exit 2, no PASS"
  else
    bad "14 outer-short" "rc=$RC, want 2 naming 'examined 1 of 18'. Output:
$OUT"
  fi
else bad "14 outer-short" "no MUT-SPLICE marker for the watched sweep in $GUARD"; fi

if mut_cut "$MUT/outer-short.sh" "$MUT/outer-short-nocount.sh" watched-count-identity; then
  run_g "$MUT/outer-short-nocount.sh" "chore: bump the tenant-scope baseline"
  if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'PASS: nothing watched moved' \
     && ! printf '%s' "$OUT" | grep -q 'SHORT SWEEP'; then
    ok "15 OUTER CUT — without the identity the same short read prints PASS over a real move (the defect, reproduced)"
  else
    bad "15 outer-cut" "rc=$RC, want 0 with 'PASS: nothing watched moved'. Output:
$OUT"
  fi
else bad "15 outer-cut" "no MUT-ANCHOR block for the watched sweep in $GUARD"; fi

# ── the inner loop: TWO keys move in ONE watched file, the body states ONE ──
# A FRESH BASE. Earlier arms left several watched files changed relative to
# $BASE, and the first draft of these arms measured a 3-key union across two
# paths while asserting 2 across one — the assertion was about a population the
# fixture no longer had. Pin the base to HEAD here so the ONLY diff below is the
# react cap file, and the union is exactly its two keys.
silencer_counts 44 > "$FX/scripts/.silencer-counts"
cap_json "22.5 KB" > "$FX/js/packages/react/.size-limit.json"
# `|| true`: an earlier arm may already have left the tree in this exact state,
# and "nothing to commit" is not a failure here — only the resulting sha matters.
git -C "$FX" add -A && git -C "$FX" commit -qm "chore: restore the fixture to a single-file baseline" >/dev/null 2>&1 || true
BASE_TWO="$(git -C "$FX" rev-parse HEAD)"
run_g2() { OUT="$(PR_BODY="$2" bash "$1" --base "$BASE_TWO" --head HEAD 2>&1)"; RC=$?; }

cat <<'JSON' > "$FX/js/packages/react/.size-limit.json"
[
 {
  "name": "PortableText root import",
  "path": "dist/index.mjs",
  "import": "{ PortableText }",
  "limit": "1.4 KB",
  "gzip": true
 },
 {
  "name": "PortableDoc renderer — client entry (dist/index.mjs)",
  "path": "dist/index.mjs",
  "limit": "22.75 KB",
  "gzip": true
 }
]
JSON
git -C "$FX" add -A && git -C "$FX" commit -qm "perf(react): two caps move at once"
TWO_BODY='perf(react): two caps move at once

Threshold-move: js/packages/react/.size-limit.json#limit#1 1.3 KB -> 1.4 KB — the root import gained a guard clause.'

run_g2 "$GUARD" "$TWO_BODY"
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'REFUSED  js/packages/react/.size-limit.json#limit#2 moved 22.5 KB -> 22.75 KB' \
   && printf '%s' "$OUT" | grep -q 'STATED   js/packages/react/.size-limit.json#limit#1'; then
  ok "16a CONTROL — with two keys moved and one stated, the intact key loop STATES one and REFUSES the other"
else
  bad "16a control-two-keys" "rc=$RC, want 1 with limit#1 STATED and limit#2 REFUSED. Output:
$OUT"
fi

if mut_splice "$GUARD" "$MUT/inner-short.sh" key-count-identity; then
  run_g2 "$MUT/inner-short.sh" "$TWO_BODY"
  if [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'SHORT KEY SWEEP — examined 1 of 2 union key(s)' \
     && ! printf '%s' "$OUT" | grep -q '^PASS:'; then
    ok "16 INNER SHORT — a drained fd 0 in the KEY loop refuses naming both numbers (1 of 2), exit 2"
  else
    bad "16 inner-short" "rc=$RC, want 2 naming 'examined 1 of 2 union key(s)'. Output:
$OUT"
  fi
else bad "16 inner-short" "no MUT-SPLICE marker for the key loop in $GUARD"; fi

if mut_cut "$MUT/inner-short.sh" "$MUT/inner-short-nocount.sh" watched-count-identity; then
  run_g2 "$MUT/inner-short-nocount.sh" "$TWO_BODY"
  if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'STATED   js/packages/react/.size-limit.json#limit#1' \
     && ! printf '%s' "$OUT" | grep -q 'limit#2' \
     && ! printf '%s' "$OUT" | grep -q 'SHORT KEY SWEEP'; then
    ok "17 INNER CUT — without the identities the same short key read never sees limit#2 and the guard passes (the defect, reproduced)"
  else
    bad "17 inner-cut" "rc=$RC, want 0 with limit#1 STATED, limit#2 never mentioned. Output:
$OUT"
  fi
else bad "17 inner-cut" "no MUT-ANCHOR block covering the key identity in $GUARD"; fi

echo
if [ "$fails" -eq 0 ]; then
  echo "pds-threshold-move-guard_test: PASS"
  exit 0
fi
echo "pds-threshold-move-guard_test: FAIL ($fails arm(s))"
exit 1
