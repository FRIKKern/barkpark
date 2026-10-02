defmodule BarkparkWeb.ValidationFailedSubjectTest do
  @moduledoc """
  task-7f0e58f885c3e363 — a `validation_failed` for an input that is not a
  document names what failed. A bad `?order=` answered "document failed
  validation" with a hint to match the schema, and a bad webhook url answered
  the same headline with a hint about Content-Type, though neither request sent
  a document. The field-level `details` were always right and stay the same.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content

  @dataset "vfsubject"

  setup do
    {ws, _project} = ensure_default_scope!()
    token = "vf-subject-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "vf-subject", @dataset, ["read", "write", "admin"], ws.id)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    %{token: token}
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  test "a bad ?order= names the query parameter, not a document or a schema",
       %{conn: conn, token: token} do
    body =
      conn
      |> authed(token)
      |> get("/v1/data/query/#{@dataset}/post?order=title")
      |> json_response(422)

    err = body["error"]
    assert err["code"] == "validation_failed"
    assert err["message"] == "query parameter order failed validation"
    refute err["message"] =~ "document"
    refute err["hint"] =~ "schema"
    assert [msg] = err["details"]["order"]
    assert msg =~ "unrecognised order spec"
  end

  test "a bad webhook url names the webhook, and the hint is not about Content-Type",
       %{conn: conn, token: token} do
    body =
      conn
      |> authed(token)
      |> post(
        "/v1/webhooks/#{@dataset}",
        Jason.encode!(%{"name" => "t1", "url" => "not-a-url", "events" => ["create"]})
      )
      |> json_response(422)

    err = body["error"]
    assert err["code"] == "validation_failed"
    assert err["message"] == "webhook failed validation"
    refute err["hint"] =~ "Content-Type"
    assert err["details"]["url"] == ["must be an http(s) URL with a host"]
  end
end
