# PDS w22 — collision + housekeeping re-derivation recipes (2026-07-27)

Verifier lane `collision-and-housekeeping-recheck`. Every row is a command that re-derives the
claim from scratch. Run from `/Volumes/SATECHI/github/barkpark`.

| Claim | Rerun |
|---|---|
| Both w21 housekeeping rows read `done` with full criteria | `bp task get pds-w21-diagnose-and-fire -o json \| python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d.get('criteria_progress'))"` (and `pds-w21-crown-collect-and-seal`) |
| Epic task carries wave_paper + verifying wave_status | `bp task get task-2ac1f95237c4a8e5 -o json \| python3 -c "import json,sys;c=json.load(sys.stdin)['doc']['content'];print(c['wave_paper']);print(c['wave_status'][:120])"` |
| Epic has 136 children, 82 open — NOT ~130 open | `bp task get task-2ac1f95237c4a8e5 -o json \| python3 -c "import json,sys;from collections import Counter;ch=json.load(sys.stdin)['children'];print(len(ch),Counter(c['lifecycle_status'] for c in ch))"` |
| No PDS row carries a live unreleased claim | same children dump; filter `claim` without `released_at`/`closed_at`/`expired_at` |
| #6055 is the only open PR on the fenced surfaces | `gh pr list --state open --limit 60 --json number,files --jq '.[] \| select([.files[].path] \| any(test("^api/lib/barkpark/tasks/\|^deploy/\|^scripts/pds-\|^internal/cli/cloud_")))'` |
| #6055 merges clean into current origin/main | `git merge-tree --write-tree --name-only origin/main pr6055-check; echo $?` → exit 0, tree oid only |
| `query.ex` has zero drift on main since #6055's base | `git log --oneline $(git merge-base pr6055-check origin/main)..origin/main -- api/lib/barkpark/tasks/query.ex` → empty |
| #6055's own .ex files ARE formatted | `git show pr6055-check:api/lib/barkpark/tasks/query.ex \| (cd api && mix format --stdin-filename=lib/barkpark/tasks/query.ex -)` diffed against the blob |
| origin/main ITSELF is format-red on the close-gate test file | `git show origin/main:api/test/barkpark_web/controllers/tasks_controller_test.exs > /tmp/a.exs; git show origin/main:api/test/barkpark_web/controllers/tasks_controller_test.exs \| (cd api && mix format --stdin-filename=test/barkpark_web/controllers/tasks_controller_test.exs -) > /tmp/b.exs; diff -q /tmp/a.exs /tmp/b.exs` |
| The format red entered at c79b0ddff (#5826), clean at its parent 19e2fb96b | same recipe with `${c}:api/${P}` — QUOTE the ref, zsh eats `$c:a` as a history modifier |
| main's `elixir` workflow reports run-level SUCCESS with a FAILED Format job | `gh run view 30291553601 --json headSha,jobs --jq '{sha:.headSha,jobs:[.jobs[]\|{n:.name,c:.conclusion}]}'` |
| w21-fire worktree absent from disk and from all registered worktrees | `ls -d /Volumes/SATECHI/github/barkpark-w21-fire; git worktree list \| grep -i w21` (never `git worktree prune`) |
| No recent remote branch carries fenced-surface work | `git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/remotes/origin --count=25` then `git diff --name-only origin/main...<b>` filtered on the four prefixes |
