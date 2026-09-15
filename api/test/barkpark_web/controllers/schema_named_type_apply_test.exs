defmodule BarkparkWeb.SchemaNamedTypeApplyTest do
  @moduledoc """
  Gyldendal parity E3.6: `POST /v1/schemas/:dataset` refuses a field whose type
  is neither built-in nor a registered object type — a 422 that NAMES the type
  — and accepts it once the object type has been applied.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @dataset "test"

  setup do
    token = "barkpark-dev-token-named-type-#{System.unique_integer([:positive])}"
    Auth.create_token(token, "dev", "schema-named-type-test", ["read", "write", "admin"])
    suffix = System.unique_integer([:positive])
    %{token: token, doc: "nt_doc_#{suffix}", obj: "nt_seo_#{suffix}"}
  end

  defp post_schema(ctx, body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/schemas/#{@dataset}", Jason.encode!(body))
  end

  defp doc_body(ctx) do
    %{
      "name" => ctx.doc,
      "title" => "Utgivelse",
      "visibility" => "public",
      "fields" => [
        %{"name" => "title", "type" => "string"},
        %{"name" => "seo", "title" => "SEO og sosiale medier", "type" => ctx.obj}
      ]
    }
  end

  test "an unknown type name is a 422 that names the type; after the object type is applied the same payload lands",
       ctx do
    conn = post_schema(ctx, doc_body(ctx))
    assert conn.status == 422, "expected 422, got #{conn.status}: #{conn.resp_body}"
    assert conn.resp_body =~ ctx.obj
    assert conn.resp_body =~ "object type"

    obj =
      post_schema(ctx, %{
        "name" => ctx.obj,
        "kind" => "object",
        "title" => "SEO og sosiale medier",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "noindex", "type" => "boolean"}
        ]
      })

    assert obj.status in 200..201, obj.resp_body
    assert Jason.decode!(obj.resp_body)["kind"] == "object"

    landed = post_schema(ctx, doc_body(ctx))
    assert landed.status in 200..201, landed.resp_body

    read =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> get("/v1/schemas/#{@dataset}/#{ctx.doc}")

    assert read.status == 200

    body = Jason.decode!(read.resp_body)
    schema = body["schema"] || body["result"] || body
    seo = Enum.find(schema["fields"] || [], &(&1["name"] == "seo"))
    assert seo, "no seo field in the read-back: #{String.slice(read.resp_body, 0, 300)}"

    assert seo["type"] == "composite"
    assert seo["namedType"] == ctx.obj
    assert Enum.map(seo["fields"], & &1["name"]) == ["title", "noindex"]
  end
end
