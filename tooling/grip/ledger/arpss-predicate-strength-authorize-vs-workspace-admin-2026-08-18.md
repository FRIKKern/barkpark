# Re-derivation recipe — predicate strength: `authorize/3` vs `workspace_admin?/2` (share-token confinement)

Verifier phase, epic `api-read-path-security-sweep`, wave
`api-read-path-security-sweep-wave-share-token-confinement-2026-08-18`.
Assignment: `predicate-strength-ruling`. Date 2026-08-18. Base `origin/main` = `cd75286b72d08e439adccf7a338e5c8e8e607641`.

## Question

Does `Barkpark.Tenancy.Auth.authorize(token, ws, :admin)` ignore `membership.role`?
If yes, a global-admin token that is a plain `member` of workspace B passes `authorize(:admin)` at B —
the exact cross-tenant admin bypass `workspace_admin?/2` was written to close (barkpark-23yi / barkpark-fsko).

## Source reading (level: origin/main bytes)

    git show origin/main:api/lib/barkpark/tenancy/auth.ex | sed -n '159,180p'   # authorize/3 api_token arm
    git show origin/main:api/lib/barkpark/tenancy/auth.ex | sed -n '316,340p'   # membership_role/2 + workspace_admin?/2
    git show origin/main:api/lib/barkpark_web/plugs/require_workspace_role.ex   # the repo's recorded ruling
    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '761,775p'     # :scoped_admin pipeline comment

## Run proof (level: running system)

Probes live in the session scratchpad (NOT in the repo — `mix test` takes an absolute path,
so no repo file is written):

  * `probe_predicate_strength_test.exs` — create ws A/B/C; `Auth.create_token(raw, label, "production",
    ["read","write","admin"], ws_a.id)`; `TenancyAuth.create_membership(ws_b.id, tok.id, "member")`;
    print `membership_role/2`, `member?/2`, `permits?/2`, `authorize/3`, `workspace_admin?/2` for A, B, C
    plus a non-UUID workspace id.
  * `probe_predicate_nil_totality_test.exs` — same token, `workspace_id = nil` on both predicates.

Ran from a clean worktree that already carries a compiled `MIX_ENV=test` build
(`.../scratchpad/srv-12405-red-repro`, PR-#12405 head; its diff does NOT touch
`api/lib/barkpark/tenancy/auth.ex`, verified with `git diff --name-only origin/main HEAD`):

    cd <worktree>/api && MIX_ENV=test mix test <scratchpad>/probe_predicate_strength_test.exs
    cd <worktree>/api && MIX_ENV=test mix test <scratchpad>/probe_predicate_nil_totality_test.exs

## Decisive output

    membership_role(tok, B)         = "member"
    permits?(tok, :admin)           = true
    AUTHORIZE(tok, B, :admin)       = :ok            <-- bypass
    WORKSPACE_ADMIN?(tok, B)        = false          <-- closed
    AUTHORIZE(tok, C, :admin)       = {:error, :forbidden}   (genuine non-member)
    WORKSPACE_ADMIN?(tok, A)        = true           (home workspace, role "admin")
    AUTHORIZE(tok, "not-a-uuid")    = RAISED Ecto.Query.CastError
    WORKSPACE_ADMIN?(tok,"not-uuid")= RAISED Ecto.Query.CastError
    AUTHORIZE(tok, nil, :admin)     = {:error, :forbidden}
    WORKSPACE_ADMIN?(tok, nil)      = RAISED FunctionClauseError
    MEMBERSHIP_ROLE(tok, nil)       = RAISED FunctionClauseError

## Ruling

Use `workspace_admin?/2`. It is strictly stronger, free, and already the repo's recorded gate for
scoped admin ops (`RequireWorkspaceRole`, `:scoped_admin` pipeline) and for credential-revealing
Studio surfaces (`connectors-settings-cred-installation-admin-gate`,
`connectors-settingslive-theme-plugin-per-write-belt`). A raw-credential surface may not use the
weaker gate.

Two mechanical obligations for the builder:

  1. `workspace_admin?/2` and `membership_role/2` are NOT total — `nil` raises `FunctionClauseError`,
     a non-UUID raises `Ecto.Query.CastError`. Guard both before calling (resolve the target workspace
     id first; `is_binary/1` + `Repo.uuid_or_nil/1`), or a 500 replaces a 404 on the credential surface.
     (`authorize/3` is total on `nil` but NOT on a non-UUID — same CastError.)
  2. The leak-closed proof gains strength: with `workspace_admin?/2` the ws-A actor may be an actual
     `member` of ws-B and still be denied. With `authorize/3` that same test would go GREEN-BY-BYPASS,
     so the proof would have had to use a genuine NON-member of B — a weaker statement.
