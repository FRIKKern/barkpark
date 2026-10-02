#!/usr/bin/env bash
#
# lane-state.test.sh — lane-state.sh's three outcomes and its worktree split, offline.
#
# MANUAL PROOF — not wired: helpers/*.test.sh sits outside selftest-wiring-census.sh's name-keyed
# corpus (scripts/ only) and lane-state.sh has no --selftest entry point, so the census asks for
# no wiring. Run it by hand after touching lane-state.sh or lane-open-prs.sh:
#     bash .claude/skills/orchestrate-tasks/helpers/lane-state.test.sh
#
# THE HARNESS. `bp` and `gh` are stubs on PATH serving fixture JSON; git is REAL — a scratch bare
# origin, a clone, and five worktrees built with real commits, so the ahead counts, the
# ls-remote read and the ancestry checks are the ones lane-state.sh runs in production.
#
#   lane-open    lane/open    1 ahead, pushed,   GitHub: open PR #11            -> WORK
#   lane-merged  lane/merged  1 ahead, pushed,   GitHub: MERGED PR #12 at head  -> EXCLUDED
#   lane-nopr    lane/nopr    1 ahead, unpushed, GitHub: no PR                  -> WORK
#   lane-level   lane/level   0 ahead, clean                                    -> not listed
#   other-x      other/x      1 ahead, another lane's branch and dir            -> not listed
#
# ARMS
#   1 WORK       exit 0; each section populated; merged excluded, open + nopr included.
#   2 CONTROL    same tree, GitHub answers NO PR for lane/merged: it comes BACK as work — so arm 1's
#                exclusion was GitHub's verdict, not an ancestry accident (the branch is 1 ahead).
#   3 EMPTY      a lane with nothing: exit 0, every section says the read SUCCEEDED with zero.
#   4 LEDGER     bp refuses: exit 2, CANNOT READ ledger, and the LEDGER section prints no zero.
#   5 GITHUB     gh refuses: exit 2, CANNOT READ for the PR list AND for every lane worktree whose
#                merge state it could not ask — none silently excluded, none listed as work.
#
# EXIT: 0 all arms pass · 1 an assertion failed · 2 the harness could not run.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/lane-state.sh"
[ -f "$SUT" ] || { echo "CANNOT RUN: no lane-state.sh beside this harness" >&2; exit 2; }
for t in jq git; do command -v "$t" >/dev/null || { echo "CANNOT RUN: $t missing" >&2; exit 2; }; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
fails=0
chk() { # chk <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$3], wanted [$2]"; fails=$((fails+1)); fi
}
cnt() { printf '%s\n' "$1" | grep -c -- "$2"; }   # count lines of $1 matching $2 (no -q: reads to EOF)

# ── the real git tree ──────────────────────────────────────────────────────────────────────────
G() { git -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null -c init.defaultBranch=main "$@"; }
{
  G init -q --bare "$W/origin.git"
  G clone -q "$W/origin.git" "$W/root"
  echo base > "$W/root/f"; G -C "$W/root" add f; G -C "$W/root" commit -qm base; G -C "$W/root" push -q origin HEAD:main
  G -C "$W/root" fetch -q origin
  mk() { # mk <dir> <branch> <push:0|1> <commit:0|1>
    G -C "$W/root" worktree add -q "$W/wt/$1" -b "$2" origin/main
    if [ "$4" = 1 ]; then echo "$1" > "$W/wt/$1/g"; G -C "$W/wt/$1" add g; G -C "$W/wt/$1" commit -qm "$1"; fi
    if [ "$3" = 1 ]; then G -C "$W/wt/$1" push -q origin "$2"; fi
  }
  mk lane-open lane/open 1 1
  mk lane-merged lane/merged 1 1
  mk lane-nopr lane/nopr 0 1
  mk lane-level lane/level 0 0
  mk other-x other/x 1 1
} > "$W/setup.log" 2>&1 || { echo "CANNOT RUN: git setup failed"; cat "$W/setup.log"; exit 2; }
MERGED_SHA=$(git -C "$W/wt/lane-merged" rev-parse HEAD)
chk "setup: lane-merged is 1 ahead of origin/main (ancestry alone would call it unmerged)" 1 \
    "$(git -C "$W/root" rev-list --count origin/main..lane/merged)"

