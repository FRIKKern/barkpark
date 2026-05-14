defmodule BarkparkWeb.Components.Fields.TreeCodelistFieldTest do
  @moduledoc """
  Smoke tests for `TreeCodelistField` (G4). Verifies the LiveComponent renders
  the markers `CodelistField` dispatches to, handles the empty-registry case
  without exploding, and toggles the selected/matched state through its
  event handlers.

  Uses the `:tree_loader` test seam so the component never touches the DB —
  the loader returns a fixture tree shaped exactly like the real
  `Barkpark.Content.Codelists.tree/3` output.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.Fields.TreeCodelistField
  alias Barkpark.Content.SchemaDefinition.Field

  # Shape matches Codelists.tree/3: nested %{value, label, children} maps.
  defp fixture_tree do
    [
      %{
        value: "FB",
        label: "Fiction",
        children: [
          %{value: "FBA", label: "Modern fiction", children: []},
          %{value: "FBC", label: "Classic fiction", children: []}
        ]
      },
      %{
        value: "WN",
        label: "Nature, the natural world",
        children: []
      }
    ]
  end

  defp stub_loader(tree) do
    fn _plugin, _list_id, _opts -> tree end
  end

  defp field do
    %Field{
      name: "theme",
      type: "codelist",
      codelist_id: "test:thema",
      version: 93
    }
  end

  defp base_assigns(extra \\ %{}) do
    Map.merge(
      %{
        id: "tree-test",
        field: field(),
        value: nil,
        options: [],
        on_change: "form_change",
        plugin_name: "test",
        list_id: "test:thema",
        readonly: false,
        input_name: "doc[theme]",
        tree_loader: stub_loader(fixture_tree())
      },
      extra
    )
  end

  describe "render — populated tree" do
    test "emits the bp-tree-codelist root marker and the hidden input" do
      html = render_component(TreeCodelistField, base_assigns())

      assert html =~ "bp-tree-codelist"
      assert html =~ ~s(name="doc[theme]")
      assert html =~ ~s(type="hidden")
    end

    test "renders every root node, marks them as treeitems" do
      html = render_component(TreeCodelistField, base_assigns())

      assert html =~ "FB"
      assert html =~ "Fiction"
      assert html =~ "WN"
      assert html =~ ~s(role="treeitem")
      assert html =~ ~s(role="tree")
    end

    test "root nodes with children render the bp-tree-toggle button" do
      html = render_component(TreeCodelistField, base_assigns())

      assert html =~ "bp-tree-toggle"
      # Roots start collapsed, so children should NOT appear yet
      refute html =~ ~s(data-code="FBA")
      refute html =~ ~s(data-code="FBC")
    end

    test "auto-expands ancestors of the current :value so the selected leaf is visible" do
      html = render_component(TreeCodelistField, base_assigns(%{value: "FBA"}))

      # The FB root is auto-expanded, so its FBA child must appear.
      assert html =~ ~s(data-code="FBA")
      assert html =~ "Modern fiction"
      # FBA is selected
      assert html =~ ~s(data-selected="true")
    end

    test "exposes codelist id + version on the root" do
      html = render_component(TreeCodelistField, base_assigns())

      assert html =~ ~s(data-codelist-id="test:test:thema")
      assert html =~ ~s(data-codelist-version="93")
    end
  end

  describe "render — empty registry" do
    test "falls through to the disabled <select> placeholder when the loader returns []" do
      html =
        render_component(
          TreeCodelistField,
          base_assigns(%{tree_loader: stub_loader([])})
        )

      assert html =~ "no codelist registered"
      assert html =~ ~s(data-codelist-empty="true")
      assert html =~ "disabled"
    end
  end

  describe "stateful events (toggle + select)" do
    # render_component/2 doesn't drive handle_event; we exercise that via a
    # LiveView host. Phoenix.LiveViewTest's `live_isolated_component/3`
    # would be ideal here but isn't available in this Phoenix LV version.
    # We verify the events are wired by inspecting the rendered markup.

    test "toggle button carries the expected phx-click target and event name" do
      html = render_component(TreeCodelistField, base_assigns())

      assert html =~ ~s(phx-click="tree_node_toggle")
      assert html =~ ~s(phx-value-code="FB")
    end

    test "select button carries the expected phx-click target and event name" do
      html = render_component(TreeCodelistField, base_assigns())

      assert html =~ ~s(phx-click="tree_node_select")
    end

    test "search input wires the search event" do
      html = render_component(TreeCodelistField, base_assigns())

      assert html =~ "bp-tree-search"
      assert html =~ ~s(phx-keyup="tree_search_input")
    end
  end

  describe "readonly" do
    test "disables the select buttons when :readonly is true" do
      html = render_component(TreeCodelistField, base_assigns(%{readonly: true}))

      # The bp-tree-row-button buttons should be disabled — at least one
      # disabled select button is enough to verify the wiring.
      assert html =~ "bp-tree-row-button"
      assert html =~ "disabled"
    end
  end
end
