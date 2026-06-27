defmodule BarkparkWeb.StudioComponents.PanesTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias BarkparkWeb.StudioComponents.Panes

  describe "status_badge/1" do
    test "renders a span with status class and text" do
      html = render_component(&Panes.status_badge/1, %{status: "published"})

      assert html =~ ~s(class="status status-published")
      assert html =~ ~s(class="status-dot")
      assert html =~ "published"
    end

    test "reflects the status string in both the class modifier and the label" do
      html = render_component(&Panes.status_badge/1, %{status: "draft"})

      assert html =~ ~s(class="status status-draft")
      assert html =~ "draft"
      refute html =~ "status-published"
    end
  end

  describe "pane_doc_item/1 – selectable / checked (bulk-publish feature)" do
    defp base_assigns do
      %{
        phx_click: "select",
        phx_value_pane: "1",
        phx_value_id: "doc-abc",
        title: "My Post",
        doc_id: "doc-abc",
        status: "published",
        is_draft: false
      }
    end

    test "selectable=false (default) renders no checkbox" do
      html = render_component(&Panes.pane_doc_item/1, base_assigns())

      refute html =~ "bp-doc-checkbox"
      refute html =~ "toggle-doc-checkbox"
    end

    test "selectable=true renders a checkbox span with a phx-click handler" do
      html =
        render_component(&Panes.pane_doc_item/1, Map.merge(base_assigns(), %{selectable: true}))

      assert html =~ ~s(class="bp-doc-checkbox")
      assert html =~ ~s(phx-click="toggle-doc-checkbox")
      assert html =~ ~s(phx-value-id="doc-abc")
      assert html =~ ~s(data-test-id="doc-checkbox-doc-abc")
    end

    test "checked=true adds is-bulk-checked class and renders ✓ inside the checkbox" do
      html =
        render_component(
          &Panes.pane_doc_item/1,
          Map.merge(base_assigns(), %{selectable: true, checked: true})
        )

      assert html =~ "is-bulk-checked"
      assert html =~ "is-checked"
      assert html =~ "✓"
    end

    test "checked=false (default) does not mark row or box as checked" do
      html =
        render_component(
          &Panes.pane_doc_item/1,
          Map.merge(base_assigns(), %{selectable: true, checked: false})
        )

      refute html =~ "is-bulk-checked"
      refute html =~ "is-checked"
      refute html =~ "✓"
    end

    test "badge attr produces a pill with a slugified modifier class" do
      html =
        render_component(
          &Panes.pane_doc_item/1,
          Map.merge(base_assigns(), %{badge: "In Progress"})
        )

      assert html =~ ~s(pane-doc-badge pane-doc-badge--in-progress)
      assert html =~ "In Progress"
    end

    test "badge attr with special chars slugifies correctly" do
      html =
        render_component(
          &Panes.pane_doc_item/1,
          Map.merge(base_assigns(), %{badge: "NEW_STATUS!"})
        )

      assert html =~ "pane-doc-badge--new-status"
    end
  end
end