# ── stubs ──────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$W/bin" "$W/fx"
cat > "$W/bin/bp" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_BP_FAIL:-0}" = 1 ] && { echo "stub bp: dial tcp: connection refused" >&2; exit 1; }
[ "$1 $2" = "task ls" ] || { echo "stub bp: unexpected '$*'" >&2; exit 9; }
cat "$STUB_DIR/fx/ls.json"
STUB
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_GH_FAIL:-0}" = 1 ] && { echo '{"message":"Bad credentials","status":"401"}'; echo "gh: Bad credentials (HTTP 401)" >&2; exit 1; }
[ "$1" = api ] || { echo "stub gh: unexpected '$*'" >&2; exit 9; }
case "$2" in
  *"/pulls?state=open"*) cat "$STUB_DIR/fx/open.json";;
  *"/pulls?state=all&head="*)
    br=${2#*head=*:}; br=${br%%&*}; f="$STUB_DIR/fx/head.$(printf '%s' "$br" | tr '/' '_').json"
    if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi;;
  *) echo "stub gh: unexpected '$*'" >&2; exit 9;;
esac
STUB
chmod +x "$W/bin/bp" "$W/bin/gh"

cat > "$W/fx/ls.json" <<'JSON'
{"ok":true,"page":{"has_more":false,"dataset_ambiguous":[]},"docs":[
 {"doc_id":"task-lane-held","title":"a row this lane holds","lifecycle_status":"in_progress",
  "claim":{"worker":"lead-lane-r3","epoch":4,"lease_expires_at":"2026-09-24T09:00:00Z","lease_extension":{"pr":11}}},
 {"doc_id":"task-other-lane","title":"another lane's row","lifecycle_status":"in_progress",
  "claim":{"worker":"lead-other-r3","epoch":1}}
]}
JSON
cat > "$W/fx/open.json" <<'JSON'
[{"number":11,"draft":false,"created_at":"2026-09-24T08:00:00Z","head":{"ref":"lane/open","sha":"1111111111111111111111111111111111111111"},
  "title":"feat: open work","body":"prose\n\nTask: task-lane-held\n"},
 {"number":13,"draft":true,"created_at":"2026-09-24T08:00:00Z","head":{"ref":"lane/stray","sha":"2222222222222222222222222222222222222222"},
  "title":"feat: stray","body":"Task: task-not-claimed"},
 {"number":14,"draft":false,"created_at":"2026-09-24T08:00:00Z","head":{"ref":"other/x","sha":"3333333333333333333333333333333333333333"},
  "title":"other lane","body":"Task: task-other-lane"}]
JSON
echo '[{"number":11,"state":"open","merged_at":null,"head":{"sha":"x"}}]' > "$W/fx/head.lane_open.json"
printf '[{"number":12,"state":"closed","merged_at":"2026-09-24T07:00:00Z","head":{"sha":"%s"}}]\n' "$MERGED_SHA" > "$W/fx/head.lane_merged.json"

run() { # run <lane> [ENV=VAL…] — sets OUT and RC
  local lane="$1"; shift
  OUT=$(env PATH="$W/bin:$PATH" STUB_DIR="$W" "$@" bash "$SUT" "$lane" o/r --root "$W/root" 2>&1); RC=$?
}
show() { [ "$fails" -gt "$1" ] && printf '%s\n' "$OUT" | sed 's/^/      | /'; return 0; }

echo "== arm 1: WORK — three sections, merged excluded, open and unpushed included"
f0=$fails; run lane
chk "arm1 exit 0" 0 "$RC"
chk "arm1 no CANNOT READ line" 0 "$(cnt "$OUT" '^CANNOT READ')"
chk "arm1 LEDGER lists the lane's row" 1 "$(cnt "$OUT" '^task-lane-held lead-lane-r3 epoch=4 lease-pr=11 ')"
chk "arm1 LEDGER omits another lane's row" 0 "$(cnt "$OUT" '^task-other-lane ')"
chk "arm1 PRS lists #11 and #13, not other/x's #14" "1 1 0" \
    "$(cnt "$OUT" '^#11 ') $(cnt "$OUT" '^#13 ') $(cnt "$OUT" '^#14 ')"
