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
end
