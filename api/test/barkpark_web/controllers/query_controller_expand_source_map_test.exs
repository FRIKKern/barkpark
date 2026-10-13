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

    # task-d0c2bd670e2d8a87: `path_idx` indexes a table SHARED across the
    # root document and every expanded sub-document, so its numeric value
    # depends on what else the walk has already seen — never pin a literal
    # index. The invariant that must hold is that `paths[path_idx]` names
    # the author's OWN bare in-document field, "name" — not the root's
    # "title", and not the author's own redacted "email".
    assert Enum.at(source_map["paths"], path_idx) == ~s($["name"])

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

  test "every mapping's paths[source.path] names exactly the field it addresses, across rows and expanded refs (task-d0c2bd670e2d8a87)",
       %{conn: conn, scope: scope} do
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

    # THE BUG, pinned generically rather than at one hand-picked index:
    # `paths[source.path]` must be the BARE in-document path of the exact
    # field the mapping's own (prefixed) result key names — never the
    # alphabetically-unrelated field a global sort or a per-document-local
    # counter happened to land on. `result_path/1`'s shape means that bare
    # path is always a suffix of the full result key once `"$"` is dropped.
    for {result_path, %{"source" => %{"path" => path_idx}}} <- source_map["mappings"] do
      bare_path = Enum.at(source_map["paths"], path_idx)

      assert is_binary(bare_path) and
               String.ends_with?(result_path, String.trim_leading(bare_path, "$")),
             "mapping #{inspect(result_path)} points at paths[#{path_idx}] = " <>
               "#{inspect(bare_path)}, which does not name the field #{inspect(result_path)} addresses"
    end

    # And the two concrete pairs the live repro actually hit, named directly:
    # the root `title` on EACH row, and the expanded author's OWN `name`.
    for row <- [0, 1] do
      title_idx = source_map["mappings"][~s($[#{row}]["title"])]["source"]["path"]
      assert Enum.at(source_map["paths"], title_idx) == ~s($["title"])

      name_idx = source_map["mappings"][~s($[#{row}]["author"]["name"])]["source"]["path"]
      assert Enum.at(source_map["paths"], name_idx) == ~s($["name"])
    end
  end

  test "repro-shaped regression (live report): a root `title` mapping and an expanded author's " <>
         "`name` mapping never cross-resolve to an unrelated field like `format`/`expertise'",
       %{conn: conn, scope: scope} do
    # Widen both schemas with an EXTRA field whose alphabetical position
    # falls BETWEEN the field the live report named and some other one —
    # exactly the shape ("format" sorting after "author", "expertise"
    # sorting after "email") that let the old global-sort/local-counter
    # mismatch land on a plausible-looking but WRONG field.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Author",
          "visibility" => "public",
          "fields" => [
            %{"name" => "name", "type" => "string"},
            %{"name" => "email", "type" => "string", "private" => true},
            %{"name" => "expertise", "type" => "string"}
          ]
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
            %{"name" => "format", "type" => "string"},
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

    author_id = mk_author!(uniq("auth"), "Ada", "ada@example.com", scope)

    {:ok, _} =
      Content.create_document(
        "author",
        %{
          "doc_id" => author_id,
          "name" => "Ada",
          "email" => "ada@example.com",
          "expertise" => "ML"
        },
        @dataset,
        scope
      )

    id_a =
      mk_post!(
        uniq("post"),
        %{"title" => "A", "format" => "article", "author" => author_id},
        scope
      )

    id_b = mk_post!(uniq("post"), %{"title" => "B", "format" => "note"}, scope)

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

    assert Enum.map(body["result"]["documents"], & &1["_id"]) ==
             ["drafts." <> id_a, "drafts." <> id_b]

    source_map = body["sourceMap"]
    refute is_nil(source_map)

    title_idx = source_map["mappings"][~s($[0]["title"])]["source"]["path"]
    format_idx = source_map["mappings"][~s($[0]["format"])]["source"]["path"]
    assert Enum.at(source_map["paths"], title_idx) == ~s($["title"])
    assert Enum.at(source_map["paths"], format_idx) == ~s($["format"])
    refute title_idx == format_idx

    name_idx = source_map["mappings"][~s($[0]["author"]["name"])]["source"]["path"]
    assert Enum.at(source_map["paths"], name_idx) == ~s($["name"])
    refute Enum.at(source_map["paths"], name_idx) == ~s($["expertise"])
    refute Enum.at(source_map["paths"], name_idx) == ~s($["format"])
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

  # ── security: the expanded doc's OWN redaction/perspective still binds ───

  test "a private field on the expanded document never appears in ITS OWN mappings", %{
    conn: conn,
    scope: scope
  } do
    author_id = mk_author!(uniq("auth"), "Ada", "ada@secret.example", scope)
    post_id = mk_post!(uniq("post"), %{"title" => "T", "author" => author_id}, scope)

    body =
      conn
      |> bearer(@read_token)
      |> get("/v1/data/doc/#{@dataset}/post/#{post_id}", %{
        "perspective" => "drafts",
        "sourceMap" => "true",
        "expand" => "author"
      })
      |> json_response(200)

    # The actual RESULT never carries the private field either — this is
    # `Envelope.render/3`'s own chokepoint, unchanged by this task — but the
    # property under test is specifically the SOURCE MAP: a click-to-edit
    # overlay that could point an editor at a field the result body itself
    # never rendered would be its own, narrower leak.
    refute Map.has_key?(body["result"]["author"], "email")

    source_map = body["sourceMap"]
    refute Map.has_key?(source_map["mappings"], ~s($["author"]["email"]))

    # Not "absent because nothing matched" — "name" (same document, same
    # redaction pass) DOES appear, so the absence of "email" is the
    # redaction working, not an empty/vacuous map.
    assert Map.has_key?(source_map["mappings"], ~s($["author"]["name"]))
  end

  test "a reference to a document in a DIFFERENT workspace is never expanded, and leaks nothing into sourceMap",
       %{conn: conn} do
    ws_a = TenancyFixtures.create_workspace!(uniq("expws-a"))
    proj_a = TenancyFixtures.create_project!(ws_a, uniq("proj-a"))
    scope_a = [workspace_id: ws_a.id, project_id: proj_a.id]

    ws_b = TenancyFixtures.create_workspace!(uniq("expws-b"))
    proj_b = TenancyFixtures.create_project!(ws_b, uniq("proj-b"))
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    for {dataset_scope, suffix} <- [{scope_a, "a"}, {scope_b, "b"}] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "author",
            "title" => "Author",
            "visibility" => "public",
            "fields" => [%{"name" => "name", "type" => "string"}]
          },
          @dataset,
          dataset_scope
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
          @dataset,
          dataset_scope
        )

      _ = suffix
    end

    # B's own author, under an id A's post will also reference. SAME doc_id,
    # DIFFERENT dataset_id (the unique index is (doc_id, type, dataset_id),
    # not globally unique) -- the exact bare-id-collision shape this
    # codebase's tenancy fences exist for.
    shared_author_id = uniq("auth-shared")

    {:ok, _} =
      Content.create_document(
        "author",
        %{"doc_id" => shared_author_id, "name" => "SECRET_B_NAME"},
        @dataset,
        scope_b
      )

    # A's post references that id. A has NO author doc under it at all.
    post_id = uniq("post-a")

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => post_id, "title" => "T", "author" => shared_author_id},
        @dataset,
        scope_a
      )

    admin_a_raw = "spt-expand-a-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin_a_raw, "expand-a", @dataset, ["read", "write"], ws_a.id)

    body =
      conn
      |> bearer(admin_a_raw)
      |> get("/v1/data/doc/#{@dataset}/post/#{post_id}", %{
        "perspective" => "drafts",
        "sourceMap" => "true",
        "expand" => "author"
      })
      |> json_response(200)

    # Expand found NOTHING under A's own scope: the field stays the bare id,
    # never B's rendered document. If this ever assembled to a map, B's
    # content would already be in the RESULT body, before sourceMap even
    # enters the picture.
    assert body["result"]["author"] == shared_author_id

    source_map = body["sourceMap"]
    refute is_nil(source_map)
    # Root only -- no second documents[] entry, because nothing was expanded.
    assert [_root] = source_map["documents"]
    refute Map.has_key?(source_map["mappings"], ~s($["author"]["name"]))
    refute inspect(source_map) =~ "SECRET_B_NAME"
  end
end
