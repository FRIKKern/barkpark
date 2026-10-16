defmodule BarkparkWeb.SchemaFieldsetsTest do
  @moduledoc """
  task-344d5275adc4270c: a schema's top-level `fieldsets` (Sanity's
  `[{name, title, options}]`) had no column, so `POST /v1/schemas/:dataset`
  answered 201 and the read came back without them. A named object type's
  fieldsets were lost the same way when a document inlined it.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth

  @admin_token "barkpark-dev-token-schema-fieldsets"

  @size %{
    "name" => "size",
    "title" => "Size",
    "options" => %{"columns" => 2, "collapsible" => true}
  }

  setup do
    Auth.create_token(@admin_token, "dev", "schema-fieldsets-test", ["read", "write", "admin"])
    :ok
  end

  defp post_schema(body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> @admin_token)
    |> put_req_header("content-type", "application/json")
    |> post(~p"/v1/schemas/test", Jason.encode!(body))
  end

  test "document and named object fieldsets read back after a write" do
    assert %{status: 201} =
             post_schema(%{
               "name" => "fs_dims",
               "kind" => "object",
               "title" => "Dimensions",
               "fieldsets" => [@size],
               "fields" => [%{"name" => "depth", "type" => "number", "fieldset" => "size"}]
             })

    resp =
      post_schema(%{
        "name" => "fs_poster",
        "title" => "Poster",
        "fieldsets" => [@size],
        "fields" => [
          %{"name" => "width", "type" => "number", "fieldset" => "size"},
          %{"name" => "height", "type" => "number", "fieldset" => "size"},
          %{"name" => "dims", "type" => "fs_dims"}
        ]
      })

    created = json_response(resp, 201)
    assert created["fieldsets"] == [@size]
    refute Map.has_key?(created, "warnings")

    show =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> @admin_token)
      |> get(~p"/v1/schemas/test/fs_poster")
      |> json_response(200)

    assert show["schema"]["fieldsets"] == [@size]
    assert Enum.find(show["schema"]["fields"], &(&1["name"] == "dims"))["fieldsets"] == [@size]
  end
end
