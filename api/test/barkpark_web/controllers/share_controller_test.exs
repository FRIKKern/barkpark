defmodule BarkparkWeb.ShareControllerTest do
  @moduledoc """
  P4b — contract tests for `/v1/shares`, the admin-only sharing registry CRUD
  behind `bp share ls/add/rm`.

  Covers:
    * auth gating — 401 anon, 403 non-admin, 200 admin on every verb
    * add upserts a stored share and makes it live (shared?/4)
    * add rejects an invalid scope/surface (422, no row)
    * rm removes a stored share and refreshes the live list
    * ls reports both the env baseline and stored shares, tagged by source
    * ls CONFINES the stored half to the caller's admin workspaces
    * TENANCY CONFINEMENT of the write half (arpss-w8 slice 2, below)

  ## Tenancy confinement (arpss-w8, slice 2)

  `:require_admin` proves a GLOBAL admin permission, never authority over the
  tenant a request names. `create/2` and `delete/2` therefore additionally
  require the caller to be an ADMIN MEMBER of the workspace the SCOPE names
  (`Tenancy.Auth.workspace_admin?/2`, via the same private helper slice 1
  landed for the `/tokens` actions — one predicate, not two mechanisms).

  BEHAVIOUR CHANGE THAT SHIPS, and why several tests below now plant a real
  Workspace row: before this slice, `POST /v1/shares` had ZERO binding to the
  tenancy tables, so `"gyldendal/books/production"` created a live share for a
  workspace that did not exist. Every scope a test drives through the HTTP
  surface now names a workspace the actor administers; the scopes that name
  nothing are the fail-closed proofs.

  MUTATION RECEIPTS (run in the builder's worktree, quoted in the commit body):

    * FORGE-CLOSED — deleting the `create/2` predicate (calling `do_create/4`
      unconditionally) turns "cross-tenant: a ws-A admin … cannot forge the
      mint precondition …" RED: `create` answers 201 and the foreign `:edit`
      share goes live (`Sharing.shared?(ws_b …, :docs)` becomes true).
      HONEST LIMIT, measured: with slice 1 merged, `mint_token/2` denies the
      ws-B mint on its OWN predicate, so that single mutation does NOT get as
      far as a live `bpshare_` token. Deleting BOTH predicates does — that run
      is recorded in the commit body, and it is the reason this slice exists:
      the registry is the mint's precondition, so confining only the mint left
      the forge one merge away.
    * DoS-CLOSED — deleting the `delete/2` predicate turns "cross-tenant: a
      ws-A admin cannot delete ws-B's share …" RED with the victim token's
      `revoked_at` STAMPED (the assertion that reloads the row, not the one
      that reads the status).
    * PREDICATE STRENGTH — swapping `workspace_admin?/2` for
      `TenancyAuth.authorize(actor, ws_id, :admin)` turns both cross-tenant
      tests RED, because the attacker holds a REAL `member` row in ws-B and
      `authorize/3`'s api_token arm is `member? AND the token's GLOBAL
      permissions[]`. Written against a NON-member of B, the same tests would
      pass under the weaker predicate and prove materially less.
    * LISTING-CLOSED (`GET /v1/shares`, the STORED half) — on clean
      origin/main `index/2` mapped `Sharing.list_stored/0` straight to JSON, so
      a ws-A admin saw EVERY workspace's stored share. "cross-tenant: GET
      /v1/shares does not list ws-B's stored share …" reproduces it RED there
      (ws-B's `ls-ws-b/ls-proj-b/production` row present in the payload), and
      both mutations of the new clamp turn it RED again: `-> true` (no
      confinement) and `authorize/3` in place of `workspace_admin?/2` (the
      attacker's real `member` row in ws-B walks through the weaker predicate).
      The test is not satisfiable by returning nothing — it also asserts the
      actor's OWN ws-A stored row is still listed.

  SCOPE BOUNDARY, deliberate: only the STORED half of `index/2` is confined.
  The env-declared half stays unclamped pending the owner ruling
  `arpss-stored-share-registry-ruling` (an env entry may legally name a
  workspace that does not exist, so it has no tenancy row to authorize
  against). The listing test pins that on purpose: `env-only-ws` names no
  workspace, the actor administers nothing there, and the row MUST still be
  reported — a future clamp of the env half will red this assertion, which is
  the intent.

  FIXTURE HYGIENE: every share is planted through `Sharing.add_share/1` (a
  StoredShare row + `refresh/0`) or through the HTTP verb under test, never a
  bare `Application.put_env(:barkpark, :shares, …)` — `Sharing.refresh/0`
  recomputes `:shares` from `shares_env() ++ list_stored()`, so a put_env-only
  share is ERASED by the next write and the resulting 422 would read as success
  under a loose `refute status == 201`. Both `:shares` and `:shares_env` are
  snapshotted and restored. Denial assertions are status-EXACT.

  `async: false`: the registry lives in the process-global `:barkpark, :shares`
  / `:shares_env` env, restored on_exit.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Repo, Sharing}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Sharing.StoredShare
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  import Barkpark.TenancyFixtures

  @admin_token "barkpark-test-admin-share"
  @junior_token "barkpark-test-junior-share"
  @attacker_token "barkpark-test-ws-a-admin-share"
  @owner_token "barkpark-test-own-ws-admin-share"

  setup do
    {:ok, admin} =
      Auth.create_token(@admin_token, "share-admin", "test", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "share-junior", "test", ["read", "write"])

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    %{admin: admin}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp admin_conn(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin_token)
    |> put_req_header("content-type", "application/json")
  end

  defp junior_conn(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @junior_token)
    |> put_req_header("content-type", "application/json")
  end

  defp bearer(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  # A Workspace with `admin` PRESENT as the actor's membership ROLE — the shape
  # the confinement reads. Asserted, not assumed: a fixture that silently
  # stopped granting the row would otherwise turn these into vacuous tests.
  defp admin_ws!(%ApiToken{} = actor, slug) do
    ws = create_workspace!(slug)
    {:ok, _} = TenancyAuth.create_membership(ws.id, actor.id, "admin")
    assert TenancyAuth.workspace_admin?(actor, ws.id)
    ws
  end

  # ── auth gating ─────────────────────────────────────────────────────────

  describe "auth gating" do
    test "GET /v1/shares is 401 anon, 403 junior, 200 admin", %{conn: conn} do
      assert get(conn, "/v1/shares").status == 401
      assert get(junior_conn(conn), "/v1/shares").status == 403
      assert get(admin_conn(conn), "/v1/shares").status == 200
    end

    test "POST /v1/shares is 401 anon, 403 junior", %{conn: conn, admin: admin} do
      admin_ws!(admin, "gyldendal")
      body = %{scope: "gyldendal/default/production", surfaces: "papers"}
      assert post(conn, "/v1/shares", body).status == 401
      assert post(junior_conn(conn), "/v1/shares", body).status == 403
      # the rejected writes never persisted a share
      refute Sharing.shared?("gyldendal", "default", "production", :papers)
    end

    test "DELETE /v1/shares is 401 anon, 403 junior", %{conn: conn} do
      assert delete(conn, "/v1/shares", %{scope: "x"}).status == 401
      assert delete(junior_conn(conn), "/v1/shares", %{scope: "x"}).status == 403
    end
  end

  describe "canonical error envelope" do
    test "validation (422) and not_found (404) are code + request_id objects, not bare strings",
         %{conn: conn} do
      # Missing scope → 422. Was a bare `%{"error" => "scope is required"}`;
      # now a keyable code + the human message + a request_id.
      bad = conn |> admin_conn() |> post("/v1/shares", %{surfaces: "papers"})
      body = json_response(bad, 422)
      assert body["error"]["code"] == "validation_failed"
      assert body["error"]["message"] == "scope is required"
      assert is_binary(body["error"]["request_id"])

      # Revoking a nonexistent share-edit token → 404 canonical envelope.
      nf =
        conn |> admin_conn() |> delete("/v1/shares/tokens/11111111-1111-1111-1111-111111111111")

      nfb = json_response(nf, 404)
      assert nfb["error"]["code"] == "not_found"
      assert nfb["error"]["message"] == "token not found"
      assert is_binary(nfb["error"]["request_id"])
    end

    test "a malformed (non-UUID) token id is a clean 404, not an Ecto CastError 500", %{
      conn: conn
    } do
      # revoke_token queries ApiToken by :binary_id; before the UUID-cast guard a
      # garbage id raised Ecto.CastError → 500. Now it's a canonical 404.
      resp = conn |> admin_conn() |> delete("/v1/shares/tokens/not-a-uuid")
      assert json_response(resp, 404)["error"]["code"] == "not_found"
    end
  end

  # ── add (POST) ──────────────────────────────────────────────────────────

  describe "POST /v1/shares" do
    test "creates a share and it goes live immediately", %{conn: conn, admin: admin} do
      admin_ws!(admin, "gyldendal")
      body = %{scope: "gyldendal/books/production", surfaces: "papers,docs", access: "read"}

      resp = conn |> admin_conn() |> post("/v1/shares", body)
      assert resp.status == 201
      assert %{"share" => share} = json_response(resp, 201)
      assert share["source"] == "stored"
      assert Enum.sort(share["surfaces"]) == ["docs", "papers"]

      assert Sharing.shared?("gyldendal", "books", "production", :papers)
      assert Sharing.shared?("gyldendal", "books", "production", :docs)
    end

    test "defaults access to read and scope project/dataset", %{conn: conn, admin: admin} do
      admin_ws!(admin, "gyldendal")

      resp = conn |> admin_conn() |> post("/v1/shares", %{scope: "gyldendal", surfaces: "papers"})
      assert resp.status == 201

      assert Sharing.access_for("gyldendal", "default", "production") == :read
    end

    test "edit access is honored", %{conn: conn, admin: admin} do
      admin_ws!(admin, "g")
      body = %{scope: "g/p/production", surfaces: "media", access: "edit"}
      assert (conn |> admin_conn() |> post("/v1/shares", body)).status == 201
      assert Sharing.access_for("g", "p", "production") == :edit
    end

    test "422 on a wildcard scope, no share created", %{conn: conn} do
      resp =
        conn |> admin_conn() |> post("/v1/shares", %{scope: "*/p/production", surfaces: "papers"})

      assert resp.status == 422
      refute Sharing.shared?("*", "p", "production", :papers)
    end

    test "422 when surfaces are all unknown", %{conn: conn, admin: admin} do
      admin_ws!(admin, "g")

      resp =
        conn |> admin_conn() |> post("/v1/shares", %{scope: "g/p/production", surfaces: "wat"})

      assert resp.status == 422
    end

    test "422 when scope is missing", %{conn: conn} do
      resp = conn |> admin_conn() |> post("/v1/shares", %{surfaces: "papers"})
      assert resp.status == 422
    end
  end

  # ── rm (DELETE) ─────────────────────────────────────────────────────────

  describe "DELETE /v1/shares" do
    test "removes a stored share and refreshes the live list", %{conn: conn, admin: admin} do
      admin_ws!(admin, "gyldendal")
      assert {:ok, _} = Sharing.add_share("gyldendal/books/production:papers:read")
      assert Sharing.shared?("gyldendal", "books", "production", :papers)

      resp = conn |> admin_conn() |> delete("/v1/shares", %{scope: "gyldendal/books/production"})
      assert resp.status == 200
      assert %{"removed" => 1} = json_response(resp, 200)

      refute Sharing.shared?("gyldendal", "books", "production", :papers)
    end

    test "removing an absent scope in a workspace the caller administers returns removed: 0",
         %{conn: conn, admin: admin} do
      admin_ws!(admin, "nobody")
      resp = conn |> admin_conn() |> delete("/v1/shares", %{scope: "nobody/here/production"})
      assert resp.status == 200
      assert %{"removed" => 0} = json_response(resp, 200)
    end
  end

  # ── ls (GET) ────────────────────────────────────────────────────────────

  describe "GET /v1/shares" do
    # FIXTURE STRENGTHENED (not weakened) for the stored-half clamp: `db-ws` is
    # now a REAL workspace the caller administers, because the stored half of
    # the listing is confined to the caller's admin workspaces. Both assertions
    # below are byte-identical to before — only the fixture gained the tenancy
    # row the listing has always implied. `env-ws` deliberately stays a
    # workspace that does NOT exist: the env half is unclamped (pending
    # `arpss-stored-share-registry-ruling`) and must still be reported.
    test "reports env baseline + stored, each tagged by source", %{conn: conn, admin: admin} do
      admin_ws!(admin, "db-ws")
      Application.put_env(:barkpark, :shares_env, Sharing.parse("env-ws:papers:read"))
      assert {:ok, _} = Sharing.add_share("db-ws/default/production:docs:edit")

      body = conn |> admin_conn() |> get("/v1/shares") |> json_response(200)

      assert body["active"] == true
      sources = body["shares"] |> Enum.group_by(& &1["source"])
      assert [%{"workspace" => "env-ws"}] = sources["env"]
      assert [%{"workspace" => "db-ws", "access" => "edit"}] = sources["stored"]
    end

    test "empty when nothing is shared (default-off)", %{conn: conn} do
      body = conn |> admin_conn() |> get("/v1/shares") |> json_response(200)
      assert body == %{"shares" => [], "active" => false}
    end
  end

  # ── tenancy confinement (arpss-w8 slice 2) ──────────────────────────────

  # The attacker: a REAL admin of ws-A holding a REAL plain `member` row in
  # ws-B — the shape `authorize/3` waves through and `workspace_admin?/2`
  # denies. Returns {actor, ws_b, proj_b, scope_b}.
  defp cross_tenant_actor!(prefix) do
    ws_a = create_workspace!("#{prefix}-ws-a")
    ws_b = create_workspace!("#{prefix}-ws-b")
    proj_b = create_project!(ws_b, "#{prefix}-proj-b")
    scope_b = "#{ws_b.slug}/#{proj_b.slug}/production"

    {:ok, actor} =
      Auth.create_token(
        @attacker_token,
        "ws-a-admin",
        "test",
        ["read", "write", "admin"],
        ws_a.id
      )

    {:ok, _} = TenancyAuth.create_membership(ws_b.id, actor.id, "member")

    # PRECONDITIONS — the whole strength of these tests lives here.
    assert TenancyAuth.membership_role(actor, ws_a.id) == "admin"
    assert TenancyAuth.membership_role(actor, ws_b.id) == "member"
    # …and the weaker predicate WOULD let this actor through:
    assert TenancyAuth.authorize(actor, ws_b.id, :admin) == :ok
    refute TenancyAuth.workspace_admin?(actor, ws_b.id)

    {actor, ws_b, proj_b, scope_b}
  end

  describe "tenancy confinement" do
    test "cross-tenant: a ws-A admin who is a plain member of ws-B cannot forge the mint precondition by creating an :edit share for ws-B",
         %{conn: conn} do
      {_actor, ws_b, proj_b, scope_b} = cross_tenant_actor!("forge")

      # STEP 1 — forge the precondition. 201 before this slice.
      create =
        conn
        |> bearer(@attacker_token)
        |> post("/v1/shares", %{scope: scope_b, surfaces: "docs,media", access: "edit"})

      assert create.status == 403
      body = json_response(create, 403)
      assert body["error"]["code"] == "forbidden"
      assert body["error"]["message"] == "workspace access required"

      # THE STORE, not the status: nothing was written and ws-B is not shared.
      assert Sharing.list_stored() == []
      assert Repo.aggregate(StoredShare, :count) == 0
      refute Sharing.shared?(ws_b.slug, proj_b.slug, "production", :docs)
      assert Sharing.access_for(ws_b.slug, proj_b.slug, "production") == nil

      # STEP 2 — mint anyway. Denied, and no live token exists for ws-B.
      mint =
        conn
        |> bearer(@attacker_token)
        |> post("/v1/shares/tokens", %{scope: scope_b, surfaces: "docs"})

      assert mint.status == 403
      assert Auth.list_share_tokens(scope_b) == []
    end

    test "cross-tenant: a ws-A admin cannot delete ws-B's share, and ws-B's live edit token keeps revoked_at nil",
         %{conn: conn} do
      {_actor, ws_b, proj_b, scope_b} = cross_tenant_actor!("dos")

      # ws-B's OWN legitimate share and edit token.
      assert {:ok, _} = Sharing.add_share("#{scope_b}:docs,media:edit")

      {:ok, {victim_raw, victim}} =
        Auth.create_share_token(ws_b.slug, proj_b.slug, "production", ["docs"])

      assert {:ok, _} = Auth.verify_token(victim_raw)
      assert is_nil(victim.revoked_at)

      del = conn |> bearer(@attacker_token) |> delete("/v1/shares", %{scope: scope_b})
      assert del.status == 403
      assert json_response(del, 403)["error"]["code"] == "forbidden"

      # THE ROW, not the status. `remove_share/3` hard-revokes every edit token
      # under the scope, so this assertion is what the DoS actually destroys.
      assert is_nil(Repo.get(ApiToken, victim.id).revoked_at)
      assert {:ok, _} = Auth.verify_token(victim_raw)

      # …and ws-B's share itself survived.
      assert Sharing.shared?(ws_b.slug, proj_b.slug, "production", :docs)
      assert Sharing.access_for(ws_b.slug, proj_b.slug, "production") == :edit
      assert Repo.aggregate(StoredShare, :count) == 1
    end

    test "cross-tenant: GET /v1/shares does not list ws-B's stored share to a ws-A admin",
         %{conn: conn} do
      {_actor, ws_b, proj_b, scope_b} = cross_tenant_actor!("ls")

      # ws-B's OWN legitimate stored share — planted through the store, not the
      # HTTP verb, so the LISTING leak is reproduced even though `create/2` is
      # already confined.
      assert {:ok, _} = Sharing.add_share("#{scope_b}:docs,media:edit")

      # FIXTURE NON-VACUITY. The attack row must be LIVE in the store before the
      # listing is read: if `add_share/1` ever stops persisting this scope, the
      # refutes below would pass while proving nothing at all. The `{:ok, _}`
      # above only says the call returned — this says the row is really there.
      assert Sharing.shared?(ws_b.slug, proj_b.slug, "production", :docs)

      # ws-A's own stored share — the actor DOES administer this one. Without
      # it this test would pass against a clamp that simply returns nothing.
      assert {:ok, _} = Sharing.add_share("ls-ws-a/default/production:papers:read")

      # An env-declared share naming a workspace the actor does not administer
      # (and which does not exist at all). The env half is DELIBERATELY left
      # unclamped pending `arpss-stored-share-registry-ruling`, so this row MUST
      # stay visible — this assertion pins that scope boundary.
      Application.put_env(:barkpark, :shares_env, Sharing.parse("env-only-ws:papers:read"))

      body = conn |> bearer(@attacker_token) |> get("/v1/shares") |> json_response(200)

      grouped = Enum.group_by(body["shares"], & &1["source"])
      stored = grouped["stored"] || []

      # THE LEAK: ws-B's row must not appear in ANY half of the payload.
      refute Enum.any?(body["shares"], &(&1["workspace"] == ws_b.slug)),
             "ws-B's share leaked into the listing: #{inspect(body["shares"])}"

      refute Enum.any?(stored, &(&1["scope"] == "#{ws_b.slug}/#{proj_b.slug}/production"))

      # …and the actor still sees its OWN workspace's stored share.
      assert [%{"workspace" => "ls-ws-a", "access" => "read"}] = stored

      # …and the env half is untouched by this clamp.
      assert [%{"workspace" => "env-only-ws"}] = grouped["env"]
    end

    test "ghost share: POST for a workspace that does not exist is 422 and persists nothing",
         %{conn: conn} do
      resp =
        conn
        |> admin_conn()
        |> post("/v1/shares", %{
          scope: "no-such-ws/no-such-proj/production",
          surfaces: "docs,media",
          access: "edit"
        })

      assert resp.status == 422
      body = json_response(resp, 422)
      assert body["error"]["code"] == "validation_failed"
      # Same words `describe_token_error(:unknown_scope)` already uses on the
      # mint surface — the ruling (422, not 404) is written up in the
      # controller moduledoc, which the merge carries.
      assert body["error"]["message"] ==
               "could not add share: the workspace/project does not exist"

      # NO ROW. A ghost row would go live the moment someone registers the slug.
      assert Repo.aggregate(StoredShare, :count) == 0
      assert Sharing.list_stored() == []
      refute Sharing.shared?("no-such-ws", "no-such-proj", "production", :docs)
    end

    test "same-workspace: an admin created by Auth.create_token/5 still creates, mints and deletes end to end in its OWN workspace",
         %{conn: conn} do
      # The admin is built the way a real install builds one: `create_token/5`
      # writes the home membership in the resolved workspace. No hand-inserted
      # %ApiToken{workspace_id: nil} row — that shape is unreachable here and
      # would prove nothing.
      ws = create_workspace!("own-ws")
      proj = create_project!(ws, "own-proj")
      scope = "#{ws.slug}/#{proj.slug}/production"

      {:ok, owner} =
        Auth.create_token(@owner_token, "own-admin", "test", ["read", "write", "admin"], ws.id)

      assert TenancyAuth.membership_role(owner, ws.id) == "admin"

      create =
        conn
        |> bearer(@owner_token)
        |> post("/v1/shares", %{scope: scope, surfaces: "docs,media", access: "edit"})

      assert create.status == 201
      assert Sharing.access_for(ws.slug, proj.slug, "production") == :edit

      # the precondition it just declared is legitimately mintable
      mint =
        conn
        |> bearer(@owner_token)
        |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})

      assert mint.status == 201
      minted = json_response(mint, 201)
      assert String.starts_with?(minted["token"], "bpshare_")
      assert {:ok, _} = Auth.verify_token(minted["token"])
      minted_id = minted["share_token"]["id"]

      del = conn |> bearer(@owner_token) |> delete("/v1/shares", %{scope: scope})
      assert del.status == 200
      assert json_response(del, 200)["removed"] == 1
      refute Sharing.shared?(ws.slug, proj.slug, "production", :docs)

      # removing the share hard-revokes its OWN edit tokens — the intended
      # behaviour, unchanged, now reachable only by the scope's own admin.
      refute is_nil(Repo.get(ApiToken, minted_id).revoked_at)
    end

    test "malformed scopes are denials, never 500s", %{conn: conn} do
      # Nothing malformed can reach `TenancyAuth.workspace_admin?/2`: the scope
      # is parsed first, and the id handed to the predicate always comes from
      # `Tenancy.get_workspace_by_slug/1` (a real UUID) or the request never
      # gets there. The slice-1 helper additionally routes every id through
      # `Repo.uuid_or_nil/1`, so a nil/garbage id is a DENIAL, not a crash.
      for scope <- ["", "*/p/production", " /x/production", "a//production", "w/x/y/z"] do
        resp =
          conn |> admin_conn() |> post("/v1/shares", %{scope: scope, surfaces: "papers"})

        assert resp.status == 422, "POST scope #{inspect(scope)} → #{resp.status}"

        gone = conn |> admin_conn() |> delete("/v1/shares", %{scope: scope})
        assert gone.status == 422, "DELETE scope #{inspect(scope)} → #{gone.status}"
      end

      # a non-binary scope is a denial too
      assert (conn |> admin_conn() |> post("/v1/shares", %{surfaces: "papers"})).status == 422
      assert (conn |> admin_conn() |> delete("/v1/shares", %{})).status == 422
    end
  end
end
