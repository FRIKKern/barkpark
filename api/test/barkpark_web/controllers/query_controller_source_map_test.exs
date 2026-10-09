defmodule BarkparkWeb.QueryControllerSourceMapTest do
  @moduledoc """
  task-f18edb4599e06308 (candidate 1) — `GET /v1/data/doc/:dataset/:type/:doc_id
  ?sourceMap=true` returns a `sourceMap` field (`{result path -> source
  document + field}`) for click-to-edit. Scoped to flat fields and to
  drafts/raw perspectives only — see `Envelope.source_map/2`'s moduledoc for
  why, and task-0e0cb2167c6fcdea for the filed follow-up on `?expand=`/
  computed-field provenance.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"
  @read_token "barkpark-test-sourcemap-read"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)
    {:ok, _} = Auth.create_token(@read_token, "sourcemap-read", @dataset, ["read", "write"])

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
            %{"name" => "body", "type" => "string"},
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

  defp mk_draft!(doc_id, scope) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "doc_id" => doc_id,
          "title" => "DRAFT_TITLE",
          "body" => "DRAFT_BODY",
          "ssn" => "SECRET"
        },
        @dataset,
        scope
      )

    doc_id
  end

  defp mk_published!(doc_id, scope) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => "PUB_TITLE", "body" => "PUB_BODY", "ssn" => "SECRET2"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "post", @dataset, scope)
    doc_id
  end

  test "mappings resolve to the right document and field, under drafts", %{
    conn: conn,
    scope: scope
  } do
    id = mk_draft!(uniq("sm-drafts"), scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{
        "perspective" => "drafts",
        "sourceMap" => "true"
      })
      |> json_response(200)

    assert body["result"]["title"] == "DRAFT_TITLE"
    source_map = body["sourceMap"]
    refute is_nil(source_map)

    [doc] = source_map["documents"]
    assert doc["_id"] == body["result"]["_id"]
    assert doc["_type"] == "post"

    title_mapping = source_map["mappings"][~s($["title"])]
    assert title_mapping["source"]["document"] == 0
    path_idx = title_mapping["source"]["path"]
    assert Enum.at(source_map["paths"], path_idx) == ~s($["title"])
  end

  test "under raw perspective, mappings also resolve", %{conn: conn, scope: scope} do
    id = mk_draft!(uniq("sm-raw"), scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{
        "perspective" => "raw",
        "sourceMap" => "true"
      })
      |> json_response(200)

    refute is_nil(body["sourceMap"])
    assert Map.has_key?(body["sourceMap"]["mappings"], ~s($["body"]))
  end

  test "REFUSED/IGNORED under published perspective — no sourceMap key at all", %{
    conn: conn,
    scope: scope
  } do
    id = mk_published!(uniq("sm-pub"), scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{"sourceMap" => "true"})
      |> json_response(200)

    assert body["result"]["title"] == "PUB_TITLE"
    refute Map.has_key?(body, "sourceMap")
  end

  test "REFUSED/IGNORED under explicit ?perspective=published too", %{
    conn: conn,
    scope: scope
  } do
    id = mk_published!(uniq("sm-pub-explicit"), scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{
        "perspective" => "published",
        "sourceMap" => "true"
      })
      |> json_response(200)

    refute Map.has_key?(body, "sourceMap")
  end

  test "omitting ?sourceMap entirely never adds the key, even under drafts", %{
    conn: conn,
    scope: scope
  } do
    id = mk_draft!(uniq("sm-omit"), scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{"perspective" => "drafts"})
      |> json_response(200)

    refute Map.has_key?(body, "sourceMap")
  end

  test "REDACTED (private) fields never appear in the mappings", %{conn: conn, scope: scope} do
    id = mk_draft!(uniq("sm-redacted"), scope)

    # @read_token carries no admin permission, so the private `ssn` field is
    # dropped by Envelope.render/3 before source_map/2 ever sees it.
    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{id}", %{
        "perspective" => "drafts",
        "sourceMap" => "true"
      })
      |> json_response(200)

    refute Map.has_key?(body["result"], "ssn")
    refute Map.has_key?(body["sourceMap"]["mappings"], ~s($["ssn"]))
    refute Enum.member?(body["sourceMap"]["paths"], ~s($["ssn"]))
    refute body |> Jason.encode!() |> String.contains?("SECRET")
  end
end
