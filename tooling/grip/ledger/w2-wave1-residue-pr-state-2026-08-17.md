# Re-derivation recipe — wave-1 residue PR state (api-read-path-security-sweep wave 2)

Verifier lane `wave1-residue-pr-state`, 2026-08-17. Question: do the two wave-1
review follow-ups route to a PR branch or to a main-based micro-slice?

VERDICT: both PRs are MERGED and both files are on `origin/main`, so BOTH
follow-ups are main-based micro-slices. Their branches are deleted. Nothing
routes to `review2-11694` / `review2-11697`. Task `task-d223068f55efbf47`
criterion 5 is lead-owned and **MET** (5/5, closed epoch 8) — the assignment's
"still unmet" premise is refuted.

## Re-derive

```bash
# 1. PR state (both MERGED 2026-08-17)
gh pr view 11694 --json state,mergeStateStatus,mergedAt,headRefName
gh pr view 11697 --json state,mergeStateStatus,mergedAt,headRefName

# 2. both test files are on main
git ls-tree -r origin/main --name-only \
  | grep -E 'graph_draft_leak_test|cycle_fleet_controller_test'

# 3. squash merges present on main
git log origin/main --oneline -40 | grep -E '#11694|#11697'

# 4. PR branches deleted (empty output = deleted)
git ls-remote --heads origin \
  'loop-epic/graph-perspective-existence-gate-close-t-1-r' \
  'loop-epic/seal-the-cycle-fleet-list-equality-publi-4-r'

# 5. no open PR touches either file (empty = no collision)
for p in $(gh pr list --state open --limit 60 --json number -q '.[].number'); do
  gh pr view $p --json files -q '.files[].path' \
    | grep -E 'cycle_fleet_controller_test|graph_draft_leak_test' \
    && echo "collides: #$p"
done

# 6. criteria state of both wave-1 tasks
bp task get task-d223068f55efbf47 -o json \
  | python3 -c 'import json,sys;d=json.load(sys.stdin)["doc"];print(d["criteria_progress"]);[print(i,c["met"],c["criterion"][:120]) for i,c in enumerate(d["content"]["acceptance_criteria"],1)]'
bp task get cycle-fleet-list-equality-seal -o json \
  | python3 -c 'import json,sys;d=json.load(sys.stdin)["doc"];print(d["criteria_progress"])'
```

## Residue targets, pinned to main line numbers

```bash
# A. cycle_fleet comment overstates by one arm ("the two ... 403 assertions")
git show origin/main:api/test/barkpark_web/controllers/cycle_fleet_controller_test.exs | sed -n '588,594p'
# reviewer proof: with the revert-mutation in place, narrowing the loop to
# `for path <- [scoped]` gives 24 tests, 0 failures -> only the FLAT arm reds,
# because :require_token mounts Plugs.PublicRead (router.ex:488) and its
# allowed_route?/1 whitelist already 403'd the scoped path pre-PR.
# NOTE: the same overstatement is copied into the task's criterion-2 evidence
# ("asserts 403 forbidden on BOTH the ...") — fix both or neither.

# B. graph_draft_leak_test has NO assertion pinning the drafts.-prefix
#    normalisation done by Content.published_id/1 (DraftId at
#    api/lib/barkpark/content/draft_id.ex:27, called at
#    tasks_controller.ex:1416 before the published-only match).
grep -rn 'v1/graph' api/test/ | grep -i draft   # only public_read_test.exs:184 (403 tier arm)
git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex | sed -n '1410,1430p'
# Missing arm: plain ["read"] token GET /v1/graph/drafts.<draft-only id> must be
# 404 and must not echo the title. Reviewer measured 404 live but nothing reds
# if the published_id call is ever moved out of resolve_graph_root/2.
```
