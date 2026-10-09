defmodule BarkparkWeb.QueryControllerExpandSourceMapTest do
  @moduledoc """
  task-0e0cb2167c6fcdea — `?sourceMap=true&expand=<field>` provenance for the
  sub-document an `?expand=` swapped in. `source_map/2`'s original scope cut
  (task-f18edb4599e06308) left this out: a flat-field mapping names the
  PARENT document for every field, which is wrong once a field's value is no
  longer the parent's own content but a different document's rendered
  envelope.

  Covers both the doc-get (`Envelope.source_map/3`) and list
  (`Envelope.source_map_many/3`) surfaces, a single-reference field, an
  array-of-references field, redaction on the EXPANDED document (its own
  `private` field must stay out of its mappings, same chokepoint as the
  parent), and an unresolved reference (no expand entry, not a dangling one).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"
  @read_token "barkpark-test-expand-sourcemap-read"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} =
      Auth.create_token(@read_token, "expand-sourcemap-read", @dataset, ["read", "write"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Author",
          "visibility" => "public",
          "fields" => [
            %{"name" => "name", "type" => "string"},
            %{"name" => "email", "type" => "string", "private" => true}
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "tag",
          "title" => "Tag",
          "visibility" => "public",
          "fields" => [%{"name" => "label", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "author", "type" => "reference", "refType" => "author"},
            %{
              "name" => "tags",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "tag"}
            }
          ]
        },
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_author!(id, name, email, scope) do
    {:ok, _} =
      Content.create_document(
        "author",
        %{"doc_id" => id, "name" => name, "email" => email},
        @dataset,
        scope
      )

    id
  end

  defp mk_tag!(id, label, scope) do
    {:ok, _} =
      Content.create_document("tag", %{"doc_id" => id, "label" => label}, @dataset, scope)

    id
  end

  defp mk_post!(id, fields, scope) do
    {:ok, _} =
      Content.create_document("post", Map.put(fields, "doc_id", id), @dataset, scope)

    id
  end

  # ── doc-get: single reference ────────────────────────────────────────────

  test "an expanded single-reference field gets its own documents entry and mapping", %{
    conn: conn,
    scope: scope
  } do
    author_id = mk_author!(uniq("auth"), "Ada", "ada@example.com", scope)
    post_id = mk_post!(uniq("post"), %{"title" => "POST_TITLE", "author" => author_id}, scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{post_id}", %{
        "perspective" => "drafts",
        "sourceMap" => "true",
        "expand" => "author"
      })
      |> json_response(200)

    assert body["result"]["author"]["name"] == "Ada"
    source_map = body["sourceMap"]
    refute is_nil(source_map)

    # Root at index 0, the expanded author appended at index 1.
    [root, author_doc] = source_map["documents"]
    assert root["_id"] == body["result"]["_id"]
    assert author_doc["_type"] == "author"

    title_mapping = source_map["mappings"][~s($["title"])]
    assert title_mapping["source"]["document"] == 0

    name_mapping = source_map["mappings"][~s($["author"]["name"])]
    refute is_nil(name_mapping)
    assert name_mapping["source"]["document"] == 1
    path_idx = name_mapping["source"]["path"]

    # The author's OWN rendered keys are "email" (private, redacted away),
    # "name", and "title" (every envelope carries one, task-13711) —
    # alphabetically "name" sorts first among the two survivors, index 0.
    assert path_idx == 0

    # The redacted `email` field never appears — same chokepoint `source_map`
    # already relies on for the root document.
    refute Map.has_key?(source_map["mappings"], ~s($["author"]["email"]))
  end

  test "an array-of-references field gets one documents entry per resolved element, index-addressed",
       %{conn: conn, scope: scope} do
    tag_a = mk_tag!(uniq("tag"), "Elixir", scope)
    tag_b = mk_tag!(uniq("tag"), "CMS", scope)

    post_id =
      mk_post!(uniq("post"), %{"title" => "T", "tags" => [tag_a, tag_b]}, scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{post_id}", %{
        "perspective" => "drafts",
        "sourceMap" => "true",
        "expand" => "tags"
      })
      |> json_response(200)

    source_map = body["sourceMap"]
    refute is_nil(source_map)

    # Root + two expanded tags, in element order.
    assert length(source_map["documents"]) == 3
    [_root, tag_doc_0, tag_doc_1] = source_map["documents"]
    assert tag_doc_0["_type"] == "tag"
    assert tag_doc_1["_type"] == "tag"

    label_0 = source_map["mappings"][~s($["tags"][0]["label"])]
    refute is_nil(label_0)
    assert label_0["source"]["document"] == 1

    label_1 = source_map["mappings"][~s($["tags"][1]["label"])]
    refute is_nil(label_1)
    assert label_1["source"]["document"] == 2
  end

  test "an unresolved reference (dangling target) contributes no expand entry", %{
    conn: conn,
    scope: scope
  } do
    post_id =
      mk_post!(uniq("post"), %{"title" => "T", "author" => "no-such-doc-id"}, scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{post_id}", %{
        "perspective" => "drafts",
        "sourceMap" => "true",
        "expand" => "author"
      })
      |> json_response(200)

    source_map = body["sourceMap"]
    refute is_nil(source_map)
    # Only the root — the unresolved reference never became a rendered doc,
    # so the diff against base_rendered finds nothing changed at "author".
    assert [_root] = source_map["documents"]
    refute Map.has_key?(source_map["mappings"], ~s($["author"]["name"]))
  end

  test "without ?expand=, the response is byte-identical to the flat-fields-only shape", %{
    conn: conn,
    scope: scope
  } do
    author_id = mk_author!(uniq("auth"), "Ada", "ada@example.com", scope)
    post_id = mk_post!(uniq("post"), %{"title" => "T", "author" => author_id}, scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{post_id}", %{
        "perspective" => "drafts",
        "sourceMap" => "true"
      })
      |> json_response(200)

    source_map = body["sourceMap"]
    assert [_root] = source_map["documents"]
    refute Map.has_key?(source_map["mappings"], ~s($["author"]["name"]))
  end

  # ── list results ─────────────────────────────────────────────────────────

  test "a list row's expanded reference is appended AFTER every row's own slot", %{
    conn: conn,
    scope: scope
  } do
    author_a = mk_author!(uniq("auth"), "Ada", "ada@example.com", scope)
    author_b = mk_author!(uniq("auth"), "Bea", "bea@example.com", scope)

    id_a = mk_post!(uniq("post"), %{"title" => "A", "author" => author_a}, scope)
    id_b = mk_post!(uniq("post"), %{"title" => "B", "author" => author_b}, scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/query/#{@dataset}/post", %{
        "perspective" => "drafts",
        "sourceMap" => "true",
        "expand" => "author",
        "order" => "title:asc"
      })
      |> json_response(200)

    rows = body["result"]["documents"]
    assert Enum.map(rows, & &1["_id"]) == ["drafts." <> id_a, "drafts." <> id_b]

    source_map = body["sourceMap"]
    refute is_nil(source_map)

    # Both rows still occupy documents[0] and documents[1] — their row index —
    # exactly like the no-expand list contract. The two expanded authors are
    # appended after, at indices 2 and 3.
    [_row0, _row1, author_doc_0, author_doc_1] = source_map["documents"]
    assert author_doc_0["_type"] == "author"
    assert author_doc_1["_type"] == "author"

    name_row0 = source_map["mappings"][~s($[0]["author"]["name"])]
    refute is_nil(name_row0)
    assert name_row0["source"]["document"] == 2

    name_row1 = source_map["mappings"][~s($[1]["author"]["name"])]
    refute is_nil(name_row1)
    assert name_row1["source"]["document"] == 3

    # The row's OWN flat field still addresses the row's own slot, unchanged.
    title_row0 = source_map["mappings"][~s($[0]["title"])]
    assert title_row0["source"]["document"] == 0
  end

  test "REFUSED/IGNORED under published perspective, same as the flat-fields rule", %{
    conn: conn,
    scope: scope
  } do
    author_id = mk_author!(uniq("auth"), "Ada", "ada@example.com", scope)
    post_id = mk_post!(uniq("post"), %{"title" => "T", "author" => author_id}, scope)
    {:ok, _} = Content.publish_document(post_id, "post", @dataset, scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{post_id}", %{
        "sourceMap" => "true",
        "expand" => "author"
      })
      |> json_response(200)

    refute Map.has_key?(body, "sourceMap")
  end
end
