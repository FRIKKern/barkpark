defmodule BarkparkWeb.ShareTokenControllerTest do
  @moduledoc """
  P5 — the admin-only `/v1/shares/tokens` endpoints (mint / list / revoke).
  Minting is admin-gated (owner decision); the raw token is shown ONCE and the
  list never returns it.

  ## Tenancy confinement (arpss-w8)

  `:require_admin` proves a GLOBAL admin permission, not authority over the
  tenant a request names. These three actions additionally require the caller
  to be an ADMIN MEMBER of the workspace the request targets
  (`Tenancy.Auth.workspace_admin?/2`). Two assertions in this file moved to the
  fail-closed status when that landed — the mint test and the list+revoke test,
  both of which drove a Default-bound admin at a freshly created FOREIGN
  workspace, which is exactly the cross-tenant flow. Each is paired with a
  same-flow sibling inside the actor's OWN workspace that stays green, so the
  file proves both directions.

  MUTATION RECEIPTS (run in the builder's worktree, quoted in the commit body):

    * LEAK-CLOSED — swapping `workspace_admin?/2` for
      `Tenancy.Auth.authorize(actor, ws_id, :admin)` in
      `share_controller.ex`'s `workspace_admin?/2` helper turns
      "cross-tenant: a ws-A admin who is a plain member of ws-B …" RED
      (mint 201 where 403 is expected). The membership is what makes the test
      strong: written against a NON-member of B it would pass under the weaker
      predicate too.
    * HOST-ADMIN-PRESERVED — this is a PERMISSIVE assertion. It can never go
      red under a full reversion of the confinement, and on its own it does NOT
      catch an actor-vs-target confusion: authorizing against the ACTOR's own
      `workspace_id` leaves THIS test green (measured — the two cross-tenant
      tests below are what red on that mutation, 3 failures). It is
      mutation-verified against OVER-confinement instead: raising the admin
      role floor to `owner`, and refusing to honour a Default-workspace
      membership, each turn it RED (403 where 201 is expected).

  FIXTURE HYGIENE: every share here is planted through `Sharing.add_share/1`
  (a StoredShare row + `refresh/0`), never a bare `Application.put_env`. A
  put_env-planted share is erased by the NEXT `refresh/0`, and a wiped share
  makes mint 422 for a reason with nothing to do with tenancy — under which a
  `refute status == 201` assertion passes with the confinement DELETED. Hence
  also: every denial assertion here is status-EXACT.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Repo, Sharing, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  import Barkpark.TenancyFixtures

  @dataset "production"
  @admin "share-token-admin"
  @junior "share-token-junior"

  setup %{conn: conn} do
    {:ok, admin_token} =
      Auth.create_token(@admin, "tok-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior, "tok-junior", @dataset, ["read", "write"])

    ws = create_workspace!("tok-ws")
    proj = create_project!(ws, "tok-proj")
    scope = "#{ws.slug}/#{proj.slug}/#{@dataset}"

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares_env, [])

    # Planted as a STORED share so `Sharing.refresh/0` (fired by any later
    # add_share/remove_share) recomputes it back in instead of erasing it.
    {:ok, _} = Sharing.add_share("#{scope}:docs,media:edit")

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    %{conn: conn, scope: scope, ws: ws, proj: proj, admin_token: admin_token}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp admin(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{@admin}")
      |> put_req_header("content-type", "application/json")

  defp junior(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{@junior}")
      |> put_req_header("content-type", "application/json")

  defp bearer(conn, raw),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")

  # The Default Workspace/Project the self-hosted (host-is-admin) install runs
  # on. Asserted as PRECONDITIONS wherever a test depends on them rather than
  # assumed — ConnCase seeds them, but a proof that silently depends on a
  # fixture is a proof of the fixture.
  defp default_scope! do
    ws = Tenancy.get_default_workspace()
    proj = Tenancy.get_default_project()
    assert %Tenancy.Workspace{slug: "default"} = ws
    assert %Tenancy.Project{slug: "default"} = proj
    {ws, proj, "#{ws.slug}/#{proj.slug}/#{@dataset}"}
  end

  describe "POST /v1/shares/tokens" do
    test "minting into a FOREIGN workspace is 403 — the confinement's behaviour change",
         %{conn: conn, scope: scope} do
      # BEHAVIOUR CHANGE: this exact request returned 201 before arpss-w8. The
      # actor is the Default-bound admin; `scope` names a workspace it has no
      # membership in at all.
      resp = conn |> admin() |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})

      assert resp.status == 403
      assert json_response(resp, 403)["error"]["code"] == "forbidden"

      # and nothing was minted for the foreign scope
      assert Auth.list_share_tokens(scope) == []
    end

    test "non-admin is 403", %{conn: conn, scope: scope} do
      assert conn
             |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})
             |> Map.get(:status) == 401

      assert conn
             |> junior()
             |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})
             |> Map.get(:status) == 403
    end

    test "422 when the scope is not edit-shared", %{conn: conn} do
      # ORDERING CONTRACT: an unresolvable scope has no workspace to confine to,
      # so it must still fall through to the 422 — never a 403/404 from the
      # tenancy check running first.
      resp =
        conn
        |> admin()
        |> post("/v1/shares/tokens", %{scope: "nope/nope/production", surfaces: "docs"})

      assert resp.status == 422
      assert json_response(resp, 422)["error"]["message"] =~ "the scope is not edit-shared"
    end
  end

  describe "GET + DELETE /v1/shares/tokens" do
    test "list and revoke against a FOREIGN workspace are fail-closed",
         %{conn: conn, scope: scope} do
      # BEHAVIOUR CHANGE: before arpss-w8 the Default-bound admin minted, listed
      # and revoked this foreign workspace's tokens freely. The token is minted
      # through the PRIMITIVE here precisely because the HTTP mint is now denied.
      {:ok, {_raw, token}} =
        Auth.create_share_token(ws_slug(scope), proj_slug(scope), @dataset, ["docs"])

      scoped = conn |> admin() |> get("/v1/shares/tokens?scope=#{scope}")
      assert scoped.status == 200
      assert json_response(scoped, 200)["tokens"] == []

      # …and it is absent from the UNSCOPED list too (which used to dump every
      # workspace's rows).
      unscoped = conn |> admin() |> get("/v1/shares/tokens") |> json_response(200)
      refute Enum.any?(unscoped["tokens"], &(&1["id"] == token.id))

      revoke = conn |> admin() |> delete("/v1/shares/tokens/#{token.id}")
      assert revoke.status == 404
      assert json_response(revoke, 404)["error"]["message"] == "token not found"

      # STATUS IS NOT THE PROOF — reload the row and assert it is still live.
      assert is_nil(Repo.get(ApiToken, token.id).revoked_at)
    end

    test "revoke is admin-only", %{conn: conn} do
      assert conn
             |> junior()
             |> delete("/v1/shares/tokens/00000000-0000-0000-0000-000000000000")
             |> Map.get(:status) == 403
    end
  end

  describe "tenancy confinement" do
    test "self-hosted host-is-admin: mint -> list -> revoke end to end in the actor's own Default workspace",
         %{conn: conn, admin_token: admin_token} do
      # PROOF 2 — HOST-ADMIN-PRESERVED. The actor is built by the REAL
      # `Auth.create_token/4`: it falls back to the Default Workspace and writes
      # an admin-role membership there, which is what a single-tenant install
      # is. See the moduledoc for this proof's honest limit and the
      # over-confinement mutations that DO red it.
      {ws, _proj, scope} = default_scope!()
      assert TenancyAuth.membership_role(admin_token, ws.id) == "admin"

      {:ok, _} = Sharing.add_share("#{scope}:docs,media:edit")

      mint = conn |> admin() |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})
      assert mint.status == 201
      body = json_response(mint, 201)

      assert String.starts_with?(body["token"], "bpshare_")
      assert body["share_token"]["scope"] == scope
      assert body["share_token"]["surfaces"] == ["docs"]
      refute Map.has_key?(body["share_token"], "token_hash")
      assert {:ok, _} = Auth.verify_token(body["token"])

      id = body["share_token"]["id"]

      list = conn |> admin() |> get("/v1/shares/tokens?scope=#{scope}")
      assert list.status == 200
      listed = json_response(list, 200)["tokens"]
      assert Enum.any?(listed, &(&1["id"] == id))
      refute Enum.any?(listed, &Map.has_key?(&1, "token_hash"))

      revoke = conn |> admin() |> delete("/v1/shares/tokens/#{id}")
      assert revoke.status == 200
      assert json_response(revoke, 200)["revoked"] == true
      refute is_nil(Repo.get(ApiToken, id).revoked_at)
    end

    test "cross-tenant: a ws-A admin who is a plain member of ws-B cannot mint, list or revoke ws-B's share tokens",
         %{conn: conn, scope: scope, ws: ws_b} do
      # PROOF 1 — LEAK-CLOSED, and deliberately written against the HARD shape:
      # the actor holds a REAL `member` membership in ws-B. `authorize/3` says
      # :ok for that shape (member? AND the token's GLOBAL "admin" perm), so
      # swapping the predicate for authorize/3 turns this test RED. Against a
      # non-member of B the same test would pass under BOTH predicates and prove
      # materially less.
      ws_a = create_workspace!("leak-ws-a")
      raw = "share-token-ws-a-admin"

      {:ok, actor} =
        Auth.create_token(raw, "ws-a-admin", @dataset, ["read", "write", "admin"], ws_a.id)

      {:ok, _} = TenancyAuth.create_membership(ws_b.id, actor.id, "member")

      # preconditions: admin of A, plain member (never admin) of B
      assert TenancyAuth.membership_role(actor, ws_a.id) == "admin"
      assert TenancyAuth.membership_role(actor, ws_b.id) == "member"
      assert TenancyAuth.authorize(actor, ws_b.id, :admin) == :ok

      {:ok, {_raw_b, token_b}} =
        Auth.create_share_token(ws_slug(scope), proj_slug(scope), @dataset, ["docs"])

      # mint into B → 403
      mint = conn |> bearer(raw) |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})
      assert mint.status == 403
      assert Auth.list_share_tokens(scope) |> Enum.map(& &1.id) == [token_b.id]

      # list B's tokens → 200 with B's row absent (scoped AND unscoped)
      scoped = conn |> bearer(raw) |> get("/v1/shares/tokens?scope=#{scope}")
      assert scoped.status == 200
      assert json_response(scoped, 200)["tokens"] == []

      unscoped = conn |> bearer(raw) |> get("/v1/shares/tokens")
      assert unscoped.status == 200
      refute Enum.any?(json_response(unscoped, 200)["tokens"], &(&1["id"] == token_b.id))

      # revoke B's token → 404, byte-identical to a missing row
      revoke = conn |> bearer(raw) |> delete("/v1/shares/tokens/#{token_b.id}")
      assert revoke.status == 404
      assert json_response(revoke, 404)["error"]["message"] == "token not found"

      # THE ROW, not the status: still live.
      assert is_nil(Repo.get(ApiToken, token_b.id).revoked_at)
    end

    test "ids that cannot cast to a UUID are denials, never 500s", %{conn: conn} do
      # `workspace_admin?/2` raises FunctionClauseError on nil and
      # Ecto.Query.CastError on any non-UUID binary (including ""), so every id
      # reaching it is UUID-guarded first and anything that does not cast is a
      # DENIAL. A 500 here would trade a leak for a crash oracle.
      assert conn |> admin() |> delete("/v1/shares/tokens/not-a-uuid") |> Map.get(:status) == 404
      assert conn |> admin() |> delete("/v1/shares/tokens/%20") |> Map.get(:status) == 404

      # a row whose workspace_id is NULL (a pre-tenancy token): nil is a denial,
      # not a pass — on revoke, and on the list filter.
      {:ok, orphan} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token("orphan-share-token"),
          label: "orphan",
          dataset: @dataset,
          permissions: ["share-edit-docs"],
          share_scope: "orphan/orphan/#{@dataset}"
        })
        |> Repo.insert()

      assert is_nil(orphan.workspace_id)

      revoke = conn |> admin() |> delete("/v1/shares/tokens/#{orphan.id}")
      assert revoke.status == 404
      assert is_nil(Repo.get(ApiToken, orphan.id).revoked_at)

      list = conn |> admin() |> get("/v1/shares/tokens")
      assert list.status == 200
      refute Enum.any?(json_response(list, 200)["tokens"], &(&1["id"] == orphan.id))

      # and the mint action's scope resolution never reaches the predicate with
      # a blank/garbage workspace slug
      assert conn
             |> admin()
             |> post("/v1/shares/tokens", %{scope: "", surfaces: "docs"})
             |> Map.get(:status) == 422

      assert conn
             |> admin()
             |> post("/v1/shares/tokens", %{scope: " /x/#{@dataset}", surfaces: "docs"})
             |> Map.get(:status) == 422
    end
  end

  defp ws_slug(scope), do: scope |> String.split("/") |> Enum.at(0)
  defp proj_slug(scope), do: scope |> String.split("/") |> Enum.at(1)
end
