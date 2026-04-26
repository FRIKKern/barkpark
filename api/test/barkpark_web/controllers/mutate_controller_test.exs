defmodule BarkparkWeb.MutateControllerTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  setup do
    Barkpark.Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  # A create without _type triggers Ecto.Changeset validate_required on Document
  # → Errors.to_envelope produces validation_failed with a details map.
  defp invalid_payload do
    Jason.encode!(%{
      "mutations" => [
        %{"create" => %{"_id" => "no-type-1", "title" => "x"}}
      ]
    })
  end

  test "back-compat: validation error returns the legacy v1 envelope when Accept-Version is absent",
       %{conn: conn} do
    resp = conn |> authed() |> post("/v1/data/mutate/test", invalid_payload())

    assert resp.status == 422
    body = Jason.decode!(resp.resp_body)

    assert body["error"]["code"] == "validation_failed"
    # v1 keeps the legacy `details` map keyed by field name with a list of strings
    assert is_map(body["error"]["details"])
    assert is_list(body["error"]["details"]["type"])
    refute Map.has_key?(body["error"], "errors")
    refute Map.has_key?(body["error"], "warnings")
  end

  test "Accept-Version: 2 returns the hierarchical v2 envelope", %{conn: conn} do
    resp =
      conn
      |> authed()
      |> put_req_header("accept-version", "2")
      |> post("/v1/data/mutate/test", invalid_payload())

    assert resp.status == 422
    body = Jason.decode!(resp.resp_body)

    assert body["error"]["code"] == "validation_failed"
    refute Map.has_key?(body["error"], "details")

    assert %{"errors" => errors, "warnings" => %{}, "infos" => %{}} = body["error"]
    assert is_map(errors)
    assert [%{"severity" => _, "code" => _, "message" => _} | _] = errors["/type"]
  end

  test "non-validation errors keep the same shape regardless of Accept-Version", %{conn: conn} do
    {:ok, doc} = Content.create_document("post", %{"_id" => "rm-x", "title" => "v1"}, "test")

    body =
      Jason.encode!(%{
        "mutations" => [
          %{
            "patch" => %{
              "id" => doc.doc_id,
              "type" => "post",
              "ifRevisionID" => "wrong-rev",
              "set" => %{"title" => "v2"}
            }
          }
        ]
      })

    resp =
      conn
      |> authed()
      |> put_req_header("accept-version", "2")
      |> post("/v1/data/mutate/test", body)

    assert resp.status == 412
    parsed = Jason.decode!(resp.resp_body)
    # rev_mismatch's structured `details` is NOT a per-field error map and
    # must not be reshaped by the v2 envelope transformation.
    assert parsed["error"]["code"] == "precondition_failed"
    assert parsed["error"]["details"]["expected"] == "wrong-rev"
  end
end
