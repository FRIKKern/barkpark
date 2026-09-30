defmodule BarkparkWeb.SchemaShowNotFoundTest do
  @moduledoc """
  task-8d46c1fe49954697 — GET /v1/schemas/:dataset/:name for a name with no
  schema names the SCHEMA. It used to answer the document wording
  ("not found: document not found", hint "Check the document _id, type, and
  dataset…"), though no document was named.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content

  @dataset "schema404"

  setup do
    {ws, _project} = ensure_default_scope!()
    token = "schema-404-token-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "schema-404", @dataset, ["read", "write", "admin"], ws.id)
    %{token: token}
  end

  defp get_schema(conn, token, name) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/v1/schemas/#{@dataset}/#{name}")
  end

  test "a missing schema answers 404 not_found naming the schema and dataset, not a document",
       %{conn: conn, token: token} do
    body = conn |> get_schema(token, "nosuchtype") |> json_response(404)
    error = body["error"] || body

    assert error["code"] == "not_found"
    assert error["message"] =~ "schema"
    assert error["message"] =~ "nosuchtype"
    assert error["message"] =~ @dataset
    refute error["message"] =~ "document"
    refute error["hint"] =~ "document _id"
    assert error["hint"] =~ "/v1/schemas/#{@dataset}"
  end

  test "CONTROL: an existing schema still answers 200 with the schema", %{
    conn: conn,
    token: token
  } do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "present", "title" => "Present", "fields" => []},
        @dataset
      )

    body = conn |> get_schema(token, "present") |> json_response(200)
    assert body["schema"]["name"] == "present"
  end
end
