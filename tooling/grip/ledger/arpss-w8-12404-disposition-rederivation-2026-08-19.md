# Re-derivation recipe — PR #12404 disposition (ShareLink half, ARPSS wave 8)

Verifier `[12404-disposition]`, 2026-08-19. Every row below is re-derivable by the
command in its own cell. Run from the repo root of a checkout with `origin` fetched.

## The PR

| Fact | Command |
|---|---|
| OPEN, MERGEABLE against main, 4 files | `gh pr view 12404 --repo FRIKKern/barkpark --json state,mergeable,files` |
| Full diff (links.ex / share_link_controller.ex / item_share.ex / share_link_test.exs) | `gh pr diff 12404 --repo FRIKKern/barkpark` |
| No drift: main has touched NONE of its 4 files since merge-base | `git log --oneline $(git merge-base refs/remotes/pr/12404 origin/main)..origin/main -- api/lib/barkpark/sharing/links.ex api/lib/barkpark_web/controllers/share_link_controller.ex api/lib/barkpark_web/live/studio/studio_live/handlers/item_share.ex api/test/barkpark_web/controllers/share_link_test.exs` → EMPTY |
| main is 14 commits ahead of the merge-base | `git rev-list --count $(git merge-base refs/remotes/pr/12404 origin/main)..origin/main` |

Fetch the branch first: `git fetch origin pull/12404/head:refs/remotes/pr/12404 -f`

## The red gate — the failures are REAL and they are #12404's own

    gh pr checks 12404 --repo FRIKKern/barkpark
    gh run view --repo FRIKKern/barkpark --job 95853407807 --log > /tmp/12404.log
    grep -nE "^\s*[0-9]\) test |tests, [0-9]+ failures" /tmp/12404.log

Trailer: `27 doctests, 14007 tests, 2 failures, 48 excluded`.

1. `pds_delete_receipt_differential_test.exs:245` — `expected response with status 200, got: 404`,
   body `{"error":{"code":"not_found","message":"link not found"...}}` (its new bound `fetch_scoped` arm).
2. `http_cache_policy_test.exs:198` — `expected response with status 201, got: 404`,
   body `{"error":{"code":"not_found","message":"no such item in this scope"...}}` (its new mint confinement).

The `Format` red is FOREIGN and pre-existing on main (`api/test/barkpark/portable_doc/render/compose_test.exs:602`):

    gh run view --repo FRIKKern/barkpark --job 95853407977 --log-failed | grep -A3 "not formatted"
    git show origin/main:api/test/barkpark/portable_doc/render/compose_test.exs | sed -n 602p   # >98 cols

## Both regressions ALSO red under the MEMBERSHIP predicate

Both fixtures mint their admin with `Auth.create_token/4` (→ resolved DEFAULT workspace, which is
where `insert_token_with_membership/3` writes the home membership) and then act on a
`create_workspace!` fixture that carries no membership for that principal. So
`Tenancy.Auth.workspace_admin?(token, fixture_ws)` is `false` — a denial, exactly as under binding.

    git show origin/main:api/test/barkpark_web/contract/pds_delete_receipt_differential_test.exs | sed -n '99,101p;228,246p'
    git show origin/main:api/test/barkpark_web/integration/http_cache_policy_test.exs | sed -n '179,199p'
    git show origin/main:api/lib/barkpark/tenancy/auth.ex | sed -n '325,340p'   # workspace_admin?/2 + @canonical

Consequence: the wave MUST repair those two fixtures (grant the acting principal an admin
membership in the target workspace, e.g. `create_token/5` with `ws.id`), and both files must be
inside the builder's fence and inside the gate list.

## Ledger state — nothing is stranded by closing #12404

    bp task get arpss-share-link-object-authz-close -o json      # lifecycle open; claim.worker null; expired_at 2026-08-18T17:52:00Z; 8/9 met
    bp task get arpss-w8-rework-12404-onto-membership -o json    # lifecycle open; claim null; priority 0; 0/5 met

The 8 met=true criteria on `arpss-share-link-object-authz-close` stamp the BANNED shape
(nil-workspace admin sees all; host-admin proven by a direct `%ApiToken{workspace_id: nil}` insert).
Criterion 4 of the rework task orders flipping them.

## Sibling PRs — zero file overlap with #12404

    gh pr list --repo FRIKKern/barkpark --state open --search share --json number,title,files

#12405 and #12519 both edit `share_controller.ex` (they collide with EACH OTHER, not with #12404).
Neither touches `share_link_controller.ex`, `sharing/links.ex`, or `share_link_test.exs`.

## The five lines any second implementation would re-write (semantic collision set)

`git show refs/remotes/pr/12404 -- <file>` shows each hunk.

- `api/lib/barkpark_web/controllers/share_link_controller.ex` — `mint/2` `with` head (gate inserted
  after `get_workspace_by_slug`, before `get_project`); `list/2` `with` head (same slot);
  `revoke/2`'s `case Links.revoke(id) do`; the `else` arms; new private `token_workspace_id/1` +
  `ensure_token_scope/2`.
- `api/lib/barkpark/sharing/links.ex` — `revoke/1` → `revoke/2` head + private `fetch_scoped/2`.
- `api/test/barkpark_web/controllers/share_link_test.exs` — setup line minting `@admin`
  (`create_token/4` → `/5` with `ws.id`), plus `host_admin_token!/1` and `seed_link!/3` helpers.

A fresh branch off origin/main produces NO git conflict today (main has zero commits on these
files), but the SECOND of the two PRs to merge conflicts on all five, and main's merge queue is
non-strict — a stale-green second merge lands a mixed predicate.
