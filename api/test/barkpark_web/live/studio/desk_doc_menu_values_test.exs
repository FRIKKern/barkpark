defmodule BarkparkWeb.Studio.Desk.DocMenuValuesTest do
  @moduledoc """
  A document menu item sends its values as `phx-value-*` attributes. The two
  keys the menu itself writes (`name`, `mode`) each have their attribute; no
  atom is made from a key (Sobelow DOS.BinToAtom, main's Security gate), so
  another key draws nothing. Pure: renders the component to a string.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BarkparkWeb.Studio.Desk.DocMenu

  defp menu(items),
    do: render_component(&DocMenu.menu/1, id: "desk-pane-2-actions", items: items, place: :header)

  test "name and mode are sent as phx-value-name and phx-value-mode" do
    html =
      menu([
        %{label: "Run", name: "run", event: "schema_action", values: %{"name" => "run"}},
        %{
          label: "Beta",
          name: "editor-set-mode",
          event: "editor-set-mode",
          values: %{"mode" => "beta"}
        }
      ])

    assert html =~ ~s(phx-value-name="run")
    assert html =~ ~s(phx-value-mode="beta")
  end

  test "a key the menu does not write draws no attribute and makes no atom" do
    key = "zz#{System.unique_integer([:positive])}"

    html = menu([%{label: "Odd", name: "odd", event: "odd", values: %{key => "v"}}])

    refute html =~ "phx-value-#{key}"
    assert_raise ArgumentError, fn -> String.to_existing_atom("phx-value-#{key}") end
  end
end
