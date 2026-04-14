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

  describe "pane_item/1" do
    test "renders as a clickable div with label" do
      html =
        render_component(&StudioComponents.pane_item/1, %{
          phx_click: "select",
          phx_value_id: "query-list",
          inner_block: [%{inner_block: fn _, _ -> "List documents" end}]
        })

      assert html =~ ~s(phx-click="select")
      assert html =~ ~s(phx-value-id="query-list")
      assert html =~ ~s(class="pane-item)
      assert html =~ ~s(class="pane-item-label")
      assert html =~ "List documents"
      refute html =~ "selected"
      assert html =~ ~s(<div)
    end

    test "selected=true adds the selected class" do
      html =
        render_component(&StudioComponents.pane_item/1, %{
          phx_click: "select",
          phx_value_id: "x",
          selected: true,
          inner_block: [%{inner_block: fn _, _ -> "X" end}]
        })

      assert html =~ ~s(class="pane-item selected")
    end

    test "icon slot renders in a leading .pane-item-icon span" do
      html =
        render_component(&StudioComponents.pane_item/1, %{
          phx_click: "select",
          phx_value_id: "x",
          inner_block: [%{inner_block: fn _, _ -> "Label" end}],
          icon: [%{inner_block: fn _, _ -> "ICON" end}]
        })

      assert html =~ ~s(class="pane-item-icon")
      assert html =~ "ICON"
      icon_pos = :binary.match(html, "pane-item-icon") |> elem(0)
      label_pos = :binary.match(html, "pane-item-label") |> elem(0)
      assert icon_pos < label_pos
    end

    test "trailing slot renders in .pane-item-chevron after the label" do
      html =
        render_component(&StudioComponents.pane_item/1, %{
          phx_click: "select",
          phx_value_id: "x",
          inner_block: [%{inner_block: fn _, _ -> "Label" end}],
          trailing: [%{inner_block: fn _, _ -> "CHEV" end}]
        })

      assert html =~ ~s(class="pane-item-chevron")
      assert html =~ "CHEV"
      label_pos = :binary.match(html, "pane-item-label") |> elem(0)
      chev_pos = :binary.match(html, "pane-item-chevron") |> elem(0)
      assert label_pos < chev_pos
    end

    test "badge slot renders right-aligned, after label" do
      html =
        render_component(&StudioComponents.pane_item/1, %{
          phx_click: "select",
          phx_value_id: "x",
          inner_block: [%{inner_block: fn _, _ -> "Label" end}],
          badge: [%{inner_block: fn _, _ -> "BADGE" end}]
        })

      assert html =~ "BADGE"
      label_pos = :binary.match(html, "pane-item-label") |> elem(0)
      badge_pos = :binary.match(html, "BADGE") |> elem(0)
      assert label_pos < badge_pos
    end

    test "id attr is forwarded to the rendered element" do
      html =
        render_component(&StudioComponents.pane_item/1, %{
          phx_click: "select",
          phx_value_id: "x",
          id: "item-x",
          inner_block: [%{inner_block: fn _, _ -> "Label" end}]
        })

      assert html =~ ~s(id="item-x")
    end
  end

  describe "pane_doc_item/1" do
    test "renders title, id, and status dot" do
      html =
        render_component(&StudioComponents.pane_doc_item/1, %{
          phx_click: "select",
          phx_value_pane: "1",
          phx_value_id: "p1",
          title: "Hello World",
          doc_id: "p1",
          status: "published",
          is_draft: false
        })

      assert html =~ ~s(class="pane-doc-item)
      assert html =~ ~s(class="pane-doc-title")
      assert html =~ ~s(class="pane-doc-id")
      assert html =~ ~s(class="pane-doc-dot published")
      assert html =~ "Hello World"
      assert html =~ "p1"
      assert html =~ ~s(phx-click="select")
      assert html =~ ~s(phx-value-pane="1")
      assert html =~ ~s(phx-value-id="p1")
    end

    test "is_draft=true overrides the status dot class to draft" do
      html =
        render_component(&StudioComponents.pane_doc_item/1, %{
          phx_click: "select",
          phx_value_pane: "0",
          phx_value_id: "p1",
          title: "Hello",
          doc_id: "p1",
          status: "published",
          is_draft: true
        })

      assert html =~ ~s(class="pane-doc-dot draft")
      refute html =~ ~s(class="pane-doc-dot published")
    end

    test "selected=true adds selected modifier" do
      html =
        render_component(&StudioComponents.pane_doc_item/1, %{
          phx_click: "select",
          phx_value_pane: "1",
          phx_value_id: "p1",
          title: "Hello",
          doc_id: "p1",
          status: "published",
          is_draft: false,
          selected: true
        })

      assert html =~ ~s(class="pane-doc-item selected")
    end

    test "trailing slot allows presence dots or other inline content" do
      html =
        render_component(&StudioComponents.pane_doc_item/1, %{
          phx_click: "select",
          phx_value_pane: "1",
          phx_value_id: "p1",
          title: "Hello",
          doc_id: "p1",
          status: "published",
          is_draft: false,
          trailing: [%{inner_block: fn _, _ -> ~s(<span class="presence-dot-sm"></span>) end}]
        })

      assert html =~ "presence-dot-sm"
    end
  end
end
