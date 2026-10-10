defmodule BarkparkWeb.MutateCrossValidationTest do
  @moduledoc """
  task-9754deb160e95a80 on the API door: a schema's `cross_validations` ride
  the advise/enforce door. On an enforcing dataset an error-level rule
  refuses the create (422 `validation_failed`, keyed by the rule's first
  field); a warning-level rule and an unevaluable rule never refuse. On an
  advising dataset the error-level rule is a `schema_validation` advisory.
  """
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Validation

  setup do
    enforced = "xvenf_#{System.unique_integer([:positive])}"
    advised = "xvadv_#{System.unique_integer([:positive])}"
    token = "barkpark-dev-token-xv-#{System.unique_integer([:positive])}"
    ws = Barkpark.Tenancy.get_default_workspace()
    proj = Barkpark.Tenancy.get_default_project()
    scope = [workspace_id: ws.id, project_id: proj.id]

    previous = Application.get_env(:barkpark, Validation, [])
    Application.put_env(:barkpark, Validation, enforce_datasets: [enforced])
    on_exit(fn -> Application.put_env(:barkpark, Validation, previous) end)

    type = "xvbook_#{System.unique_integer([:positive])}"

    for dataset <- [enforced, advised] do
      Auth.create_token(token <> dataset, "dev", dataset, ["read", "write", "admin"], ws.id)
      {:ok, _} = Barkpark.Tenancy.create_dataset(proj, %{slug: dataset, name: dataset})

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Book",
            "visibility" => "public",
            "fields" => [
              %{"name" => "isbn", "type" => "string"},
              %{"name" => "gtin", "type" => "string"},
              %{"name" => "subtitle", "type" => "string"}
            ],
            "cross_validations" => [
              %{
                "name" => "isbn_xor_gtin",
                "title" => "At least one product identifier required",
                "level" => "error",
                "fields" => ["isbn", "gtin"],
                "rule" => %{
                  "any" => [
                    %{"field" => "isbn", "operator" => "non_empty"},
                    %{"field" => "gtin", "operator" => "non_empty"}
                  ]
                }
              },
              %{
                "name" => "subtitle_wanted",
                "title" => "A subtitle helps",
                "level" => "warning",
                "fields" => ["subtitle"],
                "rule" => %{"field" => "subtitle", "operator" => "non_empty"}
              },
              # Unevaluable (no such field): never a finding, never a refusal.
              %{
                "name" => "ghost",
                "level" => "error",
                "rule" => %{"field" => "nope", "operator" => "non_empty"}
              }
            ]
          },
          dataset,
          scope
        )
    end

    %{token: token, enforced: enforced, advised: advised, type: type}
  end

  defp create(ctx, dataset, content) do
    doc_id = "xv-#{System.unique_integer([:positive])}"

    resp =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> ctx.token <> dataset)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/data/mutate/#{dataset}",
        Jason.encode!(%{
          "mutations" => [
            %{
              "create" => %{
                "_id" => doc_id,
                "_type" => ctx.type,
                "title" => "B",
                "content" => content
              }
            }
          ]
        })
      )

    {resp, doc_id}
  end

  test "enforcing: an error-level cross rule refuses the create, keyed by its first field", ctx do
    {resp, doc_id} = create(ctx, ctx.enforced, %{"subtitle" => "s"})

    assert resp.status == 422, resp.resp_body
    error = json_response(resp, 422)["error"]
    assert error["code"] == "validation_failed"
    assert error["details"] == %{"isbn" => ["At least one product identifier required"]}

    refute match?(
             {:ok, _},
             Content.get_document(Content.DraftId.draft_id(doc_id), ctx.type, ctx.enforced)
           )
  end

  test "enforcing: a warning-level rule and an unevaluable rule never refuse", ctx do
    log =
      capture_log(fn ->
        {resp, _} = create(ctx, ctx.enforced, %{"isbn" => "978"})
        assert resp.status == 200, resp.resp_body

        warnings = Map.get(json_response(resp, 200), "warnings", [])

        assert Enum.any?(warnings, fn w ->
                 w["code"] == "schema_validation" and w["message"] =~ "A subtitle helps"
               end),
               "no advisory for the warning-level rule: #{inspect(warnings)}"
      end)

    assert log =~ ~s(cross_validation "ghost")
  end

  test "advising: the error-level rule is an advisory, the write lands", ctx do
    {resp, _} = create(ctx, ctx.advised, %{})

    assert resp.status == 200, resp.resp_body
    warnings = Map.get(json_response(resp, 200), "warnings", [])

    assert Enum.any?(warnings, fn w ->
             w["message"] =~ "At least one product identifier required" and
               Enum.any?(w["findings"] || [], &(&1["code"] == "cross_validation"))
           end),
           "no cross_validation advisory: #{inspect(warnings)}"
  end
end