chk "arm1 #11 trailer is claimed here" 1 "$(cnt "$OUT" '#11 task=task-lane-held — claimed by this lane')"
chk "arm1 #13 trailer is NOT claimed here" 1 "$(cnt "$OUT" '#13 task=task-not-claimed — NOT in_progress')"
chk "arm1 lane-open is WORK with its open PR" 1 "$(cnt "$OUT" '^lane-open branch=lane/open .* pushed — open PR #11$')"
chk "arm1 lane-nopr is WORK, unpushed, no PR" 1 "$(cnt "$OUT" '^lane-nopr branch=lane/nopr .* no-remote-branch — no PR$')"
chk "arm1 lane-merged is NOT a work line" 0 "$(cnt "$OUT" '^lane-merged ')"
chk "arm1 lane-merged is named as excluded" 1 "$(cnt "$OUT" '^excluded (PR merged): lane-merged(#12)$')"
chk "arm1 level and other-lane worktrees absent" "0 0" "$(cnt "$OUT" '^lane-level ') $(cnt "$OUT" '^other-x ')"
chk "arm1 tally" 1 "$(cnt "$OUT" '^worktrees with work: 2 · level with origin/main and clean: 1 · excluded, PR merged: 1$')"
show "$f0"

echo "== arm 2: CONTROL — GitHub says lane/merged has no PR, so it returns as work"
f0=$fails; mv "$W/fx/head.lane_merged.json" "$W/fx/held-aside.json"; run lane
chk "arm2 exit 0" 0 "$RC"
chk "arm2 lane-merged is now WORK" 1 "$(cnt "$OUT" '^lane-merged branch=lane/merged .* pushed — no PR$')"
chk "arm2 nothing excluded" 0 "$(cnt "$OUT" '^excluded')"
mv "$W/fx/held-aside.json" "$W/fx/head.lane_merged.json"; show "$f0"

echo "== arm 3: EMPTY — a lane with nothing anywhere says so, per read"
f0=$fails; run ghost
chk "arm3 exit 0" 0 "$RC"
chk "arm3 no CANNOT READ line" 0 "$(cnt "$OUT" '^CANNOT READ')"
chk "arm3 LEDGER zero is labelled a successful read" 1 "$(cnt "$OUT" '^NO in_progress rows claimed by lead-ghost\* — the read SUCCEEDED over 2 ')"
chk "arm3 PRS zero is labelled" 1 "$(cnt "$OUT" '^NO OPEN PRS matched')"
chk "arm3 WORKTREES zero" 1 "$(cnt "$OUT" '^worktrees with work: 0 · level with origin/main and clean: 0 · excluded, PR merged: 0$')"
show "$f0"

echo "== arm 4: LEDGER unreadable — exit 2, CANNOT READ, and no zero where the rows would be"
f0=$fails; run lane STUB_BP_FAIL=1
chk "arm4 exit 2" 2 "$RC"
chk "arm4 CANNOT READ ledger" 1 "$(cnt "$OUT" '^CANNOT READ ledger: bp task ls --status in_progress failed: stub bp: dial tcp')"
chk "arm4 no ledger zero printed" 0 "$(cnt "$OUT" '^NO in_progress rows')"
chk "arm4 cross-check says it was skipped" 1 "$(cnt "$OUT" 'trailer cross-check skipped')"
chk "arm4 final line refuses" 1 "$(cnt "$OUT" '^lane-state: CANNOT READ — 1 read(s) failed')"
show "$f0"

echo "== arm 5: GITHUB unreadable — exit 2; no worktree silently excluded, none called work"
f0=$fails; run lane STUB_GH_FAIL=1
chk "arm5 exit 2" 2 "$RC"
chk "arm5 PR list CANNOT READ" 1 "$(cnt "$OUT" '^CANNOT READ PRs: lane-open-prs.sh exited 3')"
chk "arm5 no PR zero printed" 0 "$(cnt "$OUT" '^NO OPEN PRS')"
chk "arm5 every branch worktree unreadable, named" 3 "$(cnt "$OUT" '^CANNOT READ worktree lane-.* merge state UNKNOWN, not excluded')"
chk "arm5 lane-merged not excluded on a failed read" 0 "$(cnt "$OUT" '^excluded')"
chk "arm5 final line counts 4 failed reads" 1 "$(cnt "$OUT" '^lane-state: CANNOT READ — 4 read(s) failed')"
show "$f0"

if [ "$fails" -gt 0 ]; then echo "lane-state.test.sh: $fails FAILED"; exit 1; fi
echo "lane-state.test.sh: all arms passed"
exit 0
