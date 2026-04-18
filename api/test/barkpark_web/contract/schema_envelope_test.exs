defmodule BarkparkWeb.Contract.SchemaEnvelopeTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.{Auth, Content}

  @token "barkpark-dev-token"

  setup do
    Auth.create_token(@token, "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string", "required" => true},
          %{"name" => "slug", "type" => "slug", "required" => true},
          %{"name" => "body", "type" => "richText"},
          %{
            "name" => "tags",
            "type" => "array",
            "of" => [
              %{"type" => "string"},
              %{"type" => "reference", "to" => [%{"type" => "category"}]}
            ]
          },
          %{"name" => "author", "type" => "reference", "refType" => "person"}
        ]
      },
      "test"
    )

    # Legacy endpoint reads from "production" dataset — seed it too.
    Content.upsert_schema(
      %{
        "name" => "page",
        "title" => "Page",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string", "required" => true},
          %{"name" => "body", "type" => "richText"}
        ]
      },
      "production"
    )

    :ok
  end

  defp get_json(conn, path) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get(path)
    |> json_response(200)
  end

  test "SDK schema index emits schemas + datasetSchemaHash (16-char hex)", %{conn: conn} do
    body = get_json(conn, "/v1/schemas/test")

    assert is_list(body["schemas"])
    assert is_binary(body["datasetSchemaHash"])
    assert String.length(body["datasetSchemaHash"]) == 16
    assert body["datasetSchemaHash"] =~ ~r/^[0-9a-f]{16}$/
  end

  test "each schema carries schemaHash (16-char hex) and a fields list", %{conn: conn} do
    body = get_json(conn, "/v1/schemas/test")
    post = Enum.find(body["schemas"], &(&1["name"] == "post"))

    assert post
    assert is_binary(post["schemaHash"])
    assert String.length(post["schemaHash"]) == 16
    assert post["schemaHash"] =~ ~r/^[0-9a-f]{16}$/
    assert is_list(post["fields"])
  end

  test "every field has a boolean required? key", %{conn: conn} do
    body = get_json(conn, "/v1/schemas/test")
    post = Enum.find(body["schemas"], &(&1["name"] == "post"))

    for field <- post["fields"] do
      assert Map.has_key?(field, "required?"),
             "missing required? on field #{inspect(field)}"
      assert is_boolean(field["required?"])
    end

    title = Enum.find(post["fields"], &(&1["name"] == "title"))
    body_field = Enum.find(post["fields"], &(&1["name"] == "body"))
    assert title["required?"] == true
    assert body_field["required?"] == false
  end

  test "array-typed fields emit an `of` list of element specs", %{conn: conn} do
    body = get_json(conn, "/v1/schemas/test")
    post = Enum.find(body["schemas"], &(&1["name"] == "post"))
    tags = Enum.find(post["fields"], &(&1["name"] == "tags"))

    assert tags["type"] == "array"
    assert is_list(tags["of"])
    assert %{"type" => "string"} in tags["of"]

    ref_spec = Enum.find(tags["of"], &(&1["type"] == "reference"))
    assert ref_spec
    assert is_list(ref_spec["to"])
  end

  test "reference-typed fields emit a `to` list derived from refType", %{conn: conn} do
    body = get_json(conn, "/v1/schemas/test")
    post = Enum.find(body["schemas"], &(&1["name"] == "post"))
    author = Enum.find(post["fields"], &(&1["name"] == "author"))

    assert author["type"] == "reference"
    assert author["to"] == [%{"type" => "person"}]
  end

  test "legacy /api/schemas retains the original bare-array shape", %{conn: conn} do
    body =
      conn
      |> get("/api/schemas")
      |> json_response(200)

    assert is_list(body)
    page = Enum.find(body, &(&1["name"] == "page"))
    assert page
    refute Map.has_key?(page, "schemaHash")
    refute Map.has_key?(page, "visibility")
    assert is_list(page["fields"])

    for field <- page["fields"] do
      refute Map.has_key?(field, "required?"),
             "legacy endpoint leaked required? in field #{inspect(field)}"
    end
  end
end
