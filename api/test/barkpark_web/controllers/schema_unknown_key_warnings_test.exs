defmodule BarkparkWeb.SchemaUnknownKeyWarningsTest do
  @moduledoc """
  task-415c5c02fad8a3c7 — a schema apply carrying a key Barkpark never reads
  still answers 201, and now names each such key in an advisory `warnings`
  entry. Before, `requred`, `requird` and `singelton` vanished without a word.
  ADVISORY ONLY: refusing them is an open owner decision.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @dataset "test"
  @token "barkpark-test-unknown-key-warnings"

  setup do
    {:ok, _} =
      Auth.create_token(
        @token,
        "unknown-key-warnings",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    :ok
  end

  defp apply_schema(conn, body, query \\ "") do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/schemas/#{@dataset}#{query}", Jason.encode!(body))
  end

  @typo_body %{
    "name" => "unknown_key_widget",
    "title" => "Unknown Key Widget",
    "singelton" => true,
    "fields" => [
      %{"name" => "a", "type" => "string", "requred" => true},
      %{"name" => "b", "type" => "string", "validation" => %{"requird" => true}}
    ]
  }

  test "the write still lands, and each ignored key is named by path", %{conn: conn} do
    resp = apply_schema(conn, @typo_body)

    assert resp.status == 201, resp.resp_body
    body = Jason.decode!(resp.resp_body)
    assert body["name"] == "unknown_key_widget"

    assert Enum.map(body["warnings"], & &1["path"]) ==
             ["/singelton", "/fields/0/requred", "/fields/1/validation/requird"]

    assert Enum.all?(body["warnings"], &(&1["code"] == "schema_unknown_key"))
    assert Enum.all?(body["warnings"], &(&1["severity"] == "advisory"))
  end

  test "validate_only carries the same advisories on its 200", %{conn: conn} do
    resp = apply_schema(conn, @typo_body, "?validate_only=true")

    assert resp.status == 200, resp.resp_body
    assert length(Jason.decode!(resp.resp_body)["warnings"]) == 3
  end

  test "a clean schema keeps its exact shape: no warnings key", %{conn: conn} do
    resp =
      apply_schema(conn, %{
        "name" => "known_key_widget",
        "title" => "Known Key Widget",
        "fields" => [
          %{"name" => "a", "type" => "string", "validation" => %{"required" => true}}
        ]
      })

    assert resp.status == 201, resp.resp_body
    refute Map.has_key?(Jason.decode!(resp.resp_body), "warnings")
  end

  # task-59d6a6ba332509a0: an image field's valueShape is read by Studio, so
  # validate_only and apply name no advisory for it, and the stored field
  # keeps it.
  test "valueShape on an image field draws no warning and is kept", %{conn: conn} do
    body = %{
      "name" => "value_shape_widget",
      "title" => "Value Shape Widget",
      "fields" => [%{"name" => "heroImage", "type" => "image", "valueShape" => "assetRef"}]
    }

    check = apply_schema(conn, body, "?validate_only=true")
    assert check.status == 200, check.resp_body
    refute Map.has_key?(Jason.decode!(check.resp_body), "warnings")

    resp = apply_schema(conn, body)
    assert resp.status == 201, resp.resp_body
    stored = Jason.decode!(resp.resp_body)
    refute Map.has_key?(stored, "warnings")
    assert [%{"name" => "heroImage", "valueShape" => "assetRef"}] = stored["fields"]
  end

  # task-c85d90756c6b6e97: GET /v1/schemas inlines a named object type and
  # stamps namedType on the field; posting the pulled schema back with
  # validate_only names no advisory for it.
  test "a pulled schema with an inlined named object type posts back with no warning", %{
    conn: conn
  } do
    object = %{
      "name" => "named_type_block",
      "title" => "Named Type Block",
      "kind" => "object",
      "fields" => [%{"name" => "t", "type" => "string"}]
    }

    doc = %{
      "name" => "named_type_page",
      "title" => "Named Type Page",
      "fields" => [
        %{"name" => "block", "type" => "named_type_block"},
        %{"name" => "blocks", "type" => "array", "of" => [%{"type" => "named_type_block"}]}
      ]
    }

    assert apply_schema(conn, object).status == 201
    assert apply_schema(conn, doc).status == 201

    pulled =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/v1/schemas/#{@dataset}/named_type_page")
      |> json_response(200)

    pulled = Map.get(pulled, "schema", pulled)
    assert Enum.any?(pulled["fields"], &(&1["namedType"] == "named_type_block")), inspect(pulled)

    check = apply_schema(build_conn(), Map.drop(pulled, ["id"]), "?validate_only=true")
    assert check.status == 200, check.resp_body

    warnings = Map.get(Jason.decode!(check.resp_body), "warnings", [])
    refute Enum.any?(warnings, &(&1["key"] == "namedType")), inspect(warnings)
  end
end
