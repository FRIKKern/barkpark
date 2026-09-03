defmodule BarkparkWeb.MediaSynonymsScopingTest do
  @moduledoc """
  Charter D85/D86 (Cloud-Build wave 2b, Door 2) — MEDIA twin of
  `SearchSynonymsScopingTest`. The flat media synonyms/insights admin block
  (`/v1/media/:dataset/search/*`) was byte-identical to the documents block:
  `pipe_through([:api, :require_admin])`, so a workspace-bound admin token
  collapsed to the seeded Default workspace and read/wrote Default's media
  synonyms. The fix repoints it onto `:flat_admin_api`
  (`DeriveWorkspaceFromToken` fail-SOFT before `AssignDefaultScope`).

  MUTATION-PROOF (fail-before). Revert ONLY the pipe flip on the media flat block
  and the THREE ws-resolution assertions in "workspace-bound token resolves its
  OWN workspace" go RED (token_a sees Default's "default-only" instead of its own
  "alpha"; POST stamps Default's id). The over-block test stays GREEN in both
  states. Restore → all green.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Search.Synonyms

  @ds "production"

  setup do
    {default_ws, _project} = ensure_default_scope!()
    ws_a = create_workspace!()
    ws_b = create_workspace!()
    {:ok, default_ws: default_ws, ws_a: ws_a, ws_b: ws_b}
  end

  # ws.id 5th arg is load-bearing: nil binds to Default (the nil-stays-green trap).
  defp bound_admin_token!(ws) do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(raw, "media-scoping-admin", @ds, ["read", "write", "admin"], ws.id)

    raw
  end

  defp nil_workspace_admin_token! do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, _} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "media-nil-ws-admin",
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

  defp seed!(ws_id, from) do
    {:ok, _} = Synonyms.create("media", @ds, %{"from" => from, "to" => "#{from}-to"}, ws_id)
    :ok
  end

  defp froms(result), do: Enum.map(result, & &1["from"])

  describe "workspace-bound token resolves its OWN workspace" do
    test "GET /synonyms returns its own rows, never Default's; POST stamps its ws.id",
         %{default_ws: default_ws, ws_a: ws_a} do
      seed!(ws_a.id, "alpha")
      seed!(default_ws.id, "default-only")

      raw = bound_admin_token!(ws_a)

      conn = get(conn_for(raw), "/v1/media/#{@ds}/search/synonyms")
      %{"result" => result} = json_response(conn, 200)
      got = froms(result)

      assert "alpha" in got
      refute "default-only" in got

      post_conn =
        post(conn_for(raw), "/v1/media/#{@ds}/search/synonyms", %{
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
      conn = get(conn_for(raw), "/v1/media/#{@ds}/search/synonyms")

      %{"result" => result} = json_response(conn, 200)
      assert result == []
    end

    test "ws-A DELETE of a ws-B row → 404 and the B row survives; own delete works",
         %{ws_a: ws_a, ws_b: ws_b} do
      seed!(ws_b.id, "bravo")
      seed!(ws_a.id, "alpha")

      raw = bound_admin_token!(ws_a)

      b_row = Repo.get_by!(Barkpark.Search.Synonym, workspace_id: ws_b.id, from_query: "bravo")
      del_b = delete(conn_for(raw), "/v1/media/#{@ds}/search/synonyms/#{b_row.id}")
      assert json_response(del_b, 404)
      assert Repo.get(Barkpark.Search.Synonym, b_row.id)

      a_row = Repo.get_by!(Barkpark.Search.Synonym, workspace_id: ws_a.id, from_query: "alpha")
      del_a = delete(conn_for(raw), "/v1/media/#{@ds}/search/synonyms/#{a_row.id}")
      assert %{"ok" => true} = json_response(del_a, 200)
      refute Repo.get(Barkpark.Search.Synonym, a_row.id)
    end
  end

  describe "nil-workspace / global-admin READ is never over-blocked (D59)" do
    test "GET /synonyms and GET /insights still 200, never 403" do
      seed!(nil, "global")

      raw = nil_workspace_admin_token!()

      syn = get(conn_for(raw), "/v1/media/#{@ds}/search/synonyms")
      %{"result" => result} = json_response(syn, 200)
      assert "global" in froms(result)

      ins = get(conn_for(raw), "/v1/media/#{@ds}/search/insights")
      assert %{"result" => _} = json_response(ins, 200)
    end
  end
end
