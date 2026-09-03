defmodule BarkparkWeb.SchemaUpsertEchoTest do
  @moduledoc """
  `POST /v1/schemas/:dataset` (upsert) must echo the same full SDK schema
  shape as `index`/`show` (`Content.serialize_schema_for_sdk/1`) — id,
  schemaHash, groups, deskGroups, crossValidations, listPreview included.

  Before the fix, `upsert/2` rendered a bespoke partial map (name/title/icon/
  visibility/fields/actions only) via a private `render_schema/1`, so callers
  reading `.id`/`.schemaHash` off the upsert response (as the SDK's
  `BarkparkSchema` type requires) got `nil`/`undefined`.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth

  @admin_token "barkpark-dev-token-schema-upsert-echo"

  setup do
    Auth.create_token(@admin_token, "dev", "schema-upsert-echo-test", ["read", "write", "admin"])
    :ok
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  test "POST /v1/schemas/:dataset echoes the full SDK schema shape, matching index/show",
       %{conn: conn} do
    body = %{
      "name" => "upsert_echo_widget",
      "title" => "Upsert Echo Widget",
      "visibility" => "public",
      "fields" => [%{"name" => "title", "type" => "string", "required" => true}]
    }

    resp =
      conn
      |> authed(@admin_token)
      |> post(~p"/v1/schemas/test", Jason.encode!(body))

    assert resp.status == 201
    created = json_response(resp, 201)

    assert created["id"] == "upsert_echo_widget"
    assert is_binary(created["schemaHash"])
    assert String.length(created["schemaHash"]) == 16
    assert is_list(created["groups"])
    assert is_list(created["deskGroups"])
    assert is_list(created["crossValidations"])
    assert created["listPreview"] == %{}

    field = Enum.find(created["fields"], &(&1["name"] == "title"))
    assert field["required?"] == true

    # Same dataset, same schema: the upsert echo must line up field-for-field
    # with what index/show serve for the identical schema.
    show =
      conn
      |> authed(@admin_token)
      |> get(~p"/v1/schemas/test/upsert_echo_widget")
      |> json_response(200)

    assert created == show["schema"]
  end
end
