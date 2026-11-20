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
          "fields" => [
            %{
              "name" => "meny",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "fields" => [
                  %{
                    "name" => "tittel",
                    "type" => "string",
                    "validation" => %{"required" => true}
                  },
                  %{"name" => "side", "type" => "string"},
                  %{"name" => "omrade", "type" => "string"}
                ]
              }
            },
            %{"name" => "navn", "type" => "string"}
          ],
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
            },
            %{
              "name" => "navn_paakrevd",
              "title" => "Navn mangler",
              "level" => "error",
              "fields" => ["navn"],
              "rule" => %{"field" => "navn", "operator" => "non_empty"}
            }
          ]
        },
        dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    %{token: token, dataset: dataset, type: type}
  end

  defp create(ctx, meny, navn \\ "N") do
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
              "content" => %{"meny" => meny, "navn" => navn}
            }
          }
        ]
      })
    )
  end

  test "enforcing: an error-level item rule refuses the write and names the broken item", ctx do
    resp =
      create(
        ctx,
        [%{"_key" => "a", "side" => "s", "tittel" => "A"}, %{"_key" => "b", "tittel" => "B"}],
        ""
      )

    assert resp.status == 422, resp.resp_body
    error = json_response(resp, 422)["error"]
    assert error["code"] == "validation_failed"

    # The legacy map: an item finding carries its path, as an array validation message does;
    # a plain rule's message is as before (no path).
    assert error["details"] == %{
             "meny" => ["/meny/1/side: Velg en side eller et område"],
             "navn" => ["Navn mangler"]
           }

    assert ["/meny/1/side", "/navn"] =
             for(f <- error["findings"] || [], f["code"] == "cross_validation", do: f["path"])
  end

  test "enforcing: every item with exactly one of side/omrade is written", ctx do
    resp =
      create(ctx, [
        %{"_key" => "a", "side" => "s", "tittel" => "A"},
        %{"_key" => "b", "omrade" => "o", "tittel" => "B"}
      ])

    assert resp.status == 200, resp.resp_body
  end

  test "the legacy errors map keeps its order: field validation first, then cross findings in order",
       ctx do
    resp =
      create(ctx, [%{"_key" => "a"}, %{"_key" => "b", "tittel" => "B"}, %{"_key" => "c"}], "N")

    assert resp.status == 422, resp.resp_body

    assert json_response(resp, 422)["error"]["details"] == %{
             "meny" => [
               "/meny/0/tittel: Required",
               "/meny/2/tittel: Required",
               "/meny/0/side: Velg en side eller et område",
               "/meny/1/side: Velg en side eller et område",
               "/meny/2/side: Velg en side eller et område"
             ]
           }
  end

  test "enforcing: thousands of broken items refuse fast, with a bounded answer", ctx do
    {us, resp} =
      :timer.tc(fn ->
        create(ctx, for(i <- 1..3000, do: %{"_key" => "k#{i}", "tittel" => "T"}), "N")
      end)

    assert resp.status == 422
    error = json_response(resp, 422)["error"]
    assert length(error["details"]["meny"]) == 51

    assert List.last(error["details"]["meny"]) ==
             "Velg en side eller et område (2950 more items)"

    assert length(Enum.filter(error["findings"], &(&1["code"] == "cross_validation"))) == 51
    assert us < 10_000_000, "3000 items took #{us} µs"
  end
end
