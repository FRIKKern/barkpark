defmodule BarkparkWeb.Studio.PaperEditor.TypedNativeFieldControlsTest do
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  @field_slug "2026-09-05-typed-native-controls"

  setup do
    blocks = [
      %{"id" => "typed-bool", "type" => "field-boolean", "label" => "Enabled", "value" => false},
      %{
        "id" => "typed-select",
        "type" => "field-select",
        "label" => "Tone",
        "value" => "info",
        "options" => [
          %{"value" => "info", "label" => "Info"},
          %{"value" => "warning", "label" => "Warning"}
        ]
      },
      %{
        "id" => "typed-datetime",
        "type" => "field-datetime",
        "label" => "When",
        "value" => "2026-09-05T10:00"
      },
      %{
        "id" => "typed-color",
        "type" => "field-color",
        "label" => "Accent",
        "value" => "#4f46e5"
      }
    ]

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @field_slug,
          dataset: @dataset,
          blocks: blocks
        })
      )

    :ok
  end

  test "typed native controls persist exact values and render them after reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    open_editor(view)

    cases = [
      {"typed-bool", "paper-field-field-boolean", true},
      {"typed-select", "paper-field-field-select", "warning"},
      {"typed-datetime", "paper-field-field-datetime", "2026-12-24T18:45"},
      {"typed-color", "paper-field-field-color", "#12ab34"}
    ]

    for {id, test_id, value} <- cases do
      bridge = element(view, ~s(#paper-fld-#{id}[phx-hook="BarkparkFieldBlockBridge"]))
      assert has_element?(view, ~s(#paper-fld-#{id} [data-test-id="#{test_id}"]))

      render_hook(bridge, "paper-op", %{
        "op" => "patch-block",
        "id" => id,
        "patch" => %{"value" => value},
        "if_rev" => current_rev(view)
      })

      assert stored_block(id)["value"] === value
    end

    {:ok, reloaded, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))

    open_editor(reloaded)

    assert has_element?(
             reloaded,
             ~s(#paper-fld-typed-bool [data-test-id="paper-field-field-boolean"][checked])
           )

    assert has_element?(
             reloaded,
             ~s(#paper-fld-typed-select option[value="warning"][selected])
           )

    assert has_element?(
             reloaded,
             ~s(#paper-fld-typed-datetime [data-test-id="paper-field-field-datetime"][value="2026-12-24T18:45"])
           )

    assert has_element?(
             reloaded,
             ~s(#paper-fld-typed-color [data-test-id="paper-field-field-color"][value="#12ab34"])
           )
  end

  defp stored_block(id) do
    @field_slug
    |> Content.paper_blocks(@dataset)
    |> Enum.find(&(&1["id"] == id))
  end

  defp current_rev(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev
end
