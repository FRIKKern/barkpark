# Re-derivation recipes — share-token confinement, ledger-siblings verifier (2026-08-18)

Every row re-derives from clean `origin/main` + the published Barkpark ledger. No worktree state is load-bearing.

## Filed this round (published children of `api-read-path-security-sweep`)

| id | what |
|---|---|
| `task-f11c6ed5e211476b` | PROVED: `DELETE /v1/fleet/support-tokens/:token_id` revokes ANY api_token by id |
| `task-2097f4639408aa48` | `POST`/`DELETE /v1/shares` free-text scope: forgeable mint precondition + cross-tenant DoS |
| `task-46e7d44068e7185e` | RULING NEEDED: criteria 4/6 of `arpss-share-controller-edit-token-authz` vs a membership predicate |

Read any of them back from the PUBLISHED perspective:

    bp task get task-f11c6ed5e211476b -o json | head -40
    bp task get task-2097f4639408aa48 -o json | head -40
    bp task get task-46e7d44068e7185e -o json | head -40

Confirm they are attached to the epic (child_count went 89 -> 92):

    bp task get api-read-path-security-sweep -o json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['child_count']);print([c['doc_id'] for c in d['children']][-3:])"

## Fleet support-token by-id revoke hole (4 hops, all origin/main)

    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '2046,2050p'
    git show origin/main:api/lib/barkpark_web/plugs/require_admin.ex | sed -n '13,20p'
    git show origin/main:api/lib/barkpark_web/controllers/fleet_support_token_controller.ex | sed -n '74,76p'
    git show origin/main:api/lib/barkpark/auth.ex | sed -n '227,241p'

Decisive: `require_admin` is only `Auth.has_permission?(token, "admin")`; `delete/2` never reads
`conn.assigns[:api_token]`; `revoke_token/1` is a bare `Repo.get(ApiToken, uuid)` — no workspace
filter and no token-family filter (the `fleet-support-` label is applied at mint only).

Prior art that this ANSWERS (do not treat as a duplicate — that task still owns `app_token_controller`):

    bp task get arpss-other-revoke-token-callers-authz-audit -o json | head -20   # open, priority 3, GH issue 12396

## Share registry create/delete — no tenancy check anywhere

    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '2099,2107p'
    git show origin/main:api/lib/barkpark_web/controllers/share_controller.ex | sed -n '42,90p'
    git show origin/main:api/lib/barkpark/sharing/sharing.ex | sed -n '207,266p'

Decisive: `add_share/1` upserts `workspace_slug` as a STRING with no existence/tenancy check;
`remove_share/3` `delete_all()`s the victim row AND calls
`Barkpark.Auth.revoke_share_tokens(ws_slug, proj_slug, dataset)` — a hard batch revoke of the
victim's live edit tokens. Mint's 422 precondition (`create_share_token` requires an `:edit` share)
is therefore writable by the same actor class the token confinement is meant to stop.

## Criteria conflict

    bp task get arpss-share-controller-edit-token-authz -o json \
      | python3 -c "import json,sys;[print(i,c['criterion'],c['met']) for i,c in enumerate(json.load(sys.stdin)['doc']['content']['acceptance_criteria'],1)]"

Criteria 4 and 6 are `met: true` and both assert "a nil-workspace admin still sees all" /
"host admin (nil workspace) still reaches revoke/list/mint across any workspace". Criterion 6's own
evidence records the hand-insert (`direct Repo.insert workspace_id nil`) — i.e. the arm is not
reachable through `Auth.create_token/5`.

## Sibling PR still shipping the nil-permissive predicate

    gh pr view 12404 --json number,state,isDraft,title,files

Returns `OPEN`, `isDraft: false`, touching `share_link_controller.ex`, `sharing/links.ex`,
`live/studio/studio_live/handlers/item_share.ex`, `test/.../share_link_test.exs` — so the two halves
of the corridor are on course to land two different tenancy rules unless the lead sequences them.
