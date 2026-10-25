defmodule BarkparkWeb.MutateDeskPresetAdvisoryTest do
  @moduledoc """
  task-dc9b751450c2c2c4: saving a deskStructure whose list `initialValues`
  name no field of the list's type, or give a field a value that does not fit,
  answers 200 with an `unknown_desk_preset` advisory per entry. Warn-only: the
  save lands, and the desk leaves those entries out of the list's "+".
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "test"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    token = "desk-preset-advisory-#{System.unique_integer([:positive])}"
    Auth.create_token(token, "dev", @dataset, ["read", "write", "admin"], ws.id)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "presetpage",
          "title" => "Side",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "pageType",
              "type" => "select",
              "options" => [%{"title" => "Landing", "value" => "landingPage"}]
            }
          ]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: project.id
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

  defp preset_findings(body) do
    body
    |> Map.get("warnings", [])
    |> Enum.flat_map(&(get_in(&1, ["details", "findings"]) || &1["findings"] || []))
    |> Enum.filter(&(&1["code"] == "unknown_desk_preset"))
    |> Enum.map(& &1["path"])
    |> Enum.sort()
  end

  test "a preset that names no field, or a value that does not fit, is reported on save; a valid one is not",
       %{token: token} do
    list = fn presets ->
      %{
        "kind" => "documentTypeList",
        "type" => "presetpage",
        "title" => "L",
        "initialValues" => presets
      }
    end

    body =
      save(token, [
        list.(%{"pageType" => "landingPage"}),
        %{
          "kind" => "list",
          "title" => "Gruppe",
          "items" => [
            list.(%{"pageType" => "notAnOption", "ghost" => "x", "content.title" => "ok"})
          ]
        }
      ])

    assert preset_findings(body) == [
             "/items/1/items/0/initialValues/ghost",
             "/items/1/items/0/initialValues/pageType"
           ]

    assert preset_findings(save(token, [list.(%{"content.pageType" => "landingPage"})])) == []

    assert preset_findings(save(token, [%{"kind" => "documentTypeList", "type" => "presetpage"}])) ==
             []
  end
end
