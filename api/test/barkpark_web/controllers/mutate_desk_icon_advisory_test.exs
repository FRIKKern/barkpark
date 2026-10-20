defmodule BarkparkWeb.MutateDeskIconAdvisoryTest do
  @moduledoc """
  task-af038d8b0d769e82: saving a deskStructure document that names an icon
  neither Studio draws answers 200 with an advisory naming the item and icon.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @dataset "test"

  setup do
    token = "desk-icon-advisory-#{System.unique_integer([:positive])}"

    Auth.create_token(
      token,
      "dev",
      @dataset,
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    %{token: token}
  end

  defp save(token, items) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{
        "mutations" => [
          %{
            "createOrReplace" => %{
              "_id" => "deskStructure",
              "_type" => "deskStructure",
              "items" => items
            }
          }
        ]
      })
    )
    |> json_response(200)
  end

  defp desk_findings(body) do
    body
    |> Map.get("warnings", [])
    |> Enum.flat_map(&(get_in(&1, ["details", "findings"]) || &1["findings"] || []))
    |> Enum.filter(&(&1["code"] == "unknown_desk_icon"))
  end

  test "an unknown desk icon is reported on save; known ones are not", %{token: token} do
    body =
      save(token, [
        %{"title" => "Books", "icon" => "book"},
        %{"title" => "Odd", "icon" => "no-such-icon"}
      ])

    findings = desk_findings(body)
    assert length(findings) == 1, inspect(body["warnings"])
    assert hd(findings)["path"] == "/items/1/icon"

    assert desk_findings(save(token, [%{"title" => "Tags", "icon" => "tags"}])) == []
  end
end
