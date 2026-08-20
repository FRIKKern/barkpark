# M4 — api_token-only owner membership: re-derivation recipe (2026-08-20)

Verdict: M4 CONFIRMED (code + live HTTP + live prod data). The #7 hinge it was
supposed to decide is REFUTED — the workspace creator CAN mint a `["read"]`
token, so #7 does NOT collapse back into S1.

Baseline: origin/main a07a0baa138d628987706e94a31329379410f23a. The five files
below are byte-identical between that ref and the primary worktree at
6f724edfd8 (`git diff origin/main -- <paths>` is empty).

## 1. The %User{} head is unreachable from any lib caller

    git show origin/main:api/lib/barkpark/tenancy.ex | sed -n '912,926p'
    git grep -n "create_workspace_with_owner" origin/main -- api/lib cloud

Four lib call sites; all pass an ApiToken:
  workspace_controller.ex:56 (`conn.assigns[:api_token]`),
  playground_controller.ex:124 (admin_token),
  studio/studio_live/handlers/scope.ex:111 and studio_chrome.ex:252 — both
  guarded `case socket.assigns[:api_token] do %ApiToken{} = token`, else
  flash "Sign in to create a workspace".
Only `api/test/barkpark/tenancy_test.exs:246` reaches the `%User{}` head.

## 2. Live HTTP proof (local dev server on :4000, dev DB `barkpark_dev`)

Mint a probe admin token (writes to the LOCAL dev DB only):

    cd api && MIX_ENV=dev mix run --no-start -e \
      'Application.ensure_all_started(:ecto_sql); Application.ensure_all_started(:postgrex); {:ok,_}=Barkpark.Repo.start_link(); \
       import Ecto.Query; raw = "m4probe_x"; \
       ws = Barkpark.Repo.one!(from w in Barkpark.Tenancy.Workspace, where: w.slug == "default", select: w.id); \
       {:ok,t} = Barkpark.Auth.create_token(raw, "m4-probe", "production", ["read","write","admin"], ws); IO.puts(t.id)'

    curl -s -X POST http://localhost:4000/api/workspaces \
      -H "Authorization: Bearer m4probe_x" -H 'content-type: application/json' \
      -d '{"name":"M4 Probe WS"}'        # → 201, slug m4-probe-ws

    psql -d barkpark_dev -tAc "select principal_type, principal_id, role \
      from workspace_memberships where workspace_id='<new ws id>'"
    # → api_token|<TOKEN id>|owner        (never a `user` row)

Consequence (same script style, `mix run --no-start`):
    TA.membership(user, ws.id)        → nil
    TA.member?(user, ws.id)           → false
    TA.workspace_admin?(user, ws.id)  → false
    Tenancy.list_workspaces_for(user) → []

## 3. The mint endpoint IS reachable for the creator (#7 hinge refuted)

    curl -s -w "\nHTTP=%{http_code}\n" -X POST \
      http://localhost:4000/w/m4-probe-ws/p/default/v1/tokens \
      -H "Authorization: Bearer m4probe_x" -H 'content-type: application/json' \
      -d '{"label":"m4-read","permissions":["read"]}'
    # → HTTP=201, "permissions":["read"]

RequireWorkspaceRole reads `workspace_admin?(token, ws_id)` — the creator's OWN
api_token owner row satisfies it. #7's "every mintable token is public-tier" is a
CLIENT hardcode, not a server clamp: internal/bootstrap/bootstrap.go:374 and
internal/cli/vercel_cmd.go:549 both send `"permissions": ["public-read"]`.

## 4. Backfill denominator (live prod, guerrilla 157.180.90.121)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      "sudo -u postgres psql -d barkpark_prod -tAc \"select w.slug, \
        (select count(*) from workspace_memberships m where m.workspace_id=w.id and m.principal_type='user') user_rows, \
        (select count(*) from workspace_memberships m where m.workspace_id=w.id and m.principal_type='api_token') token_rows \
        from workspaces w order by w.slug\""
    # default|2|99      gyldendal|0|3

1 of 2 prod workspaces (the customer's) has ZERO user-typed memberships. Local
dev: 6 of 6 (9 membership rows, all api_token; 0 users).

## 5. No product-level remedy exists

    git ls-tree -r --name-only origin/main api/lib/barkpark_web/controllers | grep -i "member\|invit"
    # → no output. There is no membership/invite controller and no route that
    # inserts a workspace_membership. #6's second clause is CONFIRMED: the
    # backfill can only be done by SQL or a mix task, not through the product.
