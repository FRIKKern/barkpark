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
end
