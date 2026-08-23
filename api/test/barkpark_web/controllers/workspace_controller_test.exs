defmodule BarkparkWeb.WorkspaceControllerTest do
  @moduledoc """
  Conn tests for the membership-scoped workspace/project LIST API
  (task barkpark-sj6z):

    * GET /api/workspaces returns ONLY the workspaces the bearer token is a
      member of — a workspace the token is NOT a member of is absent (the hard
      tenant boundary; mirrors the assert_no_cross_workspace_leak shape).
    * GET /api/workspaces/:slug/projects → 200 for a member, listing that
      workspace's projects; 404 for a non-member AND for an unknown slug (no
      existence leak).
    * Unauthenticated requests → 401 (the :require_token pipeline).
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.Archive

  setup do
    # create_token/4 with no explicit workspace_id binds to the seeded Default
    # Workspace AND inserts a membership — so this token is a member of
    # "default" only.
    raw = "ws-list-token-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "ws list", "test", ["read", "write"])

    # A SECOND workspace the caller IS additionally made a member of — proves
    # the list surfaces every membership, not just Default.
    {:ok, member_ws} = Tenancy.create_workspace(%{slug: "member-ws", name: "Member WS"})

    {:ok, member_proj} =
      Tenancy.create_project(member_ws, %{slug: "member-proj", name: "Member Proj"})

    {:ok, _m} = TenancyAuth.create_membership(member_ws.id, token.id, "member")

    # A THIRD workspace the caller is NOT a member of — the leak guard. Has its
    # own project so a leaked :projects response would be visibly wrong.
    {:ok, other_ws} = Tenancy.create_workspace(%{slug: "other-ws", name: "Other WS"})

    {:ok, _other_proj} =
      Tenancy.create_project(other_ws, %{slug: "other-proj", name: "Other Proj"})

    {:ok, raw_token: raw, member_ws: member_ws, member_proj: member_proj, other_ws: other_ws}
  end

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  describe "GET /api/workspaces" do
    test "returns ONLY the caller's member workspaces; a non-member workspace is absent", %{
      conn: conn,
      raw_token: raw,
      member_ws: member_ws,
      other_ws: other_ws
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces")

      assert resp.status == 200
      slugs = Jason.decode!(resp.resp_body)["workspaces"] |> Enum.map(& &1["slug"])

      # Member of: "default" (from create_token) + "member-ws".
      assert "default" in slugs
      assert member_ws.slug in slugs

      # CROSS-WORKSPACE LEAK GUARD: the workspace the caller is NOT a member of
      # must never appear — the hard tenant boundary.
      refute other_ws.slug in slugs
    end

    test "unauthenticated → 401", %{conn: conn} do
      resp = get(conn, "/api/workspaces")

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end
  end

  describe "GET /api/workspaces/:workspace_slug/projects" do
    test "200 for a member — lists that workspace's projects", %{
      conn: conn,
      raw_token: raw,
      member_ws: member_ws,
      member_proj: member_proj
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{member_ws.slug}/projects")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["workspace"]["slug"] == member_ws.slug

      project_slugs = body["projects"] |> Enum.map(& &1["slug"])
      assert member_proj.slug in project_slugs
    end

    # D13 Tier A: a REFUSAL is a refusal. This test asserted 404 before the
    # denial-shape change — it is the one that flips.
    test "403 for a real workspace the caller is NOT a member of (a refusal, not a lie)", %{
      conn: conn,
      raw_token: raw,
      other_ws: other_ws
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{other_ws.slug}/projects")

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
      # …and the refusal carries no interior detail about the workspace.
      refute Jason.decode!(resp.resp_body)["projects"]
    end

    test "404 for an unknown workspace slug", %{conn: conn, raw_token: raw} do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/no-such-ws/projects")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "unauthenticated → 401", %{conn: conn, member_ws: member_ws} do
      resp = get(conn, "/api/workspaces/#{member_ws.slug}/projects")

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end
  end

  describe "GET /api/workspaces/:workspace_slug/projects/:project_slug/datasets" do
    test "200 for a member — lists that project's datasets", %{
      conn: conn,
      raw_token: raw,
      member_ws: member_ws,
      member_proj: member_proj
    } do
      {:ok, dataset} = Tenancy.create_dataset(member_proj, %{slug: "prod-ds", name: "Prod DS"})

      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{member_ws.slug}/projects/#{member_proj.slug}/datasets")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["workspace"]["slug"] == member_ws.slug
      assert body["project"]["slug"] == member_proj.slug

      dataset_slugs = body["datasets"] |> Enum.map(& &1["slug"])
      assert dataset.slug in dataset_slugs
    end

    test "403 for a workspace the caller is NOT a member of (a refusal, not a lie)", %{
      conn: conn,
      raw_token: raw,
      other_ws: other_ws
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{other_ws.slug}/projects/other-proj/datasets")

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    test "404 for an unknown WORKSPACE slug (existence, not membership)", %{
      conn: conn,
      raw_token: raw
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/no-such-ws/projects/whatever/datasets")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    # TIER B, deliberately NOT widened: interior existence. The caller here is
    # already a member — it could list these project slugs — so 404 on an
    # unknown project confirms nothing, and 403 would be a lie in the other
    # direction ("you may not", when in fact there is nothing there).
    test "404 for an unknown PROJECT inside a workspace the caller IS a member of", %{
      conn: conn,
      raw_token: raw,
      member_ws: member_ws
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{member_ws.slug}/projects/no-such-proj/datasets")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "unauthenticated → 401", %{conn: conn, member_ws: member_ws, member_proj: member_proj} do
      resp = get(conn, "/api/workspaces/#{member_ws.slug}/projects/#{member_proj.slug}/datasets")

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end
  end

  describe "POST /api/workspaces" do
    test "201 — creates workspace, owner membership, Default project + production dataset",
         %{conn: conn, raw_token: raw} do
      slug = "fresh-ws-#{System.unique_integer([:positive])}"

      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces", %{"name" => "Fresh WS", "slug" => slug})

      assert resp.status == 201
      body = Jason.decode!(resp.resp_body)
      assert body["workspace"]["slug"] == slug
      assert body["workspace"]["name"] == "Fresh WS"

      ws = Tenancy.get_workspace_by_slug(slug)
      assert ws

      # Creator is an admin-tier (owner) member.
      membership = TenancyAuth.membership(body_token_id(raw), ws.id)
      assert membership
      assert membership.role == "owner"

      # Default project + production dataset bootstrapped + immediately usable.
      project = Tenancy.get_project(slug, "default")
      assert project
      assert project.name == "Default Project"
      assert Tenancy.get_dataset(project, "production")
    end

    test "201 — derives the slug from the name when slug omitted", %{conn: conn, raw_token: raw} do
      name = "My Cool Space #{System.unique_integer([:positive])}"

      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces", %{"name" => name})

      assert resp.status == 201
      slug = Jason.decode!(resp.resp_body)["workspace"]["slug"]
      assert slug =~ ~r/^[a-z0-9][a-z0-9-]*$/
      assert Tenancy.get_workspace_by_slug(slug)
    end

    test "422 — duplicate slug (clean conflict)", %{conn: conn, raw_token: raw} do
      slug = "dup-ws-#{System.unique_integer([:positive])}"

      assert conn
             |> authed(raw)
             |> post("/api/workspaces", %{"name" => "A", "slug" => slug})
             |> Map.get(:status) == 201

      resp = conn |> authed(raw) |> post("/api/workspaces", %{"name" => "B", "slug" => slug})

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "validation_failed"
    end

    test "422 — missing name", %{conn: conn, raw_token: raw} do
      resp = conn |> authed(raw) |> post("/api/workspaces", %{})

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "validation_failed"
    end

    test "unauthenticated → 401", %{conn: conn} do
      resp = post(conn, "/api/workspaces", %{"name" => "Nope"})

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end

    # M4 — the creator binding. Before this, POST /api/workspaces wrote exactly
    # one membership row, principal_type "api_token", and the HUMAN who made
    # the workspace was not a member of it: member?/2 false, workspace_admin?/2
    # false, list_workspaces_for/1 empty. gyldendal is in that state on prod.
    test "201 — an OWNED token also binds its human: BOTH an api_token and a user owner row",
         %{conn: conn} do
      user = owner_user("creator")
      {raw, _token} = owned_token(user)
      slug = "owned-ws-#{System.unique_integer([:positive])}"

      resp = conn |> authed(raw) |> post("/api/workspaces", %{"name" => "Owned", "slug" => slug})

      assert resp.status == 201
      ws = Tenancy.get_workspace_by_slug(slug)
      assert ws

      # The token row, exactly as before.
      token_membership = TenancyAuth.membership(body_token_id(raw), ws.id)
      assert token_membership.role == "owner"
      assert token_membership.principal_type == "api_token"

      # …and the human's own row, which is what was missing.
      user_membership = TenancyAuth.membership(user, ws.id)
      assert user_membership, "the creator's user-typed owner membership was not written"
      assert user_membership.role == "owner"
      assert user_membership.principal_type == "user"

      # The claim that actually matters to a human: they can reach it.
      assert TenancyAuth.member?(user, ws.id)
      assert TenancyAuth.workspace_admin?(user, ws.id)
      assert slug in (Tenancy.list_workspaces_for(user) |> Enum.map(& &1.slug))
    end

    test "201 — an UNOWNED (CI/bootstrap) token creates the workspace and writes NO user row",
         %{conn: conn, raw_token: raw} do
      slug = "unowned-ws-#{System.unique_integer([:positive])}"

      resp = conn |> authed(raw) |> post("/api/workspaces", %{"name" => "CI", "slug" => slug})

      assert resp.status == 201
      ws = Tenancy.get_workspace_by_slug(slug)
      assert TenancyAuth.membership(body_token_id(raw), ws.id).principal_type == "api_token"

      # CONDITIONAL, never unconditional: no NULL/placeholder membership row.
      user_rows =
        Repo.all(
          from(m in Barkpark.Tenancy.Membership,
            where: m.workspace_id == ^ws.id and m.principal_type == "user"
          )
        )

      assert user_rows == []
    end
  end

  describe "POST /api/workspaces/:workspace_slug/projects" do
    test "201 for a member — creates project + production dataset", %{
      conn: conn,
      raw_token: raw,
      member_ws: member_ws
    } do
      slug = "new-proj-#{System.unique_integer([:positive])}"

      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces/#{member_ws.slug}/projects", %{
          "name" => "New Proj",
          "slug" => slug
        })

      assert resp.status == 201
      assert Jason.decode!(resp.resp_body)["project"]["slug"] == slug

      project = Tenancy.get_project(member_ws.slug, slug)
      assert project
      assert Tenancy.get_dataset(project, "production")
    end

    test "403 for a NON-member workspace — and still writes nothing", %{
      conn: conn,
      raw_token: raw,
      other_ws: other_ws
    } do
      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces/#{other_ws.slug}/projects", %{"name" => "Sneaky"})

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
      # The guard that matters is unchanged by the denial SHAPE: no project was
      # created in the workspace we are not a member of.
      refute Tenancy.get_project(other_ws.slug, "sneaky")
    end

    test "404 for an unknown workspace slug", %{conn: conn, raw_token: raw} do
      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces/no-such-ws/projects", %{"name" => "X"})

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "422 for a duplicate project slug within the workspace", %{
      conn: conn,
      raw_token: raw,
      member_ws: member_ws
    } do
      slug = "dup-proj-#{System.unique_integer([:positive])}"

      assert conn
             |> authed(raw)
             |> post("/api/workspaces/#{member_ws.slug}/projects", %{
               "name" => "A",
               "slug" => slug
             })
             |> Map.get(:status) == 201

      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces/#{member_ws.slug}/projects", %{"name" => "B", "slug" => slug})

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "validation_failed"
    end

    test "unauthenticated → 401", %{conn: conn, member_ws: member_ws} do
      resp = post(conn, "/api/workspaces/#{member_ws.slug}/projects", %{"name" => "X"})

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end
  end

  describe "DELETE /api/workspaces/:workspace_slug" do
    test "200 for an admin — deletes the workspace and it is gone from the DB", %{conn: conn} do
      raw_admin = "ws-admin-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Throwaway WS"}, admin_token(raw_admin))

      assert Tenancy.get_workspace_by_slug(target.slug)

      resp =
        conn
        |> authed(raw_admin)
        |> delete("/api/workspaces/#{target.slug}")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["workspace"]["slug"] == target.slug
      assert body["deleted"] == true

      # The row is actually gone — no soft-delete, no lingering record.
      refute Tenancy.get_workspace_by_slug(target.slug)
    end

    test "403 for a NON-admin token (permission denial path)", %{conn: conn, raw_token: raw} do
      # `raw` (from setup) holds only ["read", "write"] — no global admin perm.
      {:ok, target} = Tenancy.create_workspace(%{slug: "keep-me-ws", name: "Keep Me"})

      resp =
        conn
        |> authed(raw)
        |> delete("/api/workspaces/#{target.slug}")

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"

      # The denial is REAL: the workspace survives an unauthorized delete attempt.
      assert Tenancy.get_workspace_by_slug(target.slug)
    end

    test "unauthenticated → 401", %{conn: conn} do
      {:ok, target} = Tenancy.create_workspace(%{slug: "anon-keep-ws", name: "Anon Keep"})

      resp = delete(conn, "/api/workspaces/#{target.slug}")

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
      assert Tenancy.get_workspace_by_slug(target.slug)
    end

    test "404 for an unknown workspace slug (admin)", %{conn: conn} do
      raw_admin = "ws-admin-404-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "ws admin", "test", ["admin"])

      resp =
        conn
        |> authed(raw_admin)
        |> delete("/api/workspaces/no-such-ws")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "ZERO-ORPHAN through the HTTP path — no workspace_id-scoped row survives the delete",
         %{conn: conn} do
      raw_admin = "ws-admin-orphan-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      # A throwaway workspace bootstrapped through the real owner path (owner
      # membership + Default project + production dataset) …
      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Orphan Sweep WS"}, admin_token(raw_admin))

      project = Tenancy.get_project(target.slug, "default")

      # … then given real scoped content so the sweep is NOT vacuously green.
      {:ok, _doc} = TenancyFixtures.create_document_in!(target, project, "post", %{}, "test")

      ws_id = target.id

      # Live-derive every table carrying a `workspace_id` column (the E1
      # column-scan the keystone paper names) — never a hardcoded list.
      scoped_tables = workspace_id_tables()
      assert scoped_tables != [], "expected at least one workspace_id-scoped table to sweep"

      # Sanity: BEFORE the delete, the workspace really does own scoped rows —
      # otherwise a zero-orphan assertion would prove nothing.
      before_total = total_scoped_rows(scoped_tables, ws_id)

      assert before_total > 0,
             "fixture seeded no workspace_id-scoped rows — sweep would be vacuous"

      resp =
        conn
        |> authed(raw_admin)
        |> delete("/api/workspaces/#{target.slug}")

      assert resp.status == 200

      # The scoped psql-style sweep through the HTTP path: EVERY workspace_id
      # table must hold zero rows for the deleted workspace.
      orphans =
        for table <- scoped_tables,
            cnt = scoped_row_count(table, ws_id),
            cnt > 0,
            do: {table, cnt}

      assert orphans == [],
             "zero-orphan violated — rows survived the HTTP delete: #{inspect(orphans)}"
    end

    # ── CROSS-TENANT CONFINEMENT (task-a5636ad31304b23a) ──────────────────
    # The arms above (200 own / 403 non-admin / 401 anonymous) ALL pass against
    # a workspace-blind gate, because the 200 arm's admin CREATED its own
    # target. The arm that was missing is the only one the defect could ever
    # fail: caller and target in DIFFERENT tenants.
    test "CROSS-TENANT: a ws-A admin cannot delete ws-B — B survives", %{conn: conn} do
      raw_a = "ws-xtenant-a-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_a, "ws A admin", "test", ["read", "write", "admin"])

      # A's OWN workspace — the caller is an `owner` here and nowhere else.
      {:ok, _own} = Tenancy.create_workspace_with_owner(%{name: "A Home WS"}, admin_token(raw_a))

      # B — a different tenant, owned by a different admin token.
      raw_b = "ws-xtenant-b-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_b, "ws B admin", "test", ["read", "write", "admin"])

      {:ok, victim} =
        Tenancy.create_workspace_with_owner(%{name: "B Victim WS"}, admin_token(raw_b))

      # FIXTURE HONESTY: the caller holds NO membership row in B at all, so this
      # is a genuine cross-tenant request and not a same-workspace vacuity.
      refute TenancyAuth.member?(admin_token(raw_a), victim.id)

      resp =
        conn
        |> authed(raw_a)
        |> delete("/api/workspaces/#{victim.slug}")

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"

      # STATE, not the status code: B is still there.
      assert Tenancy.get_workspace_by_slug(victim.slug)
    end

    # PREDICATE STRENGTH. `member?/2` is existence-only, so it would ADMIT this
    # caller. Deleting a whole workspace — irreversible, cascading to media
    # blobs and a CDN purge — is a scoped-ADMIN act, so the shipped predicate is
    # `workspace_admin?/2`: the same one #12701 landed on `/v1/shares` and the
    # same one `RequireWorkspaceRole` enforces. This arm is what pins that
    # choice — it reds the moment the gate is weakened to bare membership.
    test "CROSS-TENANT predicate strength: a global admin holding a plain `member` row in B cannot delete B",
         %{conn: conn} do
      raw_a = "ws-xtenant-mem-a-#{System.unique_integer([:positive])}"
      {:ok, token_a} = Auth.create_token(raw_a, "ws A admin", "test", ["read", "write", "admin"])

      raw_b = "ws-xtenant-mem-b-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_b, "ws B admin", "test", ["read", "write", "admin"])

      {:ok, victim} =
        Tenancy.create_workspace_with_owner(%{name: "B Member-Only WS"}, admin_token(raw_b))

      # A is granted the LOWEST membership role in B.
      {:ok, _m} = TenancyAuth.create_membership(victim.id, token_a.id, "member")

      assert TenancyAuth.member?(admin_token(raw_a), victim.id)
      refute TenancyAuth.workspace_admin?(admin_token(raw_a), victim.id)

      resp =
        conn
        |> authed(raw_a)
        |> delete("/api/workspaces/#{victim.slug}")

      assert resp.status == 403
      assert Tenancy.get_workspace_by_slug(victim.slug)
    end
  end

  describe "GET /api/workspaces/:workspace_slug/export" do
    test "200 for an admin — application/x-tar attachment with a non-empty bundle body",
         %{conn: conn} do
      raw_admin = "ws-export-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Export WS"}, admin_token(raw_admin))

      resp =
        conn
        |> authed(raw_admin)
        |> get("/api/workspaces/#{target.slug}/export")

      assert resp.status == 200

      # Binary tar carrier — NO charset (put_resp_content_type/3 nil charset).
      assert Plug.Conn.get_resp_header(resp, "content-type") == ["application/x-tar"]

      assert Plug.Conn.get_resp_header(resp, "content-disposition") ==
               ["attachment; filename=#{target.slug}.tar"]

      # The body is the real materialized bundle, not an empty 200.
      assert byte_size(resp.resp_body) > 0

      # …and it is a genuine bp-export-v1 bundle FOR THIS workspace — unpack the
      # manifest straight off the response bytes (no DB write, so no dirty-target
      # re-import conflict; the round-trip proof lives in the import test below).
      {manifest, _dumps} = Archive.unpack(resp.resp_body)
      assert manifest["format"] == Archive.format()
      assert manifest["workspace_slug"] == target.slug
    end

    test "the profile / dataset / source_server query params REACH the engine (they were silently discarded before)",
         %{conn: conn} do
      raw_admin = "ws-export-scoped-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Scoped Export WS"}, admin_token(raw_admin))

      resp =
        conn
        |> authed(raw_admin)
        |> get("/api/workspaces/#{target.slug}/export?profile=dev&source_server=https://x.test")

      assert resp.status == 200
      {manifest, _dumps} = Archive.unpack(resp.resp_body)

      # The whole point: on the pre-slice controller these are absent because the
      # action matched only workspace_slug and called export/1.
      assert manifest["profile"] == "dev"
      assert manifest["source_server"] == "https://x.test"
      assert manifest["format"] == Archive.format()

      # Content type is set UNCONDITIONALLY — there is no Accept negotiation here.
      assert Plug.Conn.get_resp_header(resp, "content-type") == ["application/x-tar"]

      assert Plug.Conn.get_resp_header(resp, "content-disposition") ==
               ["attachment; filename=#{target.slug}-dev.tar"]
    end

    test "422 with an honest reason when a scope option cannot be resolved — never a 500, never a silently wrong bundle",
         %{conn: conn} do
      raw_admin = "ws-export-422-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Refusing Export WS"}, admin_token(raw_admin))

      for {query, reason} <- [
            {"profile=staging", "invalid_profile"},
            {"dataset=no-such-dataset", "dataset_not_found"}
          ] do
        resp =
          conn
          |> authed(raw_admin)
          |> get("/api/workspaces/#{target.slug}/export?#{query}")

        assert resp.status == 422
        body = Jason.decode!(resp.resp_body)
        assert body["error"]["code"] == "unprocessable"
        assert body["error"]["reason"] == reason
        assert body["error"]["message"] != ""
      end
    end

    test "503 export_failed with a retry hint when the COPY dies of a transport failure — never a bare 500 internal_error",
         %{conn: conn} do
      raw_admin = "ws-export-503-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Dying Export WS"}, admin_token(raw_admin))

      # The exact exception the live 500 carried, raised from the exact function
      # it was raised in (run_copy_out/1), through the real route. A genuine
      # pool timeout cannot be used here: under the SQL sandbox it arrives as an
      # ownership-shutdown EXIT, not a rescuable raise.
      Application.put_env(:barkpark, :export_copy_fault, "tcp recv: closed")
      on_exit(fn -> Application.delete_env(:barkpark, :export_copy_fault) end)

      resp =
        conn
        |> authed(raw_admin)
        |> get("/api/workspaces/#{target.slug}/export")

      assert resp.status == 503
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "export_failed"
      assert body["error"]["reason"] == "database_unavailable"
      assert body["error"]["message"] != ""
      assert body["error"]["hint"] =~ "Retry"
    end

    test "404 for an unknown workspace slug (admin)", %{conn: conn} do
      raw_admin = "ws-export-404-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "ws admin", "test", ["admin"])

      resp =
        conn
        |> authed(raw_admin)
        |> get("/api/workspaces/no-such-ws/export")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "403 for a NON-admin token (permission denial before the action)",
         %{conn: conn, raw_token: raw, member_ws: member_ws} do
      # `raw` holds only ["read", "write"] — the :require_admin gate 403s it
      # BEFORE export/2 runs, so no bundle is ever materialized.
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{member_ws.slug}/export")

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    test "unauthenticated → 401", %{conn: conn, member_ws: member_ws} do
      resp = get(conn, "/api/workspaces/#{member_ws.slug}/export")

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end

    # ── CROSS-TENANT CONFINEMENT (task-f416f96ef0860f47) ──────────────────
    # Same omission as the DELETE block above: every existing arm's admin
    # created its own target, so none of them crosses a tenant boundary. This
    # one does — and it asserts on the BYTES, not on the status code, because a
    # status cannot tell you whether the bundle leaked.
    test "CROSS-TENANT: a ws-A admin cannot export ws-B — and not one byte of B reaches the wire",
         %{conn: conn} do
      raw_a = "ws-xexport-a-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_a, "ws A admin", "test", ["read", "write", "admin"])

      {:ok, _own} =
        Tenancy.create_workspace_with_owner(%{name: "A Home Export WS"}, admin_token(raw_a))

      raw_b = "ws-xexport-b-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_b, "ws B admin", "test", ["read", "write", "admin"])

      sentinel = "B Secret Export WS #{System.unique_integer([:positive])}"
      {:ok, victim} = Tenancy.create_workspace_with_owner(%{name: sentinel}, admin_token(raw_b))

      refute TenancyAuth.member?(admin_token(raw_a), victim.id)

      # THE ORACLE IS NOT VACUOUS: B's own admin exports B and the sentinel IS
      # in the tar. So the `refute` below is a real absence, not a string that
      # never appears in a bundle in the first place.
      allowed = conn |> authed(raw_b) |> get("/api/workspaces/#{victim.slug}/export")
      assert allowed.status == 200
      assert allowed.resp_body =~ sentinel

      denied = conn |> authed(raw_a) |> get("/api/workspaces/#{victim.slug}/export")

      assert denied.status == 403
      assert Jason.decode!(denied.resp_body)["error"]["code"] == "forbidden"

      # No attachment, and — the thing that actually matters — none of B's
      # bundle. There is no undo for a read.
      assert Plug.Conn.get_resp_header(denied, "content-disposition") == []
      refute denied.resp_body =~ sentinel
    end

    # PREDICATE STRENGTH, and it bites harder here than on delete: a FULL
    # profile bundle is the whole workspace, including the secret / credential /
    # PII classes that `profile=dev` exists to scrub. A plain `member` must not
    # be able to walk out with it, so the gate is `workspace_admin?/2`.
    test "CROSS-TENANT predicate strength: a global admin holding a plain `member` row in B cannot export B",
         %{conn: conn} do
      raw_a = "ws-xexport-mem-a-#{System.unique_integer([:positive])}"
      {:ok, token_a} = Auth.create_token(raw_a, "ws A admin", "test", ["read", "write", "admin"])

      raw_b = "ws-xexport-mem-b-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_b, "ws B admin", "test", ["read", "write", "admin"])

      sentinel = "B Member-Only Export WS #{System.unique_integer([:positive])}"
      {:ok, victim} = Tenancy.create_workspace_with_owner(%{name: sentinel}, admin_token(raw_b))

      {:ok, _m} = TenancyAuth.create_membership(victim.id, token_a.id, "member")

      assert TenancyAuth.member?(admin_token(raw_a), victim.id)
      refute TenancyAuth.workspace_admin?(admin_token(raw_a), victim.id)

      denied = conn |> authed(raw_a) |> get("/api/workspaces/#{victim.slug}/export")

      assert denied.status == 403
      refute denied.resp_body =~ sentinel
    end

    # OPERATOR REMEDY (task-382829df2d7bf491). The binding above narrowed this
    # route to `workspace_admin?/2`, and the three production consumers of it —
    # `bp cloud workspace export` (internal/cli/cloud_workspace_cmd.go:165), the
    # support pull (internal/cli/cloud_support_cmd.go:1736) and the provisioner
    # (internal/provisioner/support.go:730) — all present an admin-permissioned
    # operator token against a workspace they did NOT necessarily create. When
    # that token holds no membership, the sanctioned remedy is an explicit
    # `admin` GRANT, never weakening the predicate (that reopens the
    # cross-tenant hole task-a5636ad31304b23a / task-f416f96ef0860f47 closed).
    #
    # THE GAP THIS FILLS: `@admin_roles` is ~w(owner admin), but every ALLOW arm
    # on this route draws its authority from `create_workspace_with_owner` →
    # role "owner", and every DENY arm uses "member" or no row at all. So the
    # `admin` half of that constant is UNEXERCISED here. Narrow `@admin_roles`
    # to ~w(owner) and the whole file still passes — while the documented
    # operator remedy silently stops working in production. This arm is the
    # tripwire for exactly that reversal.
    #
    # NOT VACUOUS BY CONSTRUCTION: the same token is asserted DENIED before the
    # grant and ALLOWED after it, so the grant is provably what flipped the
    # outcome — a 200 here cannot come from an accidental global bypass.
    test "OPERATOR REMEDY: an explicitly granted `admin` membership — not ownership — restores export of a workspace the operator did not create",
         %{conn: conn} do
      raw_op = "ws-export-op-#{System.unique_integer([:positive])}"

      {:ok, token_op} =
        Auth.create_token(raw_op, "operator", "test", ["read", "write", "admin"])

      # The target is created by a DIFFERENT principal — the production shape
      # the provisioner/support chain actually faces (a workspace that arrived
      # by seeds, a migration, an import, or another operator). The operator
      # token is therefore NOT its owner.
      raw_owner = "ws-export-op-owner-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_owner, "ws owner", "test", ["read", "write", "admin"])

      sentinel = "Operator Grant Export WS #{System.unique_integer([:positive])}"

      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: sentinel}, admin_token(raw_owner))

      # BEFORE: admin PERMISSIONS but no membership row → denied. This is the
      # negative control that makes the assertion after the grant meaningful.
      refute TenancyAuth.member?(admin_token(raw_op), target.id)
      before = conn |> authed(raw_op) |> get("/api/workspaces/#{target.slug}/export")
      assert before.status == 403
      refute before.resp_body =~ sentinel

      # THE REMEDY: an explicit `admin` grant — the authority is a recorded
      # grant, not a global bit. Deliberately NOT "owner": this is the half of
      # @admin_roles nothing else on this route covers.
      {:ok, membership} = TenancyAuth.create_membership(target.id, token_op.id, "admin")
      assert membership.role == "admin"
      assert TenancyAuth.workspace_admin?(admin_token(raw_op), target.id)

      # AFTER: the identical token now exports, and the bundle really is this
      # workspace's — asserted on the BYTES, not just the status code.
      allowed = conn |> authed(raw_op) |> get("/api/workspaces/#{target.slug}/export")
      assert allowed.status == 200
      assert allowed.resp_body =~ sentinel
    end
  end

  describe "POST /api/workspaces/:workspace_slug/import" do
    test "200 for an admin — imports a bundle into a clean scope and returns {tables,total_rows}",
         %{conn: conn} do
      raw_admin = "ws-import-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      # Seed a real workspace with scoped content so the round-trip is NOT vacuous.
      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Import RT WS"}, admin_token(raw_admin))

      project = Tenancy.get_project(target.slug, "default")
      {:ok, _doc} = TenancyFixtures.create_document_in!(target, project, "post", %{}, "test")

      {:ok, bundle} = WorkspaceBundle.export(target.id)
      ws_slug = target.slug

      # CLEAN TARGET: delete the workspace (cascades every FK-scoped row) then clear
      # the two FK-less audit tables so the copy-strategy members re-import without
      # a primary-key collision (the copy path assumes a clean target; only the
      # E3/allowlist members are ON CONFLICT idempotent). audit_events is
      # append-only, so the purge runs under `session_replication_role = replica`
      # (triggers off) — the same clean-target trick the engine round-trip uses.
      {:ok, _} = Tenancy.delete_workspace(target)
      {:ok, ws_bin} = Ecto.UUID.dump(target.id)
      purge_fkless_audit!(ws_bin)
      refute Tenancy.get_workspace_by_slug(ws_slug)

      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{ws_slug}/import", bundle)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert is_map(body["tables"])
      assert body["total_rows"] > 0

      # The import REALLY landed through the HTTP path: the workspace + its scoped
      # document are back — not a vacuous 200.
      assert Tenancy.get_workspace_by_slug(ws_slug)

      assert scoped_row_count("documents", target.id) > 0
    end

    # pds-bl-clean-import-ungated-500: `clean` is the DEFAULT mode and is
    # deliberately ungated (ruling in the controller @doc), so the populated-
    # target collision is reachable by any admin who simply forgets `--merge`.
    # Live, that used to die as `internal_error` 500 whose real cause (a 25P02
    # masking the PK conflict) only the server log knew. This pins the honest
    # refusal: a typed 409 naming the pg error class + constraint + table, and
    # a fully rolled-back target.
    test "CLEAN into a still-populated workspace answers a typed 409 naming the constraint — " <>
           "never a bare internal_error 500 (pds-bl-clean-import-ungated-500)",
         %{conn: conn} do
      raw_admin = "ws-clean-collide-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Clean Collide WS"}, admin_token(raw_admin))

      project = Tenancy.get_project(target.slug, "default")
      {:ok, _doc} = TenancyFixtures.create_document_in!(target, project, "post", %{}, "test")

      {:ok, bundle} = WorkspaceBundle.export(target.id)
      docs_before = scoped_row_count("documents", target.id)

      # NO cleanup: the workspace is still populated, so the copy-strategy
      # members must PK-collide (the root `workspaces` row re-imports under
      # its own still-resident id).
      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{target.slug}/import", bundle)

      assert resp.status == 409

      err = Jason.decode!(resp.resp_body)["error"]
      assert err["code"] == "import_constraint_violation"
      assert err["details"]["pg_code"] == "unique_violation"

      # The envelope NAMES the cause — a caller can see what collided without
      # the server journal.
      assert is_binary(err["details"]["constraint"])
      assert is_binary(err["details"]["table"])

      # Atomic refusal: the target is byte-for-byte the workspace it was —
      # nothing landed, nothing was lost.
      assert Tenancy.get_workspace_by_slug(target.slug).name == "Clean Collide WS"
      assert scoped_row_count("documents", target.id) == docs_before
    end

    test "403 for a NON-admin token (permission denial before the action)",
         %{conn: conn, raw_token: raw, member_ws: member_ws} do
      resp =
        conn
        |> authed(raw)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{member_ws.slug}/import", "ignored")

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    # ── the bounded body (PDS wave 23, pds-bl-bounded-import-unpack) ───────────
    #
    # The ceiling that ships is DERIVED (2x the measured 2,605.5 MiB bundle =
    # 5,464,203,264 B). No test posts 5.46 GB, so the refusal is exercised
    # through the `:max_import_body_bytes` override — the mechanism, not the
    # number, is what these prove.
    test "413 import_body_too_large refuses an over-ceiling body in CLEAN mode — the mode " <>
           "that had NO gate at all",
         %{conn: conn} do
      raw_admin = "ws-import-413-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      Application.put_env(:barkpark, :max_import_body_bytes, 1_024)

      try do
        resp =
          conn
          |> authed(raw_admin)
          |> put_req_header("content-type", "application/x-tar")
          |> post("/api/workspaces/whatever/import", String.duplicate("x", 4_096))

        assert resp.status == 413
        body = Jason.decode!(resp.resp_body)
        assert body["error"]["code"] == "import_body_too_large"
        # The limit is NAMED, not merely enforced.
        assert body["error"]["details"]["limit_bytes"] == 1_024
        assert body["error"]["message"] =~ "1024-byte ceiling"
        assert body["error"]["message"] =~ "2,605.5 MiB"
      after
        Application.delete_env(:barkpark, :max_import_body_bytes)
      end
    end

    test "the ceiling can be exercised BOTH ways: the same body under a high ceiling is " <>
           "NOT refused (the 413 is not a constant)",
         %{conn: conn} do
      raw_admin = "ws-import-413b-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      # Same 4 KB body, ceiling above it: it gets past the gate and dies on the
      # engine's honest invalid_bundle instead (4 KB of "x" is not a tar).
      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/whatever/import", String.duplicate("x", 4_096))

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "invalid_bundle"
    end

    test "413 also gates mode=merge", %{conn: conn} do
      raw_admin = "ws-import-413m-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      Application.put_env(:barkpark, :allow_bundle_import, true)
      Application.put_env(:barkpark, :max_import_body_bytes, 1_024)

      try do
        resp =
          conn
          |> authed(raw_admin)
          |> put_req_header("content-type", "application/x-tar")
          |> post("/api/workspaces/whatever/import?mode=merge", String.duplicate("x", 4_096))

        assert resp.status == 413
        assert Jason.decode!(resp.resp_body)["error"]["code"] == "import_body_too_large"
      after
        Application.delete_env(:barkpark, :max_import_body_bytes)
        Application.delete_env(:barkpark, :allow_bundle_import)
      end
    end

    test "the success receipt says whether the disk precondition actually RAN", %{conn: conn} do
      raw_admin = "ws-import-disk-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Disk RX WS"}, admin_token(raw_admin))

      project = Tenancy.get_project(target.slug, "default")
      {:ok, _doc} = TenancyFixtures.create_document_in!(target, project, "post", %{}, "test")

      {:ok, bundle} = WorkspaceBundle.export(target.id)
      ws_slug = target.slug

      {:ok, _} = Tenancy.delete_workspace(target)
      {:ok, ws_bin} = Ecto.UUID.dump(target.id)
      purge_fkless_audit!(ws_bin)

      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{ws_slug}/import", bundle)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert body["body_bytes"] == byte_size(bundle),
             "the receipt must report the bytes actually spilled"

      # Checked or not, it SAYS which — never a checkmark for a check that did
      # not run. Plug.Test sets content-length, so on a normal box this is a
      # real, performed check carrying the free-space number it measured.
      assert is_map(body["disk_precondition"])
      assert is_boolean(body["disk_precondition"]["checked"])

      if body["disk_precondition"]["checked"] do
        assert body["disk_precondition"]["free_bytes"] > 0
      else
        assert is_binary(body["disk_precondition"]["reason"])
      end
    end

    test "unauthenticated → 401", %{conn: conn, member_ws: member_ws} do
      resp =
        conn
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{member_ws.slug}/import", "ignored")

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end
  end

  describe "POST /api/workspaces/:workspace_slug/import?mode=merge (PDS-D10 fail-closed guard)" do
    test "REFUSED 403 bundle_import_disabled while :allow_bundle_import is unset (fail-closed default)",
         %{conn: conn, member_ws: member_ws} do
      # Stand-alone: the env plumb ships in a disjoint slice — make the absent
      # (default-false) polarity explicit regardless of ambient test config.
      Application.delete_env(:barkpark, :allow_bundle_import)

      raw_admin = "ws-merge-off-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{member_ws.slug}/import?mode=merge", "never-imported")

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "bundle_import_disabled"
    end

    test "explicit false refuses identically (the guard reads the value, not mere presence)",
         %{conn: conn, member_ws: member_ws} do
      Application.put_env(:barkpark, :allow_bundle_import, false)
      on_exit(fn -> Application.delete_env(:barkpark, :allow_bundle_import) end)

      raw_admin = "ws-merge-false-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{member_ws.slug}/import?mode=merge", "never-imported")

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "bundle_import_disabled"
    end

    test "ALLOWED when :allow_bundle_import is true — merge converges a drifted, still-populated workspace over HTTP",
         %{conn: conn} do
      Application.put_env(:barkpark, :allow_bundle_import, true)
      on_exit(fn -> Application.delete_env(:barkpark, :allow_bundle_import) end)

      raw_admin = "ws-merge-on-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Merge RT WS"}, admin_token(raw_admin))

      project = Tenancy.get_project(target.slug, "default")
      {:ok, _doc} = TenancyFixtures.create_document_in!(target, project, "post", %{}, "test")

      {:ok, bundle} = WorkspaceBundle.export(target.id)

      # Drift the STILL-POPULATED workspace — the clean path would PK-crash here;
      # merge must converge it back without any pre-purge.
      Repo.query!("UPDATE workspaces SET name = 'HTTP-DRIFT' WHERE slug = $1", [target.slug])

      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{target.slug}/import?mode=merge", bundle)

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["mode"] == "merge"
      assert is_map(body["tables"])
      assert body["total_rows"] > 0

      # The drift is converged back through the HTTP path — not a vacuous 200.
      assert Tenancy.get_workspace_by_slug(target.slug).name == "Merge RT WS"
      assert scoped_row_count("documents", target.id) > 0
    end

    test "409 import_constraint_violation names the constraint on a non-arbiter unique collision — never a blind 500 (task-63a199c0a0ce2a06)",
         %{conn: conn} do
      Application.put_env(:barkpark, :allow_bundle_import, true)
      on_exit(fn -> Application.delete_env(:barkpark, :allow_bundle_import) end)

      raw_admin = "ws-merge-conflict-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      # SOURCE workspace carrying a NULL-dataset_id schema row — the slot the
      # partial unique index (name, dataset) WHERE dataset_id IS NULL guards.
      {:ok, source} =
        Tenancy.create_workspace_with_owner(%{name: "Conflict Src WS"}, admin_token(raw_admin))

      clash = "clash#{System.unique_integer([:positive])}"
      insert_null_dsid_schema!(source.id, clash)

      {:ok, bundle} = WorkspaceBundle.export(source.id)

      # The source leaves (a different box); a SIBLING workspace on the target
      # holds a different-id row in the SAME (name, dataset) NULL slot. The
      # merge arbiter is the primary key only, so the bundle row must collide
      # on the partial index — the exact raise class that used to escape as an
      # opaque internal_error 500 (bp exit 8, body never captured).
      {:ok, _} = Tenancy.delete_workspace(source)
      {:ok, ws_bin} = Ecto.UUID.dump(source.id)
      purge_fkless_audit!(ws_bin)

      {:ok, sibling} =
        Tenancy.create_workspace_with_owner(%{name: "Conflict Sib WS"}, admin_token(raw_admin))

      insert_null_dsid_schema!(sibling.id, clash)

      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{source.slug}/import?mode=merge", bundle)

      assert resp.status == 409
      err = Jason.decode!(resp.resp_body)["error"]
      assert err["code"] == "import_constraint_violation"
      assert err["details"]["pg_code"] == "unique_violation"

      assert err["details"]["constraint"] ==
               "schema_definitions_name_dataset_null_dataset_id_index"

      # The whole import rolled back: the source workspace did NOT land, and the
      # sibling's resident row is untouched.
      refute Tenancy.get_workspace_by_slug(source.slug)

      assert Repo.query!(
               "SELECT count(*) FROM schema_definitions WHERE workspace_id = $1::text::uuid AND name = $2",
               [sibling.id, clash]
             ).rows == [[1]]
    end

    # pds-bl-import-409-http-test: the PDS-D9 same-slug/different-id root
    # collision was pinned ONLY at the engine layer
    # (workspace_bundle_test.exs "same slug + different id + NON-empty
    # workspace"); the HTTP edge — status, code, and all three details keys —
    # was unpinned, so a merge_import/3 refactor could silently change the
    # error contract.
    test "409 workspace_slug_conflict pins the FULL wire shape on a same-slug/different-id " <>
           "root collision (PDS-D9, pds-bl-import-409-http-test)",
         %{conn: conn} do
      Application.put_env(:barkpark, :allow_bundle_import, true)
      on_exit(fn -> Application.delete_env(:barkpark, :allow_bundle_import) end)

      raw_admin = "ws-slug-conflict-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      # SOURCE workspace, exported, then deleted — its slug becomes vacant.
      {:ok, source} =
        Tenancy.create_workspace_with_owner(%{name: "Slug Conflict Src"}, admin_token(raw_admin))

      {:ok, bundle} = WorkspaceBundle.export(source.id)
      {:ok, _} = Tenancy.delete_workspace(source)
      {:ok, ws_bin} = Ecto.UUID.dump(source.id)
      purge_fkless_audit!(ws_bin)

      # A POPULATED squatter re-takes the SAME slug under a DIFFERENT id —
      # one document makes it not-an-empty-shell, so the D9 pre-flight must
      # REFUSE rather than adopt.
      {:ok, squatter} =
        Tenancy.create_workspace(%{slug: source.slug, name: "Slug Squatter WS"})

      {:ok, sq_proj} =
        Tenancy.create_project(squatter, %{slug: "sq-proj", name: "Sq Proj"})

      {:ok, _doc} = TenancyFixtures.create_document_in!(squatter, sq_proj, "post", %{}, "test")

      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{source.slug}/import?mode=merge", bundle)

      # The FULL wire shape: status, code, and every details key.
      assert resp.status == 409
      err = Jason.decode!(resp.resp_body)["error"]
      assert err["code"] == "workspace_slug_conflict"
      assert err["message"] =~ "not an empty shell"
      assert err["details"]["slug"] == source.slug
      assert err["details"]["existing_id"] == squatter.id
      assert err["details"]["bundle_id"] == source.id

      # Fail-closed both ways: the squatter and its document survive, and the
      # bundle workspace did NOT land.
      assert Tenancy.get_workspace_by_slug(source.slug).id == squatter.id
      assert scoped_row_count("documents", squatter.id) == 1

      refute Repo.query!(
               "SELECT count(*) FROM workspaces WHERE id = $1::text::uuid",
               [source.id]
             ).rows == [[1]]
    end

    test "unmatched engine {:error, term} → NAMED, LOGGED 500 import_failed — never the silent internal_error (task-96d8ab2b582818a4)",
         %{conn: conn} do
      # The round-3 live fire: 500 internal_error, zero log lines — an
      # `{:error, term}` no controller clause matched fell through to the
      # FallbackController's unlogged catch-all (Ecto's Repo.transaction can
      # legitimately return {:error, :rollback} on a nested-rollback commit
      # downgrade). The :import_fault seam forces exactly that term through the
      # REAL unpack + HTTP path; the wire must answer a named import_failed
      # carrying the term, and the log must name it BEFORE the response.
      Application.put_env(:barkpark, :allow_bundle_import, true)
      Application.put_env(:barkpark, :import_fault, {:error, :rollback})

      on_exit(fn ->
        Application.delete_env(:barkpark, :allow_bundle_import)
        Application.delete_env(:barkpark, :import_fault)
      end)

      raw_admin = "ws-merge-fault-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      {:ok, target} =
        Tenancy.create_workspace_with_owner(%{name: "Fault RT WS"}, admin_token(raw_admin))

      {:ok, bundle} = WorkspaceBundle.export(target.id)

      {resp, log} =
        ExUnit.CaptureLog.with_log(fn ->
          conn
          |> authed(raw_admin)
          |> put_req_header("content-type", "application/x-tar")
          |> post("/api/workspaces/#{target.slug}/import?mode=merge", bundle)
        end)

      assert resp.status == 500
      err = Jason.decode!(resp.resp_body)["error"]
      assert err["code"] == "import_failed"
      assert err["message"] =~ ":rollback"
      # request_id stamped by the shared emitter — the operator can grep for it.
      assert is_binary(err["request_id"])

      # NEVER SILENT: the term is logged at error level before the response.
      assert log =~ "unhandled error"
      assert log =~ ":rollback"
    end

    test "unknown mode → 422 invalid_mode (never silently treated as clean)",
         %{conn: conn, member_ws: member_ws} do
      raw_admin = "ws-merge-bad-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_admin, "ws admin", "test", ["read", "write", "admin"])

      resp =
        conn
        |> authed(raw_admin)
        |> put_req_header("content-type", "application/x-tar")
        |> post("/api/workspaces/#{member_ws.slug}/import?mode=sideways", "never-imported")

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "invalid_mode"
    end
  end

  # A schema row in the NULL-dataset_id slot (the flat-deployment shape the
  # partial unique index `(name, dataset) WHERE dataset_id IS NULL` guards) —
  # inserted directly so the write path cannot helpfully stamp a dataset_id.
  defp insert_null_dsid_schema!(ws_id, name) do
    Repo.query!(
      "INSERT INTO schema_definitions (id, name, title, dataset, workspace_id, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1, $1, 'test', $2::text::uuid, now(), now())",
      [name, ws_id]
    )
  end

  # Clear the two FK-less audit tables for a workspace so a bundle re-import into
  # the same DB has a clean copy-strategy target. audit_events enforces
  # append-only via a trigger, so the DELETE runs under
  # `session_replication_role = replica` (triggers off) and is reset to DEFAULT
  # after — mirroring the engine round-trip's clean-target purge.
  defp purge_fkless_audit!(ws_bin) do
    Repo.query!("SET session_replication_role = replica", [])

    try do
      Repo.query!("DELETE FROM audit_events WHERE workspace_id = $1", [ws_bin])
      Repo.query!("DELETE FROM audit_export_sinks WHERE workspace_id = $1", [ws_bin])
    after
      Repo.query!("SET session_replication_role = DEFAULT", [])
    end
  end

  # Resolve the api_token id for the raw bearer used in setup, so membership
  # assertions don't depend on the controller echoing the token.
  defp body_token_id(raw) do
    {:ok, token} = Auth.verify_token(raw)
    token.id
  end

  # A registered human, and a bearer token that NAMES them as its owner —
  # the `api_tokens.owner_user_id` seam `Plugs.ResolveTokenOwner` reads.
  defp owner_user(prefix) do
    {:ok, u} =
      Barkpark.Accounts.register_user(%{
        email: "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery"
      })

    u
  end

  defp owned_token(user) do
    raw = "owned-token-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "owned", "test", ["read", "write"])

    {:ok, token} =
      token |> Ecto.Changeset.change(%{owner_user_id: user.id}) |> Repo.update()

    {raw, token}
  end

  # The verified %ApiToken{} struct behind a raw bearer — the shape
  # `create_workspace_with_owner/2` binds the owner membership to.
  defp admin_token(raw) do
    {:ok, token} = Auth.verify_token(raw)
    token
  end

  # The two FK-less audit tables (charter D4/D15): they carry a workspace_id
  # column but NO foreign key, so `delete_workspace`'s cascade cannot reach
  # them. Sweeping them inside delete_workspace is the SEPARATE, file-disjoint
  # slice `bl-audit-fk-orphans` — NOT this route slice. This slice proves the
  # FK-cascade zero-orphan through the HTTP path; those two stay excluded here
  # so the two slices don't overlap. (E3 string-keyed tables are deferred to
  # bpb-delete-e3-string-keyed-sweep and carry no workspace_id column at all,
  # so they never enter this scan.)
  @fk_less_audit_tables ~w(audit_events audit_export_sinks)

  # Live-derived E1 enumeration: every public base table with a workspace_id
  # column, MINUS the FK-less audit tables above. Sourced from
  # information_schema so a new FK-scoped tenant table is swept automatically —
  # never a hardcoded list.
  defp workspace_id_tables do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.columns " <>
          "WHERE column_name = 'workspace_id' AND table_schema = 'public' " <>
          "ORDER BY table_name"
      )

    rows
    |> Enum.map(fn [t] -> t end)
    |> Enum.reject(&(&1 in @fk_less_audit_tables))
  end

  defp scoped_row_count(table, ws_id) do
    # Dump the uuid to its 16-byte binary so Postgrex encodes it as a uuid
    # param (a `$1::uuid` cast on a string param raises an EncodeError).
    {:ok, ws_bin} = Ecto.UUID.dump(ws_id)

    %{rows: [[cnt]]} =
      Repo.query!("SELECT count(*) FROM #{table} WHERE workspace_id = $1", [ws_bin])

    cnt
  end

  defp total_scoped_rows(tables, ws_id) do
    Enum.reduce(tables, 0, fn table, acc -> acc + scoped_row_count(table, ws_id) end)
  end
end
