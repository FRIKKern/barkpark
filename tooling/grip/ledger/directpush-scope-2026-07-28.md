# Re-derivation recipes — directpush-scope (honest-gates W4 verify, 2026-07-28)

Scope of `hgw3-s7-charter-via-pr`, its collision with PR #6086, the two unread
push-recipe scripts, and the true direct-push rate on `origin/main`.

All commands run from `/Volumes/SATECHI/github/barkpark`. Nothing here mutates
anything: every repo read is `git show origin/main:` (authority L2 — what is
really on main, not this checkout) or a read-only `gh api`.

## R1 — the CLAUDE.md session-ending push mandate (the scope gap)

```bash
git show origin/main:CLAUDE.md | grep -n 'PUSH TO REMOTE\|retry until it succeeds\|pull --rebase'
```
Expect exactly two hits, `92` and `96`. Line 96 is the infinite-loop clause:
`If push fails, resolve and retry until it succeeds.`

Census — the mandate exists at exactly ONE in-repo site:
```bash
git grep -n 'retry until it succeeds' origin/main
git grep -n 'PUSH TO REMOTE' origin/main
git grep -n 'pull --rebase && git push' origin/main
```
All three return only `CLAUDE.md:96` / `CLAUDE.md:92`.

Out-of-repo twin (a LEAD ACTION, not a slice — no builder and no CI guard reaches it):
```bash
grep -n 'pull --rebase\|retry until it succeeds\|git push' /Users/pelle/.claude/CLAUDE.md
grep -rln --include='*.md' -e 'pull --rebase' -e 'retry until it succeeds' -e 'PUSH TO REMOTE' /Users/pelle/.claude
```
Expect `~/.claude/CLAUDE.md:31` only, in the `# Ending a work session` block. It
carries the same push mandate but NOT the retry-forever clause; it does carry
the escape hatch `Ask before pushing if the repo's own conventions require it.`

## R2 — CLAUDE.md is 8 bytes from its CI-enforced budget

```bash
bash scripts/check-doc-budgets.sh | grep -E 'CLAUDE.md|PASS|FAIL'
```
Expect `ok:   CLAUDE.md 9992B <= 10000B`. Any net-additive rewrite of the push
rule reds `doc-gates.yml`. The rewrite must be byte-neutral-or-shrinking.

Section map (proves 87-96 is NOT in the verbatim-exempt Golden Rules / Past
Mistakes sections, so no owner sign-off is required):
```bash
git show origin/main:CLAUDE.md | grep -n '^## \|verbatim-exempt'
```
`## Past Mistakes` at 62, `## Task layer + session completion` at 76,
`## Doc contract` at 98 → lines 87-96 sit inside the Task-layer section.

## R3 — PR #6086 collision with hgw3-s7's two files

```bash
git fetch origin pull/6086/head:pr6086-tmp
git diff origin/main...pr6086-tmp --stat -- \
  .claude/workflows/bp-epic-cycle.workflow.js \
  .claude/workflows/bp-epic-cycle-epic-memory-plan.md
git diff origin/main...pr6086-tmp -U0 -- .claude/workflows/bp-epic-cycle.workflow.js | grep '^@@'
git diff origin/main...pr6086-tmp -U0 -- .claude/workflows/bp-epic-cycle-epic-memory-plan.md | grep '^@@'
git rev-list --count pr6086-tmp..origin/main   # behind
git rev-list --count origin/main..pr6086-tmp   # ahead
gh pr view 6086 --json mergeable,mergeStateStatus,updatedAt
```
Decisive: on `workflow.js` the nearest hunks are `@@ -721,0` and `@@ -733,0` —
s7's target lines 726-727 are pure CONTEXT, no textual overlap. On `plan.md` the
hunk is `@@ -18,7 +18,9 @@`, whose context window CONTAINS s7's target line 20 —
that one DOES collide at merge time.

Locate s7's targets on main:
```bash
git show origin/main:.claude/workflows/bp-epic-cycle.workflow.js | grep -nE 'pull --rebase origin main|Do NOT merge'
git show origin/main:.claude/workflows/bp-epic-cycle-epic-memory-plan.md | sed -n '18,24p'
```

## R4 — hgw3-s7 criterion 5 is a VACUOUS gate; main's documented gate is a FALSE RED

```bash
node --check .claude/workflows/bp-epic-cycle.workflow.js;                    echo "s7 crit5 EXIT=$?"
node --input-type=module --check < .claude/workflows/bp-epic-cycle.workflow.js; echo "plan.md:21 EXIT=$?"
```
`s7 crit5 EXIT=0`, `plan.md:21 EXIT=1` (`SyntaxError: Illegal return statement`
at line 751) — the gate written on main fails on unmodified main.

