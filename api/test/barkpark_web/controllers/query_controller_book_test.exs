defmodule BarkparkWeb.QueryControllerBookTest do
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}

  @raw_token "wi2-test-token-#{System.unique_integer([:positive])}"
  @dataset "wi2_book_test"

  setup do
    # Flat routes resolve the seeded Default workspace/project via
    # AssignDefaultScope, and the query layer now filters reads by it. Stamp
    # the same Default scope on these fixtures so they live where the flat
    # route reads (mirrors the backfill: every flat-route row belongs to
    # Default).
    ws = Tenancy.get_default_workspace()
    project = Tenancy.get_default_project()
    scope = [workspace_id: ws.id, project_id: project.id]

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Posts",
        "visibility" => "public",
        "fields" => []
      },
      @dataset
    )

    Content.upsert_schema(
      %{
        "name" => "book",
        "title" => "Book",
        "visibility" => "private",
        "fields" => []
      },
      @dataset
    )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "wi2-post-1", "title" => "Public Post"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("wi2-post-1", "post", @dataset, scope)

    {:ok, _} =
      Content.create_document(
        "book",
        %{"_id" => "wi2-book-1", "title" => "Published Book"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("wi2-book-1", "book", @dataset, scope)

    {:ok, _} =
      Content.create_document(
        "book",
        %{"_id" => "wi2-book-draft", "title" => "Draft Only Book"},
        @dataset,
        scope
      )

    {:ok, _} = Auth.create_token(@raw_token, "wi2 test token", @dataset, ["read", "write"])

    :ok
  end

  defp authed(conn) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> @raw_token)
  end

  describe "GET /v1/data/query/:dataset/:type" do
    test "anonymous on private schema returns 404", %{conn: conn} do
      resp = get(conn, "/v1/data/query/#{@dataset}/book")
      assert resp.status == 404
    end

    test "authed on private schema returns 200 with published-perspective documents",
         %{conn: conn} do
      body =
        conn
        |> authed()
        |> get("/v1/data/query/#{@dataset}/book")
        |> json_response(200)

      docs = body["result"]["documents"]
      assert is_list(docs)
      ids = Enum.map(docs, & &1["_id"])
      assert "wi2-book-1" in ids
      refute Enum.any?(ids, &String.starts_with?(&1, "drafts."))
      assert body["result"]["perspective"] == "published"
    end

    test "authed on private schema with perspective=drafts returns drafts.* documents",
         %{conn: conn} do
      body =
        conn
        |> authed()
        |> get("/v1/data/query/#{@dataset}/book?perspective=drafts")
        |> json_response(200)

      docs = body["result"]["documents"]
      ids = Enum.map(docs, & &1["_id"])
      assert "drafts.wi2-book-draft" in ids
      assert body["result"]["perspective"] == "drafts"
    end

    test "anonymous on public schema still returns 200 (no regression)",
         %{conn: conn} do
      body =
        conn
        |> get("/v1/data/query/#{@dataset}/post")
        |> json_response(200)

      ids = Enum.map(body["result"]["documents"], & &1["_id"])
      assert "wi2-post-1" in ids
    end
  end

  describe "GET /v1/data/doc/:dataset/:type/:doc_id" do
    test "anonymous on private schema returns 404", %{conn: conn} do
      resp = get(conn, "/v1/data/doc/#{@dataset}/book/wi2-book-1")
      assert resp.status == 404
    end

    test "authed on private schema returns the document", %{conn: conn} do
      body =
        conn
        |> authed()
        |> get("/v1/data/doc/#{@dataset}/book/wi2-book-1")
        |> json_response(200)

      assert body["result"]["_id"] == "wi2-book-1"
    end
  end
end
