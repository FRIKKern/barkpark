defmodule BarkparkWeb.SearchSynonymsScopingTest do
  @moduledoc """
  Charter D85/D86 (Cloud-Build wave 2b, Door 2) — the FLAT documents search
  synonyms/insights admin routes must attribute the caller's OWN workspace, not
  collapse every caller into the seeded Default workspace.

  BEFORE the fix the documents flat block ran `pipe_through([:api, :require_admin])`:
  `:api` ends in `AssignDefaultScope` (stamps `current_workspace = Default`) with
  NO `DeriveWorkspaceFromToken`, and `require_admin` is a plain admin-permission
  gate mintable by a workspace-bound admin token — so such a token read and wrote
  DEFAULT's synonyms on any shared dataset slug. The fix repoints the block onto
  the bespoke `:flat_admin_api` pipeline, which runs
  `DeriveWorkspaceFromToken` (fail-SOFT) BEFORE `AssignDefaultScope`, so a
  workspace-bound admin token resolves ITS workspace while a nil-workspace token
  still falls through to Default/global (READs stay global-legacy by D59).

  MUTATION-PROOF (fail-before). Revert ONLY the pipe flip on the documents flat
  block (`pipe_through(:flat_admin_api)` → `pipe_through([:api,
  :require_admin])`) and the THREE ws-resolution assertions in
  "workspace-bound token resolves its OWN workspace" go RED: token_a's GET no
  longer includes its own "alpha", it DOES see Default's "default-only", and its
  POST stamps the Default workspace_id instead of ws_a.id. The over-block test
  ("nil-workspace / global-admin READ is never over-blocked") stays GREEN in both
  states — the repoint neither adds nor removes over-refusal. Restore → all green.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Search.Synonyms

  @ds "production"

  setup do
    # Default Workspace must exist so the pre-fix Default-collapse path is real.
    {default_ws, _project} = ensure_default_scope!()
    ws_a = create_workspace!()
    ws_b = create_workspace!()
    {:ok, default_ws: default_ws, ws_a: ws_a, ws_b: ws_b}
  end

  # A workspace-BOUND admin token — the ws.id 5th arg is load-bearing: nil binds
  # to Default (the nil-stays-green trap the mutation-proof depends on avoiding).
  defp bound_admin_token!(ws) do
    raw = "tok-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "scoping-admin", @ds, ["read", "write", "admin"], ws.id)
    raw
  end

  # A genuinely nil-workspace (legacy/global) admin token. `create_token` binds
  # an omitted workspace_id to Default, so mint straight through the changeset.
  defp nil_workspace_admin_token! do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, _} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "nil-ws-admin",
        dataset: @ds,
        permissions: ["read", "write", "admin"],
        workspace_id: nil
      })
      |> Repo.insert()

    raw
  end

  defp conn_for(raw) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  # Seed a synonym directly on the module (tenant-aware) so the row carries the
  # given workspace_id (nil = the legacy/global row).
  defp seed!(ws_id, from) do
    {:ok, _} = Synonyms.create("documents", @ds, %{"from" => from, "to" => "#{from}-to"}, ws_id)
    :ok
  end

  defp froms(result), do: Enum.map(result, & &1["from"])

  describe "workspace-bound token resolves its OWN workspace" do
    test "GET /synonyms returns its own rows, never Default's; POST stamps its ws.id",
         %{default_ws: default_ws, ws_a: ws_a} do
      seed!(ws_a.id, "alpha")
      seed!(default_ws.id, "default-only")

      raw = bound_admin_token!(ws_a)

      conn = get(conn_for(raw), "/v1/data/search/#{@ds}/synonyms")
      %{"result" => result} = json_response(conn, 200)
      got = froms(result)

      # RED before the fix: token_a collapsed to Default → saw "default-only",
      # not "alpha".
      assert "alpha" in got
      refute "default-only" in got

      # POST create stamps the caller's OWN workspace — RED before the fix
      # (stamped Default's id).
      post_conn =
        post(conn_for(raw), "/v1/data/search/#{@ds}/synonyms", %{
          "from" => "beta",
          "to" => "beta-to"
        })

      %{"result" => created} = json_response(post_conn, 200)
      row = Repo.get!(Barkpark.Search.Synonym, created["id"])
      assert row.workspace_id == ws_a.id
    end
  end

  describe "cross-tenant matrix is fail-closed" do
    test "ws-A never sees ws-B's synonyms (empty 200, never 403)", %{ws_a: ws_a, ws_b: ws_b} do
      seed!(ws_b.id, "bravo")

      raw = bound_admin_token!(ws_a)
      conn = get(conn_for(raw), "/v1/data/search/#{@ds}/synonyms")

      %{"result" => result} = json_response(conn, 200)
      assert result == []
    end

    test "ws-A DELETE of a ws-B row → 404 and the B row survives; own delete works",
         %{ws_a: ws_a, ws_b: ws_b} do
      seed!(ws_b.id, "bravo")
      seed!(ws_a.id, "alpha")

      raw = bound_admin_token!(ws_a)

      b_row = Repo.get_by!(Barkpark.Search.Synonym, workspace_id: ws_b.id, from_query: "bravo")
      del_b = delete(conn_for(raw), "/v1/data/search/#{@ds}/synonyms/#{b_row.id}")
      assert json_response(del_b, 404)
      # B row survived the cross-tenant delete attempt.
      assert Repo.get(Barkpark.Search.Synonym, b_row.id)

      a_row = Repo.get_by!(Barkpark.Search.Synonym, workspace_id: ws_a.id, from_query: "alpha")
      del_a = delete(conn_for(raw), "/v1/data/search/#{@ds}/synonyms/#{a_row.id}")
      assert %{"ok" => true} = json_response(del_a, 200)
      refute Repo.get(Barkpark.Search.Synonym, a_row.id)
    end
  end

  describe "nil-workspace / global-admin READ is never over-blocked (D59)" do
    test "GET /synonyms and GET /insights still 200, never 403" do
      seed!(nil, "global")

      raw = nil_workspace_admin_token!()

      syn = get(conn_for(raw), "/v1/data/search/#{@ds}/synonyms")
      %{"result" => result} = json_response(syn, 200)
      # The global (nil-workspace) row is visible on the fallthrough path.
      assert "global" in froms(result)

      ins = get(conn_for(raw), "/v1/data/search/#{@ds}/insights")
      assert %{"result" => _} = json_response(ins, 200)
    end
  end
end
