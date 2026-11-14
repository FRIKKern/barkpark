defmodule BarkparkWeb.Studio.DeskDarkSurfacesTest do
  @moduledoc """
  In dark, the desk's edit pane is TanStack's page colour (`--dk-bg`). The
  boxed fields (array, object, code list, localized), an array's rows and
  a chosen reference sit on it too, not on the Studio's near-black card
  (`--bg-card`, #0d0d0f). Light, and the old
  Studio, keep their colours (task-1969db8fe615e6b9).
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  defp sheet, do: rendered_to_string(BarkparkWeb.Studio.Desk.DocStyle.sheet(%{}))

  test "in dark, the boxed fields, array rows and a chosen reference take the pane colour, only inside the desk's edit pane" do
    rule =
      Regex.run(~r/([^{}]*fieldset\.bp-field-array[^{}]*)\{([^}]*)\}/, sheet(),
        capture: :all_but_first
      )

    assert [selectors, body] = rule
    assert body =~ "background: var(--dk-bg);"

    parts = selectors |> String.split(",") |> Enum.map(&String.trim/1)

    assert parts == [
             ~s(html[data-theme="dark"] .dk .dk-edit fieldset.bp-field-array),
             ~s(html[data-theme="dark"] .dk .dk-edit .bp-field-composite),
             ~s(html[data-theme="dark"] .dk .dk-edit .bp-field-codelist),
             ~s(html[data-theme="dark"] .dk .dk-edit .bp-field-localized),
             ~s(html[data-theme="dark"] .dk .dk-edit .bp-array-row),
             ~s(html[data-theme="dark"] .dk .dk-edit .ref-selected)
           ]
  end
end
