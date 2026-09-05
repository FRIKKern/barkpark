defmodule BarkparkWeb.QueryControllerExpandScopeTest do
  @moduledoc """
  P0 regression — cross-tenant read leak via `?expand=` (barkpark-8nb9).

  After the keystone (workspace_id uniqueness) and dataset-string-collapse
  fixes, doc_id collisions across workspaces are LEGAL: workspaces A and B can
  both hold a `post` named `p1` referencing an `author` named `a1`. The query
  layer's primary list/get reads are scoped, but `Content.Expand.expand/4`
  was previously called WITHOUT `scope_opts(conn)` — so `resolve_ref/4` hit
  `Content.get_document(ref_id, ref_type, dataset)` (3-arg, no opts), and
  `scope_to_workspace_or_global(query, nil, _)` happily returned the global
  match. Either `Repo.one` raises `Ecto.MultipleResultsError` on collision,
  or it returns the other workspace's row — embedded in A's response. Live
  cross-tenant content leak.

  This file proves both directions:

    * Workspace A's scoped query for `post/p1?expand=author` returns A's
      author, never B's, even when both workspaces hold a `post/p1 →
      author/a1` pair under the SAME dataset string.
    * A single-workspace expand still works (no regression on the happy path).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "expand_scope_leak_ds"

  setup do
    # Two distinct workspaces sharing the same dataset string. Project slugs
    # match the scoped /w/:ws/p/:project/... route convention. The dataset
    # string is the OLD multi-tenant collision axis — the fix guarantees the
    # WHERE clause filters by workspace_id even on the expand-time ref read.
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "ws-a-8nb9", name: "WS A"})
    {:ok, proj_a} = Tenancy.create_project(ws_a, %{slug: "proj-a", name: "P A"})

    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "ws-b-8nb9", name: "WS B"})
    {:ok, proj_b} = Tenancy.create_project(ws_b, %{slug: "proj-b", name: "P B"})

    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    # Public schemas — keep anon access trivial; the leak axis is workspace,
    # not visibility.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Author",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "author", "type" => "reference", "refType" => "author"}
          ]
        },
        @dataset
      )

    # Same doc_ids in both workspaces — the whole point of the keystone fix.
    # Distinct author titles per workspace so the leak is observable.
    {:ok, _} =
      Content.create_document(
        "author",
        %{"_id" => "a1", "title" => "Author from A"},
        @dataset,
        scope_a
      )

    {:ok, _} = Content.publish_document("a1", "author", @dataset, scope_a)

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p1", "title" => "Post in A", "author" => "a1"},
        @dataset,
        scope_a
      )

    {:ok, _} = Content.publish_document("p1", "post", @dataset, scope_a)

    {:ok, _} =
      Content.create_document(
        "author",
        %{"_id" => "a1", "title" => "Author from B"},
        @dataset,
        scope_b
      )

    {:ok, _} = Content.publish_document("a1", "author", @dataset, scope_b)

    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "p1", "title" => "Post in B", "author" => "a1"},
        @dataset,
        scope_b
      )

    {:ok, _} = Content.publish_document("p1", "post", @dataset, scope_b)

    # Tokens — one per workspace, each a member of its own workspace only.
    raw_a = "expand-scope-a-#{System.unique_integer([:positive])}"
    raw_b = "expand-scope-b-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw_a, "WS A token", @dataset, ["read", "write"], ws_a.id)
    {:ok, _} = Auth.create_token(raw_b, "WS B token", @dataset, ["read", "write"], ws_b.id)

    {:ok, raw_a: raw_a, raw_b: raw_b}
  end

  defp authed(conn, raw),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> raw)

  describe "scoped /w/:ws/p/:project query with ?expand=" do
    test "show/?expand=author returns the CALLER workspace's author, never the other workspace's",
         %{conn: conn, raw_a: raw_a} do
      body =
        conn
        |> authed(raw_a)
        |> get("/w/ws-a-8nb9/p/proj-a/v1/data/doc/#{@dataset}/post/p1?expand=author")
        |> json_response(200)

      result = body["result"]
      assert result["_id"] == "p1"
      assert result["title"] == "Post in A"
      # The leak signature: pre-fix, this is the OTHER workspace's row (or a
      # 500 from `Ecto.MultipleResultsError` raising in Repo.one). Post-fix,
      # workspace_id IS in the WHERE clause on the expand-time read.
      assert is_map(result["author"]),
             "author should have expanded into a map, got: #{inspect(result["author"])}"

      assert result["author"]["_id"] == "a1"
      assert result["author"]["title"] == "Author from A"
      refute result["author"]["title"] == "Author from B"
    end

    test "show/?expand=author from workspace B returns B's author (mirror direction)",
         %{conn: conn, raw_b: raw_b} do
      body =
        conn
        |> authed(raw_b)
        |> get("/w/ws-b-8nb9/p/proj-b/v1/data/doc/#{@dataset}/post/p1?expand=author")
        |> json_response(200)

      result = body["result"]
      assert result["title"] == "Post in B"
      assert is_map(result["author"])
      assert result["author"]["title"] == "Author from B"
      refute result["author"]["title"] == "Author from A"
    end

    test "list/?expand=author scopes the embedded author per workspace",
         %{conn: conn, raw_a: raw_a} do
      body =
        conn
        |> authed(raw_a)
        |> get("/w/ws-a-8nb9/p/proj-a/v1/data/query/#{@dataset}/post?expand=author")
        |> json_response(200)

      [post] = body["result"]["documents"]
      assert post["_id"] == "p1"
      assert is_map(post["author"])
      assert post["author"]["title"] == "Author from A"
    end
  end

  describe "single-workspace expand (regression guard)" do
    test "expand still resolves the ref when only one workspace holds the data",
         %{conn: conn, raw_a: raw_a} do
      # Workspace A is fully self-contained for its own (post p1 -> author a1)
      # pair. Just re-prove the happy path keeps working with opts threaded.
      body =
        conn
        |> authed(raw_a)
        |> get("/w/ws-a-8nb9/p/proj-a/v1/data/doc/#{@dataset}/post/p1?expand=author")
        |> json_response(200)

      assert body["result"]["author"]["_id"] == "a1"
    end
  end
end
