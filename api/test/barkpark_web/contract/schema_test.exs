defmodule BarkparkWeb.Contract.SchemaTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.{Auth, Content}

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    :ok
  end

  test "schema index carries _schemaVersion", %{conn: conn} do
    body =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/schemas/test")
      |> json_response(200)

    assert body["_schemaVersion"] == 1
    assert is_list(body["schemas"])
    assert Enum.any?(body["schemas"], &(&1["name"] == "post"))
  end

  test "schema show carries _schemaVersion", %{conn: conn} do
    body =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/schemas/test/post")
      |> json_response(200)

    assert body["_schemaVersion"] == 1
    assert body["schema"]["name"] == "post"
  end

  test "upsert rejects a structurally-invalid fields payload with a 422", %{conn: conn} do
    body =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post("/v1/schemas/test", %{
        "name" => "widget",
        "title" => "Widget",
        # a field with no `name` — parse/2 rejects it
        "fields" => [%{"type" => "string"}]
      })
      |> json_response(422)

    assert body["error"]["code"] == "validation_failed"
    assert body["error"]["message"] =~ "schema fields failed validation"
    # and nothing got persisted under the bad name
    assert Content.get_schema("widget", "test", []) == {:error, :not_found}
  end

  test "upsert rejects a reserved plugin: field prefix on the ad-hoc endpoint", %{conn: conn} do
    body =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post("/v1/schemas/test", %{
        "name" => "gadget",
        "title" => "Gadget",
        "fields" => [%{"name" => "plugin:secret:x", "type" => "string"}]
      })
      |> json_response(422)

    assert body["error"]["code"] == "validation_failed"
  end

  test "upsert with a valid fields payload still succeeds (no false rejection)", %{conn: conn} do
    body =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post("/v1/schemas/test", %{
        "name" => "post",
        "title" => "Post v2",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "body", "type" => "text"}
        ]
      })
      |> json_response(201)

    assert body["name"] == "post"
    assert body["title"] == "Post v2"
  end

  test "upsert of a fields-less partial update is not re-validated", %{conn: conn} do
    # No `fields` key → the stored (valid) definition is left untouched and the
    # write is never re-validated, so a title-only edit always succeeds.
    body =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> post("/v1/schemas/test", %{"name" => "post", "title" => "Renamed"})
      |> json_response(201)

    assert body["title"] == "Renamed"
  end
end