Mutation proof that criterion 5 cannot fail (this is the finding):
```bash
cp .claude/workflows/bp-epic-cycle.workflow.js /tmp/mut.js
printf '\nconst x = (((;\n' >> /tmp/mut.js
node --check /tmp/mut.js; echo "EXIT=$?"      # => 0
```
Minimal repro of the Node bug — a file with BOTH a top-level `export` and a
top-level `return` makes `node --check` exit 0 on ANY syntax error:
```bash
printf 'export const a = 1;\nreturn 1;\nconst x = (((;\n' > /tmp/m1.js && node --check /tmp/m1.js; echo $?  # 0
printf 'export const a = 1;\nconst x = (((;\n'            > /tmp/m2.js && node --check /tmp/m2.js; echo $?  # 1
printf 'const x = (((;\n'                                  > /tmp/m3.js && node --check /tmp/m3.js; echo $?  # 1
```

The only non-vacuous gate for this file is #6086's module-scope harness:
```bash
node -e 'const fs=require("fs");const s=fs.readFileSync(process.argv[1],"utf8").replace(/^export /m,"");const AF=Object.getPrototypeOf(async function(){}).constructor;new AF("args","budget","agent","parallel","pipeline","phase","log","workflow",s);console.log("CONSTRUCT-OK")' \
  .claude/workflows/bp-epic-cycle.workflow.js; echo "EXIT=$?"   # CONSTRUCT-OK, 0
node -e '<same>' /tmp/mut.js >/dev/null 2>&1; echo "EXIT=$?"    # 1
```

## R5 — the two unread push-recipe scripts do NOT push

```bash
git show origin/main:scripts/local-update.sh        | grep -nE 'push|git (pull|fetch|merge|reset)'
git show origin/main:scripts/pds-window-sentinel.sh | grep -nE 'push|git (pull|fetch|merge|reset)'
```
`local-update.sh` → only `32:  git pull --rebase --autostash`.
`pds-window-sentinel.sh` → `315: git fetch origin --quiet`, `318: git pull --rebase`,
`352: git merge-base --is-ancestor`. Zero `git push` in either file. Neither is
an unattended pusher; both are read-side only and survive protection untouched.

## R6 — the TRUE direct-push rate (the `(#NNNN)` heuristic overcounts)

The subject heuristic is wrong in the safe-looking direction — a squash merged
with a custom `--subject` lands with no `(#N)` suffix and is miscounted as a
direct push. Proof:
```bash
gh api repos/FRIKKern/barkpark/commits/466809dc2/pulls \
  -q '.[] | "PR#\(.number) merged=\(.merged_at) mergeSha=\(.merge_commit_sha[0:9])"'
# PR#6021 merged=2026-07-27T13:02:29Z mergeSha=466809dc2  -> a PR merge, not a direct push
```

Exact method — set-difference of main's commits against every merged PR's
`merge_commit_sha`:
```bash
gh api --paginate 'repos/FRIKKern/barkpark/pulls?state=closed&per_page=100&sort=updated&direction=desc' \
  -q '.[] | select(.merged_at != null) | .merge_commit_sha' | sort -u > /tmp/mergeshas.txt
for W in '7 days ago' '24 hours ago'; do
  git log origin/main --since="$W" --pretty=format:'%H' | grep . > /tmp/win.txt
  tot=$(wc -l < /tmp/win.txt)
  grep -vxF -f /tmp/mergeshas.txt /tmp/win.txt > /tmp/direct.txt
  d=$(wc -l < /tmp/direct.txt)
  awk -v a=$d -v b=$tot -v w="$W" 'BEGIN{printf "%s total=%d direct=%d %.2f%%\n", w, b, a, 100*a/b}'
done
```
Measured 2026-07-28: 7d `453 total / 60 direct / 13.25%`;
24h `101 total / 17 direct / 16.83%`. (Heuristic gave 63 and 18-19.)

Actors and code-touching split:
```bash
while read s; do git log -1 --format='%an' $s; done < /tmp/direct.txt | sort | uniq -c | sort -rn
# 7d: 39 survey, 20 "Frikk Jarl", 1 probe
while read s; do git show --format= --name-only $s | grep . \
  | grep -qvE '\.md$|^tooling/grip/ledger/.*\.json$' && git log -1 --format='%h %s' $s; done < /tmp/direct.txt
# 9 of 60 touch code; the other 51 are charter/plan/ledger docs from epic-cycle Decide
```
