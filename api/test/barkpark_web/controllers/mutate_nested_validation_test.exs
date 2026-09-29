defmodule BarkparkWeb.MutateNestedValidationTest do
  @moduledoc """
  Gyldendal parity E1.11 (task-34ea5ee00dfb7a99) on the API door: a required
  rule on a subfield — inside a NAMED object type (E3.6) and inside an arrayOf
  composite row — refuses a create through `POST /v1/data/mutate` on an
  enforcing dataset, 422 `validation_failed`, with the finding under its
  TOP-LEVEL field and the subfield path in the message. The flat envelope
  keying (`details.<field> => [msg]`) is unchanged.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Validation

  setup do
    dataset = "e111enf_#{System.unique_integer([:positive])}"
    token = "barkpark-dev-token-e111-#{System.unique_integer([:positive])}"

    Auth.create_token(
      token,
      "dev",
      dataset,
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    previous = Application.get_env(:barkpark, Validation, [])
    Application.put_env(:barkpark, Validation, enforce_datasets: [dataset])
    on_exit(fn -> Application.put_env(:barkpark, Validation, previous) end)

    # The unscoped mutate door reads the DEFAULT workspace; the named type and
    # the document type are applied there, on a dataset registered under it.
    ws = Barkpark.Tenancy.get_default_workspace()
    proj = Barkpark.Tenancy.get_default_project()
    {:ok, _} = Barkpark.Tenancy.create_dataset(proj, %{slug: dataset, name: dataset})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "seo",
          "kind" => "object",
          "title" => "SEO",
          "fields" => [
            %{"name" => "title", "type" => "string", "validation" => %{"required" => true}},
            %{"name" => "description", "type" => "text"}
          ]
        },
        dataset,
        scope
      )

    type = "e111page_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Page",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "seo", "type" => "seo"},
            %{
              "name" => "banners",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "fields" => [
                  %{"name" => "title", "type" => "string", "validation" => %{"required" => true}}
                ]
              }
            }
          ]
        },
        dataset,
        scope
      )

    %{token: token, dataset: dataset, type: type}
  end

  defp create(ctx, doc_id, content) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{ctx.dataset}",
      Jason.encode!(%{
        "mutations" => [
          %{
            "create" => %{
              "_id" => doc_id,
              "_type" => ctx.type,
              "title" => "Page",
              "content" => content
            }
          }
        ]
      })
    )
  end

  test "a required miss inside the named seo type and inside a banners row is refused 422, keyed by the top-level field with the path in the message",
       ctx do
    doc_id = "e111-nested-#{System.unique_integer([:positive])}"

    resp =
      create(ctx, doc_id, %{
        "seo" => %{"description" => "no title"},
        "banners" => [%{"title" => "ok"}, %{}]
      })

    assert resp.status == 422, "expected a refusal, got #{resp.status}: #{resp.resp_body}"
    body = json_response(resp, 422)
    assert body["error"]["code"] == "validation_failed"

    details = body["error"]["details"]
    assert details["seo"] == ["/seo/title: Required"]
    assert details["banners"] == ["/banners/1/title: Required"]
    assert Map.keys(details) |> Enum.sort() == ["banners", "seo"]

    refute match?(
             {:ok, _},
             Content.get_document(
               Barkpark.Content.DraftId.draft_id(doc_id),
               ctx.type,
               ctx.dataset
             )
           ),
           "the refused document must not exist"
  end

  test "content satisfying every nested rule lands 200", ctx do
    doc_id = "e111-good-#{System.unique_integer([:positive])}"

    resp =
      create(ctx, doc_id, %{
        "seo" => %{"title" => "T", "description" => "d"},
        "banners" => [%{"title" => "ok"}]
      })

    assert resp.status == 200, resp.resp_body
  end
end
