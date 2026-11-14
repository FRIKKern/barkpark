defmodule BarkparkWeb.SchemaStoredFieldsTest do
  @moduledoc """
  `GET /v1/schemas/:dataset?definition=stored` serves each schema's `fields`
  as stored, so the nested fields of an array member come back. The default
  list keeps cutting a member down to type, to and name.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth

  @admin_token "barkpark-dev-token-schema-stored-fields"

  @fields [
    %{
      "name" => "rows",
      "type" => "array",
      "of" => [
        %{
          "type" => "object",
          "name" => "row",
          "fields" => [%{"name" => "label", "type" => "string"}]
        }
      ]
    }
  ]

  setup do
    Auth.create_token(@admin_token, "dev", "schema-stored-fields-test", ["read", "write", "admin"])

    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin_token)
    |> put_req_header("content-type", "application/json")
  end

  defp listed(conn, path) do
    body = conn |> authed() |> get(path) |> json_response(200)
    {body, Enum.find(body["schemas"], &(&1["name"] == "stored_fields_widget"))}
  end

  test "definition=stored serves the stored members; the default list cuts them down",
       %{conn: conn} do
    body = %{"name" => "stored_fields_widget", "title" => "Widget", "fields" => @fields}
    assert conn |> authed() |> post(~p"/v1/schemas/test", Jason.encode!(body)) |> response(201)

    {envelope, schema} = listed(conn, ~p"/v1/schemas/test?definition=stored")
    assert envelope["definition"] == "stored"
    assert schema["fields"] == @fields
    assert is_binary(schema["schemaHash"])

    {envelope, schema} = listed(conn, ~p"/v1/schemas/test")
    refute Map.has_key?(envelope, "definition")
    assert [%{"of" => [%{"type" => "object", "name" => "row"} = member]}] = schema["fields"]
    refute Map.has_key?(member, "fields")
  end
end
