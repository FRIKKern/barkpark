<!-- doc-tier: cold | canonical-for: cch-w66-concurrency-recheck-recipe | budget: 1200tok -->

# CCH wave 66 — concurrency re-check at dispatch (2026-08-10 ~00:52 local / 22:52Z)

> HISTORICAL RECORD (2026-08-10) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Re-derivation recipes for the collision-surface measurement. Run from the repo root.

## 1. Which worktrees hold the contested files DIRTY

```
for d in .claude/worktrees/*/; do s=$(git -C "$d" status --porcelain 2>/dev/null | grep -E 'app\.js|web/router\.ex|sites/deploy\.ex|deploy_ledger\.ex|tasks/(close|stamp)\.ex'); [ -n "$s" ] && echo "== $d" && echo "$s"; done
```

## 2. Modified-in-last-hour is a TRAP — fresh worktree checkout stamps every file

```
for d in .claude/worktrees/wf_ff5561ef-0c7-19; do stat -f '%Sm %N' -t '%H:%M:%S' $d/cloud/priv/static/app.js $d/api/lib/barkpark/tasks/close.ex $d/README.md; done
```

Uniform mtimes across unrelated files (incl. README.md) = checkout, not edit. Only trust an
mtime that is LATER than the worktree's README.md and paired with a dirty status entry.

## 3. Identify a worktree family's epic (gh cannot see unpushed runs)

```
for p in .claude/worktrees/<prefix>-*/; do echo "-- $p $(git -C $p rev-parse --abbrev-ref HEAD)"; git -C $p status --porcelain | head -6; done
```

Untracked scratch dirs (`.w34/`, `.probe_tags.txt`, `scripts/deploy-reliability-exit-*.md`)
identify the run faster than the branch name, which is often `worktree-<id>`.

## 4. Open PRs touching the contested files

```
gh pr list --state open --limit 100 --json number,updatedAt,headRefName,files --jq '.[]|. as $p|$p.files[]|select(.path|test("app\\.js|web/router\\.ex|sites/deploy\\.ex|deploy_ledger\\.ex|tasks/(close|stamp)\\.ex"))|"\($p.number) \($p.updatedAt) \($p.headRefName) \(.path)"' | sort -u
```

## 5. Does a claimed fence actually exist in the other epic's charter?

```
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -oE 'dr-w[0-9]+' | sort -t w -k2 -n -u | tail -4
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -n 'no_previous' | tail
```

The LOCAL charter copy is L3 and stale; always `git show origin/main:`.

## 6. Who owns api/lib/barkpark/tasks/close.ex

```
grep -n 'tasks/close\.ex\|tasks/stamp\.ex' .claude/workflows/bp-felix-pristine-charter.md
bp task get task-felix-close-merge-gate-autostamp -o json
```
