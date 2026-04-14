defmodule BarkparkWeb.StudioComponentsPaneTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias BarkparkWeb.StudioComponents

  describe "pane_layout/1" do
    test "wraps inner block in .pane-layout container" do
      html =
        render_component(&StudioComponents.pane_layout/1, %{
          inner_block: [%{inner_block: fn _, _ -> "body" end}]
        })

      assert html =~ ~s(class="pane-layout")
      assert html =~ "body"
    end

    test "applies optional id attr" do
      html =
        render_component(&StudioComponents.pane_layout/1, %{
          id: "studio-panes",
          inner_block: [%{inner_block: fn _, _ -> "" end}]
        })

      assert html =~ ~s(id="studio-panes")
    end
  end

  describe "pane_column/1" do
    test "renders header title and inner block" do
      html =
        render_component(&StudioComponents.pane_column/1, %{
          title: "Endpoints",
          inner_block: [%{inner_block: fn _, _ -> "body content" end}]
        })

      assert html =~ ~s(class="pane-column")
      assert html =~ ~s(class="pane-header")
      assert html =~ ~s(class="pane-header-title")
      assert html =~ "Endpoints"
      assert html =~ "body content"
    end

    test "collapsed=true renders a vertical strip instead of full body" do
      html =
        render_component(&StudioComponents.pane_column/1, %{
          title: "Post",
          collapsed: true,
          phx_click: "expand-pane",
          phx_value_idx: "1",
          inner_block: [%{inner_block: fn _, _ -> "hidden body" end}]
        })

      assert html =~ "pane-column--collapsed"
      assert html =~ ~s(phx-click="expand-pane")
      assert html =~ ~s(phx-value-idx="1")
      assert html =~ ~s(class="pane-column-collapsed-label")
      assert html =~ "Post"
      refute html =~ "hidden body"
    end

    test "last=true adds the trailing-border-removal modifier" do
      html =
        render_component(&StudioComponents.pane_column/1, %{
          title: "Response",
          last: true,
          inner_block: [%{inner_block: fn _, _ -> "" end}]
        })

      assert html =~ "pane-column--last"
    end

    test "flex attr adds inline style and width override" do
      html =
        render_component(&StudioComponents.pane_column/1, %{
          title: "Docs",
          flex: "1.1",
          inner_block: [%{inner_block: fn _, _ -> "" end}]
        })

      assert html =~ "flex: 1.1"
      assert html =~ "width: auto"
    end

    test "header_actions slot renders inside the header" do
      html =
        render_component(&StudioComponents.pane_column/1, %{
          title: "Post",
          inner_block: [%{inner_block: fn _, _ -> "" end}],
          header_actions: [%{inner_block: fn _, _ -> ~s(<button class="pane-add-btn">+</button>) end}]
        })

      assert html =~ ~s(<button class="pane-add-btn">+</button>)
    end
  end

  describe "pane_empty/1" do
    test "renders message inside .empty-state" do
      html =
        render_component(&StudioComponents.pane_empty/1, %{
          message: "Nothing selected",
          inner_block: [%{inner_block: fn _, _ -> "" end}]
        })

      assert html =~ ~s(class="empty-state")
      assert html =~ "Nothing selected"
    end
  end

  describe "pane_section_header/1" do
    test "renders label in a .pane-section-header div" do
      html =
        render_component(&StudioComponents.pane_section_header/1, %{
          inner_block: [%{inner_block: fn _, _ -> "Query" end}]
        })

      assert html =~ ~s(class="pane-section-header")
      assert html =~ "Query"
      refute html =~ "button"
    end

    test "collapsible=true renders as a button with a rotating chevron" do
      html =
        render_component(&StudioComponents.pane_section_header/1, %{
          collapsible: true,
          collapsed: false,
          phx_click: "toggle-category",
          phx_value_category: "Query",
          inner_block: [%{inner_block: fn _, _ -> "Query" end}]
        })

      assert html =~ ~s(phx-click="toggle-category")
      assert html =~ ~s(phx-value-category="Query")
      assert html =~ "pane-section-header"
      assert html =~ "pane-section-header-chevron"
      refute html =~ "pane-section-header-chevron collapsed"
    end

    test "collapsible=true + collapsed=true flags the chevron as collapsed" do
      html =
        render_component(&StudioComponents.pane_section_header/1, %{
          collapsible: true,
          collapsed: true,
          phx_click: "toggle-category",
          phx_value_category: "Query",
          inner_block: [%{inner_block: fn _, _ -> "Query" end}]
        })

      assert html =~ "pane-section-header-chevron collapsed"
    end
  end

  describe "pane_divider/0" do
    test "renders an empty .pane-divider" do
      html = render_component(&StudioComponents.pane_divider/1, %{})
      assert html =~ ~s(class="pane-divider")
    end
  end
end
