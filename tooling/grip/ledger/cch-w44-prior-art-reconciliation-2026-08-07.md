# cch-w44 — prior-art reconciliation re-derivation recipes (2026-08-07)

Tree: `origin/main` = `ba712a4b29ce5e6721b81a93343182654e47918f`.
Every row below is a command, not a claim. Run from the repo root.

## Rows

| # | What it settles | Command |
|---|---|---|
| 1 | `cch-w43-s3` lifecycle + its own words that the arity arm is filed separately | `bp task get cch-w43-s3-binding-census-names-the-authority-below-the-router -o json \| python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status']);[print(i,c['criterion'][:200]) for i,c in enumerate(d['content']['acceptance_criteria'])]"` |
| 2 | `task-7c86463e27ac80f3` is a cancelled throwaway probe, not a competing draft | `bp task get task-7c86463e27ac80f3 -o json \| python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'], d['content']['close_reason'])"` |
| 3 | S2's true filed parent exists and is OPEN | `bp task get cch-w43-bl-binding-census-arity-arm -o json \| python3 -c "import sys,json;print(json.load(sys.stdin)['doc']['lifecycle_status'])"` |
| 4 | S3's filed parent exists | `bp search query "me envelope census onboarding subtree"` (row `cch-w43-bl-me-census-onboarding-subtree`) |
| 5 | No `cch-w43-s4` row was ever filed — `cch-w42-s3` IS S1's row | `bp task get cch-w43-s4 -o json` → `not_found` |
| 6 | #10201 / #10005 / #9955 all merged; D483's collision is discharged in fact | `for n in 10201 10005 9955; do gh pr view $n --json number,state,mergedAt; done` |
| 7 | The four census literals are ALIVE, at 106/81 — not discharged | `git show origin/main:cloud/priv/static/__preview__/breakpoint-sweep.test.mjs \| sed -n '573,583p'` |
| 8 | `api/` path trap: neither member verb lives under `api/` | `git show origin/main:api/lib/barkpark/accounts.ex \| grep -cE "remove_member_as\|update_member_role_as\|outranks\?"` → `0`; `git show origin/main:api/lib/barkpark/accounts/authz.ex` → fatal |
| 9 | The two server laws, on the tree, with the owner escape hatch | `git show origin/main:cloud/lib/barkpark_cloud/accounts.ex \| grep -n "def remove_member_as\|def update_member_role_as\|outranks?"` → 1715 / 1722 / 1784 / 1801 |
| 10 | AC1's cited anchors `:1720` / `:1799` are stale (blank line / bare `{:error, :forbidden}`) | `git show origin/main:cloud/lib/barkpark_cloud/accounts.ex \| sed -n '1720p;1799p'` |
| 11 | D485/AC6's five line numbers are ALL stale; the live five | `git show origin/main:cloud/priv/static/__preview__/smoke.mjs \| grep -nE "\(admin\)\|an admin roster"` → 2056/2435/2526; `git show origin/main:cloud/priv/static/__preview__/scenarios.mjs \| grep -n "(admin)"` → 2420/2455 |
| 12 | Both `(admin)`-labelled scenarios really pass `role: "owner"` | `git show origin/main:cloud/priv/static/__preview__/scenarios.mjs \| sed -n '2424p;2459p'` |
| 13 | D483's cited unit callers `:5814/:5871` are stale by ~1730 lines | `git show origin/main:cloud/priv/static/__app.test.mjs \| grep -n memberRowHtml` → 7131/7548/7550/7554/7558/7605/7607/7613/14425 |
| 14 | The lying cell renders inside a green test today | `git show origin/main:cloud/priv/static/__app.test.mjs \| sed -n '7605,7616p'` |

## Standing traps this recipe pins

- `smoke.mjs:2056` (`"an admin roster carries the typed-confirm Disconnect"`) sits under the
  **`providers-connected`** scenario, NOT under a members scenario — AC6 groups it with the
  members strings and it does not belong to that surface.
- `smoke.mjs:2526` / `scenarios.mjs:2455` are the **env-vars** screen, outside S1's fence.
