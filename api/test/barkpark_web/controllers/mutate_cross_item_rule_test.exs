defmodule BarkparkWeb.MutateCrossItemRuleTest do
  @moduledoc """
  task-5bb338ffd4621865 on the API door: an item rule (`"each": "meny"`)
  rides the advise/enforce door like any cross rule. On an enforcing dataset
  an error-level item rule refuses the write, keyed by the list's field, and
  its finding names the broken item (`/meny/1/side`).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Validation

  setup do
    dataset = "xvitem_#{System.unique_integer([:positive])}"
    token = "barkpark-dev-token-xvi-#{System.unique_integer([:positive])}"
    ws = Barkpark.Tenancy.get_default_workspace()
    proj = Barkpark.Tenancy.get_default_project()

    previous = Application.get_env(:barkpark, Validation, [])
    Application.put_env(:barkpark, Validation, enforce_datasets: [dataset])
    on_exit(fn -> Application.put_env(:barkpark, Validation, previous) end)

    type = "xvinnst_#{System.unique_integer([:positive])}"
    Auth.create_token(token, "dev", dataset, ["read", "write", "admin"], ws.id)
    {:ok, _} = Barkpark.Tenancy.create_dataset(proj, %{slug: dataset, name: dataset})

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Innstillinger",
          "visibility" => "public",
          "fields" => [%{"name" => "meny", "type" => "array"}],
          "cross_validations" => [
            %{
              "name" => "side_eller_omrade",
              "title" => "Velg en side eller et område",
              "level" => "error",
              "each" => "meny",
              "fields" => ["side"],
              "rule" => %{
                "one" => [
                  %{"field" => "side", "operator" => "non_empty"},
                  %{"field" => "omrade", "operator" => "non_empty"}
                ]
              }
            }
          ]
        },
        dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    %{token: token, dataset: dataset, type: type}
  end

  defp create(ctx, meny) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{ctx.dataset}",
      Jason.encode!(%{
        "mutations" => [
          %{
            "create" => %{
              "_id" => "xvi-#{System.unique_integer([:positive])}",
              "_type" => ctx.type,
              "title" => "Meny",
              "content" => %{"meny" => meny}
            }
          }
        ]
      })
    )
  end

  test "enforcing: an error-level item rule refuses the write and names the broken item", ctx do
    resp = create(ctx, [%{"_key" => "a", "side" => "s"}, %{"_key" => "b"}])

    assert resp.status == 422, resp.resp_body
    error = json_response(resp, 422)["error"]
    assert error["code"] == "validation_failed"
    assert error["details"] == %{"meny" => ["Velg en side eller et område"]}

    assert [%{"path" => "/meny/1/side", "code" => "cross_validation"}] =
             Enum.filter(error["findings"] || [], &(&1["code"] == "cross_validation"))
  end

  test "enforcing: every item with exactly one of side/omrade is written", ctx do
    resp = create(ctx, [%{"_key" => "a", "side" => "s"}, %{"_key" => "b", "omrade" => "o"}])
    assert resp.status == 200, resp.resp_body
  end
end
