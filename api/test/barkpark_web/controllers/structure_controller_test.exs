defmodule BarkparkWeb.StructureControllerTest do
  use BarkparkWeb.ConnCase, async: true

  # GET /v1/structure/:dataset serves the SAME tree Studio renders
  # (Barkpark.Structure.build/2) — host groups + plugin desk items — so the
  # TUI's desk can equal Studio's without client-side per-plugin logic.

  setup %{conn: conn} do
    {:ok, _} =
      Barkpark.Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "📄",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        "production"
      )

    {:ok, _} =
      Barkpark.Auth.create_token(
        "barkpark-structure-test-token",
        "structure-test",
        "test",
        ["read", "write", "admin"]
      )

    {:ok, conn: put_req_header(conn, "authorization", "Bearer barkpark-structure-test-token")}
  end

  test "serves the canonical tree with typed nodes", %{conn: conn} do
    resp = get(conn, "/v1/structure/production") |> json_response(200)

    root = resp["structure"]
    assert root["id"] == "root"
    assert root["type"] == "list"
    assert is_list(root["items"]) and root["items"] != []

    # Every node carries a known type; absent fields are omitted (no nulls).
    walk = fn walk, node ->
      assert node["type"] in ~w(list list_item document_type_list document_list document divider
                  link nested plugin_document_list plugin_link)
      refute Map.has_key?(node, "filter") and is_nil(node["filter"])
      Enum.each(node["items"] || [], &walk.(walk, &1))
      if node["child"], do: walk.(walk, node["child"])
    end

    walk.(walk, root)

    # The post type is reachable somewhere in the tree (content group).
    flat = :erlang.term_to_binary(root)
    assert flat =~ "post"
  end

  test "serves a tiered tree: MAIN top-level, a Plugins node and a …Rest node, all as :list", %{
    conn: conn
  } do
    # An enabled :plugins-placement plugin (OnixEdit, promoted only to enabled,
    # keeping its default :plugins placement) puts a books group under Plugins;
    # orphaned documents (no schema) force a …Rest node. Both must serialize as
    # plain :list nodes so old Go TUI binaries render them (no new node `type`).
    {:ok, _} =
      Barkpark.Content.upsert_schema(
        %{"name" => "book", "title" => "Books", "visibility" => "private", "fields" => []},
        "production"
      )

    Barkpark.Repo.insert!(%Barkpark.Content.Document{
      doc_id: "book-1",
      type: "book",
      dataset: "production",
      status: "published",
      title: "A Book",
      rev: "r1",
      content: %{}
    })

    Barkpark.Repo.insert!(%Barkpark.Content.Document{
      doc_id: "ghost-1",
      type: "ghostType",
      dataset: "production",
      status: "published",
      title: "Orphan",
      rev: "r2",
      content: %{}
    })

    # Default workspace has no plugin overrides at the API level (scope_opts →
    # no workspace_id for the flat desk), so OnixEdit stays default-disabled and
    # book falls into …Rest. That still proves the …Rest tier + node types.
    root = get(conn, "/v1/structure/production") |> json_response(200) |> Map.fetch!("structure")

    rest = Enum.find(root["items"], &(&1["id"] == "rest"))
    assert rest, "expected a …Rest node when orphaned/unplaced doc types exist"

    assert rest["type"] == "list",
           "…Rest must be a plain :list — old TUI binaries drop unknown types"

    rest_titles = Enum.map(rest["items"], & &1["title"])

    assert Enum.any?(rest_titles, &(&1 == "ghostType (1)")),
           "orphaned types surface in …Rest with an honest count — never silently hidden"

    # The orphaned child is a plain (non-drillable) :document leaf, but still a
    # KNOWN type the Go switch keeps (never dropped).
    ghost = Enum.find(rest["items"], &(&1["typeName"] == "ghostType"))
    assert ghost["type"] == "document"
  end

  test "anonymous callers are rejected" do
    conn = Phoenix.ConnTest.build_conn()
    resp = get(conn, "/v1/structure/production")
    assert resp.status in [401, 403]
  end

  describe "?desk= names another deskStructure document (task-31f9264adeb053be)" do
    setup do
      {:ok, _} =
        Barkpark.Content.upsert_schema(
          %{
            "name" => "deskStructure",
            "title" => "Desk",
            "singleton" => true,
            "visibility" => "private",
            "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
          },
          "production"
        )

      desk!("deskStructure", "Default desk", "Posts")
      desk!("deskStructure.pensum", "Pensum", "Pensum posts")
      :ok
    end

    defp desk!(id, title, row, extra \\ %{}) do
      items = [%{"kind" => "documentTypeList", "type" => "post", "title" => row}]
      content = Map.merge(%{"items" => items}, extra)

      {:ok, _} =
        Barkpark.Content.create_document(
          "deskStructure",
          %{"doc_id" => id, "title" => title, "content" => content},
          "production"
        )

      {:ok, _} = Barkpark.Content.publish_document(id, "deskStructure", "production")
    end

    defp titles(resp), do: Enum.map(resp["structure"]["items"], & &1["title"])

    test "builds the named published desk and names it back", %{conn: conn} do
      resp = get(conn, "/v1/structure/production?desk=deskStructure.pensum") |> json_response(200)

      assert resp["desk"] == "deskStructure.pensum"
      assert resp["structure"]["title"] == "Pensum"
      assert "Pensum posts" in titles(resp)
      refute "Posts" in titles(resp)
    end

    test "without ?desk= the default desk is unchanged and not named", %{conn: conn} do
      resp = get(conn, "/v1/structure/production") |> json_response(200)

      refute Map.has_key?(resp, "desk")
      assert resp["structure"]["title"] == "Default desk"
      assert "Posts" in titles(resp)
    end

    test "a desk id with no published document is not named back", %{conn: conn} do
      {:ok, _} =
        Barkpark.Content.create_document(
          "deskStructure",
          %{
            "doc_id" => "deskStructure.draftonly",
            "title" => "Draft",
            "content" => %{"items" => []}
          },
          "production"
        )

      resp =
        get(conn, "/v1/structure/production?desk=deskStructure.draftonly") |> json_response(200)

      refute Map.has_key?(resp, "desk")
      refute resp["structure"]["title"] == "Draft"
    end

    # The one never-hide exception (owner, 2026-10-25): `"only": true` on a
    # NAMED desk serves exactly the declared items — no plugin items, no
    # Plugins tier, no …Rest. The default desk ignores it.
    test "a named desk without \"only\" keeps the appended tiers", %{conn: conn} do
      resp = get(conn, "/v1/structure/production?desk=deskStructure.pensum") |> json_response(200)

      assert "Pensum posts" in titles(resp)
      assert length(titles(resp)) > 1
    end

    test "a named desk with \"only\": true serves only its declared items", %{conn: conn} do
      desk!("deskStructure.pensum", "Pensum", "Pensum posts", %{"only" => true})
      resp = get(conn, "/v1/structure/production?desk=deskStructure.pensum") |> json_response(200)

      assert titles(resp) == ["Pensum posts"]
    end

    test "the default desk ignores \"only\": true", %{conn: conn} do
      before = get(conn, "/v1/structure/production") |> json_response(200)
      desk!("deskStructure", "Default desk", "Posts", %{"only" => true})
      resp = get(conn, "/v1/structure/production") |> json_response(200)

      assert titles(resp) == titles(before)
      assert length(titles(resp)) > 1

      explicit = get(conn, "/v1/structure/production?desk=deskStructure") |> json_response(200)
      assert titles(explicit) == titles(before)
    end

    test "a drafts. or malformed id is a 400", %{conn: conn} do
      for desk <- ["drafts.deskStructure.pensum", "bad id", ".hidden", String.duplicate("a", 129)] do
        resp = get(conn, "/v1/structure/production", %{"desk" => desk}) |> json_response(400)
        assert resp["error"]["code"] == "malformed"
      end

      resp = get(conn, "/v1/structure/production?desk[]=x") |> json_response(400)
      assert resp["error"]["code"] == "malformed"
    end

    test "the credential gate is unchanged", %{conn: _conn} do
      resp =
        get(Phoenix.ConnTest.build_conn(), "/v1/structure/production?desk=deskStructure.pensum")

      assert resp.status in [401, 403]
    end
  end
end
