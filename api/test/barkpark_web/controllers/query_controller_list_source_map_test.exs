defmodule BarkparkWeb.QueryControllerListSourceMapTest do
  @moduledoc """
  task-b54d854d43769266 — `GET /v1/data/query/:dataset/:type?sourceMap=true`
  returns a `sourceMap` field mapping EACH ROW to its source document and
  field, so a list page (home-page cards, a title+author listing) can mark up
  its results for click-to-edit without one doc-get per row. #22277 added
  the same opt-in to doc-get only (`Envelope.source_map/2`); this is its list
  sibling (`Envelope.source_map_many/2`). Same scope cut: flat fields only,
  drafts/raw only — see that function's moduledoc.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"
  @read_token "barkpark-test-list-sourcemap-read"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)
    {:ok, _} = Auth.create_token(@read_token, "list-sourcemap-read", @dataset, ["read", "write"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "author", "type" => "string"},
            %{"name" => "ssn", "type" => "string", "private" => true}
          ]
        },
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_draft!(doc_id, scope, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(
        "post",
        Map.merge(
          %{
            "doc_id" => doc_id,
            "title" => "TITLE_#{doc_id}",
            "author" => "AUTHOR_#{doc_id}",
            "ssn" => "SECRET_#{doc_id}"
          },
          attrs
        ),
        @dataset,
        scope
      )

    doc_id
  end

  defp mk_published!(doc_id, scope) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => "PUB_#{doc_id}", "author" => "PUB_AUTHOR_#{doc_id}"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "post", @dataset, scope)
    doc_id
  end

  # Each test's `post` documents are the ONLY `post` rows this test's own
  # sandboxed transaction sees (Ecto.Adapters.SQL.Sandbox isolates per test),
  # so no `?filter=`/`?order=` is needed to isolate them from other tests —
  # that sidesteps the filter/order grammar entirely and keeps this file
  # about the source map, not about query syntax.
  defp row_index_of!(rows, doc_id) do
    Enum.find_index(rows, &(&1["_id"] == doc_id)) ||
      flunk("no row in #{inspect(rows)} has _id #{inspect(doc_id)}")
  end

  test "each result row maps to its OWN document index, in row order", %{
    conn: conn,
    scope: scope
  } do
    id1 = mk_draft!(uniq("list-sm-a"), scope)
    id2 = mk_draft!(uniq("list-sm-b"), scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/query/#{@dataset}/post", %{
        "perspective" => "drafts",
        "sourceMap" => "true"
      })
      |> json_response(200)

    rows = body["result"]["documents"]
    assert length(rows) == 2

    source_map = body["sourceMap"]
    refute is_nil(source_map)
    assert length(source_map["documents"]) == 2

    # Each row's documents[] entry matches that row's own rendered _id -- the
    # whole point: row i's address is document i, never a bare "document 0"
    # repeated across rows.
    for id <- [id1, id2] do
      idx = row_index_of!(rows, "drafts." <> id)
      assert Enum.at(source_map["documents"], idx)["_id"] == "drafts." <> id

      title_path = ~s($[#{idx}]["title"])
      mapping = source_map["mappings"][title_path]
      assert mapping["source"]["document"] == idx
    end
  end

  test "under raw perspective, row mappings also resolve", %{conn: conn, scope: scope} do
    mk_draft!(uniq("list-sm-raw"), scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/query/#{@dataset}/post", %{
        "perspective" => "raw",
        "sourceMap" => "true"
      })
      |> json_response(200)

    refute is_nil(body["sourceMap"])
    assert Map.has_key?(body["sourceMap"]["mappings"], ~s($[0]["author"]))
  end

  test "REFUSED/IGNORED under published perspective — no sourceMap key at all", %{
    conn: conn,
    scope: scope
  } do
    mk_published!(uniq("list-sm-pub"), scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/query/#{@dataset}/post", %{"sourceMap" => "true"})
      |> json_response(200)

    assert length(body["result"]["documents"]) == 1
    refute Map.has_key?(body, "sourceMap")
  end

  test "omitting ?sourceMap entirely never adds the key, even under drafts", %{
    conn: conn,
    scope: scope
  } do
    mk_draft!(uniq("list-sm-omit"), scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/query/#{@dataset}/post", %{"perspective" => "drafts"})
      |> json_response(200)

    refute Map.has_key?(body, "sourceMap")
  end

  test "REDACTED (private) fields never appear in any row's mapping", %{
    conn: conn,
    scope: scope
  } do
    mk_draft!(uniq("list-sm-redacted"), scope)

    # @read_token carries no admin permission, so the private `ssn` field is
    # dropped by Envelope.render_many/3 before source_map_many/2 ever sees it.
    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/query/#{@dataset}/post", %{
        "perspective" => "drafts",
        "sourceMap" => "true"
      })
      |> json_response(200)

    [row] = body["result"]["documents"]
    refute Map.has_key?(row, "ssn")
    refute Map.has_key?(body["sourceMap"]["mappings"], ~s($[0]["ssn"]))
    refute body |> Jason.encode!() |> String.contains?("SECRET_")
  end

  test "an empty result set omits the sourceMap key entirely", %{conn: conn} do
    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/query/#{@dataset}/post", %{
        "perspective" => "drafts",
        "sourceMap" => "true"
      })
      |> json_response(200)

    assert body["result"]["documents"] == []
    refute Map.has_key?(body, "sourceMap")
  end
end
