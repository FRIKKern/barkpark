defmodule BarkparkWeb.Integration.PreviewTokenDocScopeTest do
  @moduledoc """
  Owner ruling #17 (task-8bac87cd4b34aeb6): a preview token reads what it
  names.

  The `doc_ids` claim was recorded in `preview_token_jti` but never enforced,
  so a token signed for one document read every draft in the Default
  workspace's dataset. Now a token with `doc_ids` reads only those documents,
  and an optional `workspace_id` claim seats the read in that workspace. A
  token with an empty `doc_ids` list keeps reading the whole dataset, so
  existing integrations are unchanged.

  `async: false` — `Application.put_env(:barkpark, :preview, …)` is global.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, PreviewToken, Tenancy}

  @secret "test-preview-secret-docscope-1234567890"
  @dataset "production"

  setup do
    prior = Application.get_env(:barkpark, :preview)

    Application.put_env(:barkpark, :preview,
      secret: @secret,
      ttl_seconds: 600,
      issuer: "barkpark"
    )

    on_exit(fn -> Application.put_env(:barkpark, :preview, prior || []) end)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset
      )

    {ws, project} = ensure_default!()

    for {id, title} <- [{"p1", "PREVIEW ONE"}, {"p2", "SECRET TWO"}] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => id, "title" => title},
          @dataset,
          workspace_id: ws.id,
          project_id: project.id
        )
    end

    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "wsb-docscope", name: "WS B"})
    {:ok, proj_b} = Tenancy.create_project(ws_b, %{slug: "pb-docscope", name: "Proj B"})

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "b1", "title" => "B DRAFT"},
        @dataset,
        workspace_id: ws_b.id,
        project_id: proj_b.id
      )

    %{ws_b: ws_b, proj_b: proj_b}
  end

  defp ensure_default! do
    ws =
      Tenancy.get_default_workspace() ||
        elem(Tenancy.create_workspace(%{slug: "default", name: "Default"}), 1)

    project =
      Tenancy.get_default_project() ||
        elem(Tenancy.create_project(ws, %{slug: "default", name: "Default"}), 1)

    {ws, project}
  end

  defp jwt(claims) do
    {jwt, _} = PreviewToken.sign(Map.merge(%{dataset: @dataset}, claims), @secret)
    jwt
  end

  defp preview(conn, jwt), do: put_req_header(conn, "authorization", "Preview " <> jwt)

  defp ids(resp), do: Enum.map(json_response(resp, 200)["result"]["documents"], & &1["_id"])

  describe "a token with doc_ids" do
    test "reads its own draft", %{conn: conn} do
      resp =
        conn |> preview(jwt(%{doc_ids: ["p1"]})) |> get("/v1/preview/doc/#{@dataset}/post/p1")

      assert resp.status == 200
      assert resp.resp_body =~ "PREVIEW ONE"
    end

    test "cannot read another draft: 403 preview_scope, token not burned", %{conn: conn} do
      token = jwt(%{doc_ids: ["p1"]})

      resp = conn |> preview(token) |> get("/v1/preview/doc/#{@dataset}/post/p2")
      assert resp.status == 403
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["reason"] == "preview_scope"
      refute resp.resp_body =~ "SECRET TWO"

      # The refused read did not record the JTI: the same token still works
      # for the document it names.
      ok = build_conn() |> preview(token) |> get("/v1/preview/doc/#{@dataset}/post/p1")
      assert ok.status == 200
    end

    test "a drafts.-prefixed id on either side still matches", %{conn: conn} do
      resp =
        conn
        |> preview(jwt(%{doc_ids: ["drafts.p1"]}))
        |> get("/v1/preview/doc/#{@dataset}/post/p1")

      assert resp.status == 200
    end

    test "the query route returns only the named documents, and the count agrees", %{conn: conn} do
      resp =
        conn
        |> preview(jwt(%{doc_ids: ["p1"]}))
        |> get("/v1/preview/query/#{@dataset}/post?count=true")

      assert ids(resp) == ["drafts.p1"]
      assert json_response(resp, 200)["result"]["total"] == 1
    end

    test "backlinks, related, tags and ?expand are refused", %{conn: conn} do
      for path <- [
            "/v1/preview/backlinks/#{@dataset}/p1",
            "/v1/preview/related/#{@dataset}/p1",
            "/v1/preview/tags/#{@dataset}",
            "/v1/preview/doc/#{@dataset}/post/p1?expand=author"
          ] do
        resp = conn |> recycle() |> preview(jwt(%{doc_ids: ["p1"]})) |> get(path)
        assert resp.status == 403, "#{path} answered #{resp.status}"
      end
    end
  end

  describe "a dataset-wide token (empty doc_ids) is unchanged" do
    test "reads any Default draft and lists them all", %{conn: conn} do
      resp = conn |> preview(jwt(%{doc_ids: []})) |> get("/v1/preview/doc/#{@dataset}/post/p2")
      assert resp.status == 200

      list = build_conn() |> preview(jwt(%{})) |> get("/v1/preview/query/#{@dataset}/post")
      assert Enum.sort(ids(list)) == ["drafts.p1", "drafts.p2"]
    end
  end

  describe "the workspace claim" do
    test "seats the read in the named workspace", %{conn: conn, ws_b: ws_b} do
      resp =
        conn
        |> preview(jwt(%{workspace_id: ws_b.id}))
        |> get("/v1/preview/query/#{@dataset}/post")

      assert ids(resp) == ["drafts.b1"]
    end

    test "with a project claim of that workspace", %{conn: conn, ws_b: ws_b, proj_b: proj_b} do
      resp =
        conn
        |> preview(jwt(%{workspace_id: ws_b.id, project_id: proj_b.id, doc_ids: ["b1"]}))
        |> get("/v1/preview/doc/#{@dataset}/post/b1")

      assert resp.status == 200
    end

    test "an unknown workspace or a foreign project is refused", %{conn: conn, ws_b: ws_b} do
      {_ws, default_project} = ensure_default!()

      for claims <- [
            %{workspace_id: Ecto.UUID.generate()},
            %{workspace_id: ws_b.id, project_id: default_project.id}
          ] do
        resp =
          conn |> recycle() |> preview(jwt(claims)) |> get("/v1/preview/query/#{@dataset}/post")

        assert resp.status == 403
      end
    end

    test "without the claim, workspace B's draft stays out of reach", %{conn: conn} do
      resp = conn |> preview(jwt(%{})) |> get("/v1/preview/query/#{@dataset}/post")
      refute "drafts.b1" in ids(resp)
    end
  end
end
