defmodule BarkparkWeb.StructureControllerTest do
  use BarkparkWeb.ConnCase, async: false

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

  test "anonymous callers are rejected" do
    conn = Phoenix.ConnTest.build_conn()
    resp = get(conn, "/v1/structure/production")
    assert resp.status in [401, 403]
  end
end
