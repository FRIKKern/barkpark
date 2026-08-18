# Re-derivation recipe — LiveView twin of the ShareLink revoke IDOR (item_share.ex:69)

Wave: api-read-path-security-sweep-wave-share-link-raw-token-2026-08-18
Verifier lane: liveview-twin-ruling · 2026-08-19 · all facts read off `origin/main`, not a worktree.

## Claim 1 — `Links.revoke/1` on main is arity-1 and tenant-blind

    git show origin/main:api/lib/barkpark/sharing/links.ex | sed -n '89,110p'

Expect: `def revoke(id) when is_binary(id)` → `Repo.uuid_or_nil/1` → bare
`Repo.get(ShareLink, uuid)` → `change(revoked_at:)`. No `workspace_id` anywhere.

## Claim 2 — the Studio handler passes a client id straight into it and never reads the tenant

    git show origin/main:api/lib/barkpark_web/live/studio/studio_live/handlers/item_share.ex | grep -n "item_share_revoke\|Links.revoke\|current_workspace"

Expect: `67: def item_share_revoke(%{"id" => id}, socket)`, `69: Barkpark.Sharing.Links.revoke(id)`,
and the ONLY `current_workspace` hit is line 49 — inside `item_share_create/2`, not revoke.

Event wiring (client-reachable):

    git show origin/main:api/lib/barkpark_web/live/studio/studio_live.ex | sed -n '413,415p'

## Claim 3 — `Caps.admin?/1`'s token arm is workspace-blind by design

    git show origin/main:api/lib/barkpark_web/studio/caps.ex | sed -n '224,256p'

Expect `def admin?(socket)` = `token_admin?(socket.assigns[:api_token]) or account_admin?(...)`,
`defp token_admin?(%_{} = token), do: Barkpark.Auth.has_permission?(token, "admin")`,
and the comment "The token arm is deliberately membership-FREE (an `admin`-permissioned
api_token is admin wherever it is)". The account arm binds only the actor's OWN mounted ws.

## Claim 4 — the Studio scope resolver DOES fail closed (so the socket's ws is never foreign)

    git show origin/main:api/lib/barkpark_web/live_scope.ex | sed -n '95,135p'
    git show origin/main:api/lib/barkpark/tenancy/auth.ex | sed -n '169,178p'

Expect `resolve_and_authorize/2` → `authorize_read/4` → `Tenancy.Auth.authorize(token, ws.id, :read)`,
whose ApiToken arm is `member?(token, workspace_id) and permits?(token, action)`; the `else` branch
is `deny(socket)`. A non-member cannot mount the named workspace.

CAVEAT that matters for any fix that threads `socket.assigns.current_workspace`:

    git show origin/main:api/lib/barkpark_web/studio_chrome.ex | sed -n '450,466p'

`default_scope_fallback/1` pins the seeded Default workspace on flat surfaces with NO membership
check. So `current_workspace` is membership-verified only on the canonical `/w/:ws/p/:proj` route.

## Claim 5 — the residual is already filed; do not duplicate

    bp task get arpss-item-share-revoke-unscoped-revoke -o json

Expect `lifecycle_status: open`, `parent_id: api-read-path-security-sweep`, priority 1, and a
description naming BOTH callsites — "(1) the LiveView handler item_share.ex:67 item_share_revoke,
gated only by Caps.admin?(socket)… (2) HTTP DELETE /v1/shares/links/:id" — plus the run-proof
"PROBE_RESULT: LEAK". Its header line "SUBSUMED BY SA-S1 arpss-share-link-object-authz-close"
goes STALE the moment #12404 is superseded or re-fenced without the LiveView arm.

## Claim 6 — #12404 already carries the LiveView fix, on the banned predicate

    gh pr view 12404 --json state,mergeable,headRefName -q '.'
    gh pr view 12404 --json files -q '.files[].path'
    gh pr diff 12404 | sed -n '/item_share.ex/,/^diff/p'

Expect the four-file list including `…/handlers/item_share.ex`, and the hunk threading
`workspace_id: socket.assigns[:current_workspace] && …id` with a nil-permissive
"host/platform-admin passthrough" comment.
