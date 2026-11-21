defmodule BarkparkWeb.MutateCrossRuleTitleTest do
  @moduledoc """
  task-57d0947d4a29a073: a cross rule whose `title` is not text (a
  per-language map) still applies, and its findings read the rule's name.
  An item rule (`each`) used to raise on every write that broke it
  (`FieldErrors.add_findings/2` and the "(N more items)" line interpolated
  the map), so no save of that document went through, advise mode included.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Validation

  @title %{"nb" => "Velg side", "en" => "Pick a page"}

  setup do
    enforced = "xvtenf_#{System.unique_integer([:positive])}"
    advised = "xvtadv_#{System.unique_integer([:positive])}"
    token = "barkpark-dev-token-xvt-#{System.unique_integer([:positive])}"
    ws = Barkpark.Tenancy.get_default_workspace()
    proj = Barkpark.Tenancy.get_default_project()

    previous = Application.get_env(:barkpark, Validation, [])
    Application.put_env(:barkpark, Validation, enforce_datasets: [enforced])
    on_exit(fn -> Application.put_env(:barkpark, Validation, previous) end)

    type = "xvtmeny_#{System.unique_integer([:positive])}"

    for dataset <- [enforced, advised] do
      Auth.create_token(token, "dev", dataset, ["read", "write", "admin"], ws.id)
      {:ok, _} = Barkpark.Tenancy.create_dataset(proj, %{slug: dataset, name: dataset})

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Meny",
            "fields" => [
              %{
                "name" => "meny",
                "type" => "arrayOf",
                "of" => %{
                  "type" => "composite",
                  "fields" => [%{"name" => "side", "type" => "string"}]
                }
              },
              %{"name" => "navn", "type" => "string"}
            ],
            "cross_validations" => [
              %{
                "name" => "side_paakrevd",
                "title" => @title,
                "level" => "error",
                "each" => "meny",
                "fields" => ["side"],
                "rule" => %{"field" => "side", "operator" => "non_empty"}
              },
              %{
                "name" => "navn_paakrevd",
                "title" => @title,
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
    end

    %{token: token, enforced: enforced, advised: advised, type: type}
  end

  # `broken` items without a side; 0 is one item that has one.
  defp meny(0), do: [%{"_key" => "ok", "side" => "s"}]
  defp meny(broken), do: for(i <- 1..broken, do: %{"_key" => "k#{i}"})

  defp create(ctx, dataset, broken, navn \\ "N") do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{dataset}",
      Jason.encode!(%{
        "mutations" => [
          %{
            "create" => %{
              "_id" => "xvt-#{System.unique_integer([:positive])}",
              "_type" => ctx.type,
              "title" => "Meny",
              "content" => %{"meny" => meny(broken), "navn" => navn}
            }
          }
        ]
      })
    )
  end

  test "enforcing: one broken item is refused with the rule's name, not a 500", ctx do
    resp = create(ctx, ctx.enforced, 1)
    assert resp.status == 422, resp.resp_body
    error = json_response(resp, 422)["error"]
    assert error["code"] == "validation_failed"
    assert error["details"] == %{"meny" => ["/meny/0/side: side_paakrevd"]}

    assert [%{"path" => "/meny/0/side", "message" => "side_paakrevd"}] =
             for(
               f <- error["findings"],
               f["code"] == "cross_validation",
               do: Map.take(f, ~w(path message))
             )
  end

  test "enforcing: 51 broken items are refused, the summary line included", ctx do
    resp = create(ctx, ctx.enforced, 51)
    assert resp.status == 422, resp.resp_body
    meny = json_response(resp, 422)["error"]["details"]["meny"]
    assert length(meny) == 51
    assert List.last(meny) == "side_paakrevd (1 more item)"
  end

  test "a plain rule with the same title reads the same way", ctx do
    resp = create(ctx, ctx.enforced, 0, "")
    assert resp.status == 422, resp.resp_body
    assert json_response(resp, 422)["error"]["details"] == %{"navn" => ["navn_paakrevd"]}
  end

  test "advising: the write lands with the item rule's advisory", ctx do
    resp = create(ctx, ctx.advised, 1)
    assert resp.status == 200, resp.resp_body
    warnings = Map.get(json_response(resp, 200), "warnings", [])

    assert Enum.any?(warnings, fn w ->
             Enum.any?(
               w["findings"] || [],
               &(&1["code"] == "cross_validation" and &1["path"] == "/meny/0/side")
             )
           end),
           "no advisory for the item rule: #{inspect(warnings)}"
  end
end
