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

  # ── spd-w5 / charter D79 ──────────────────────────────────────────────────
  # The collapsed strip shipped with a hardcoded `aria-expanded="false"` and no
  # `aria-controls`. Measured live on the authenticated desk:
  # `document.querySelectorAll('[aria-expanded="true"]').length` was 0 across
  # the WHOLE document before and after activation, so the attribute had no
  # referent and no truth — decoration. It is structural: the strip IS the pane
  # collapsed (same id, one control in two states) and activating it DESTROYS
  # it, so no element survives to carry the true state. It is removed here, and
  # `aria-controls` names the region the control actually replaces.
  describe "pane_column/1 collapsed strip – ARIA (spd-w5)" do
    defp strip(extra \\ %{}) do
      render_component(
        &Panes.pane_column/1,
        Map.merge(
          %{
            title: "Post",
            collapsed: true,
            phx_click: "expand-pane",
            phx_value_idx: "1",
            id: "pane-post",
            inner_block: [%{inner_block: fn _, _ -> "hidden body" end}]
          },
          extra
        )
      )
    end

    test "claims no expanded state it cannot keep" do
      refute strip() =~ "aria-expanded"
    end

    test "the labelled affordances spd-s6 shipped survive the removal" do
      html = strip()

      assert html =~ ~s(<button type="button")
      assert html =~ ~s(aria-label="Back to Post")
      assert html =~ ~s(title="Back to Post")
      assert html =~ ~s(class="pane-column pane-column--collapsed")
    end

    test "aria-controls renders the caller's region id verbatim" do
      assert strip(%{controls: "studio-panes"}) =~ ~s(aria-controls="studio-panes")
    end

    test "no controls given renders no aria-controls at all (legacy call sites)" do
      # A referent that does not resolve is the decoration this replaced, so an
      # absent region must produce an absent attribute — never an empty one.
      html = strip()

      refute html =~ "aria-controls"
    end
  end

  # The other half of D79: after Enter, `document.activeElement` was BODY. The
  # strip is destroyed by its own activation, so the browser has nowhere to put
  # focus; the re-opened pane takes it via LiveView's own `phx-mounted` +
  # `JS.focus()` — declarative, not an imperative focus grab.
  describe "pane_column/1 expanded column – focus return (spd-w5)" do
    defp column(extra \\ %{}) do
      render_component(
        &Panes.pane_column/1,
        Map.merge(
          %{title: "Posts", id: "pane-posts", inner_block: [%{inner_block: fn _, _ -> "b" end}]},
          extra
        )
      )
    end

    test "focus_on_mount renders a programmatic focus target and JS.focus()" do
      html = column(%{focus_on_mount: true})

      assert html =~ ~s(tabindex="-1")
      assert html =~ "phx-mounted"
      assert html =~ "focus"
    end

    test "the default renders neither — an initial page load must not steal focus" do
      html = column()

      refute html =~ "tabindex"
      refute html =~ "phx-mounted"
    end

    test "the focus target never lands on a collapsed strip" do
      # The strip is gone by the time focus moves; only the expanded column can
      # receive it, and `focus_on_mount` must not leak into the strip branch.
      html = strip(%{focus_on_mount: true})

      refute html =~ "phx-mounted"
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

    test "selectable=true renders a REAL checkbox control with a phx-click handler" do
      html =
        render_component(&Panes.pane_doc_item/1, Map.merge(base_assigns(), %{selectable: true}))

      assert html =~ ~s(class="bp-doc-checkbox")
      assert html =~ ~s(phx-click="toggle-doc-checkbox")
      assert html =~ ~s(phx-value-id="doc-abc")
      assert html =~ ~s(data-test-id="doc-checkbox-doc-abc")

      # spd-bl-doc-checkbox-is-an-unfocusable-span: a <span phx-click> was
      # unreachable by keyboard and silent to AT. The control must be a real
      # <button role="checkbox"> with its state on aria-checked and a name
      # saying WHAT gets selected.
      [checkbox] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-test-id="doc-checkbox-doc-abc"]))
        |> Enum.to_list()

      assert LazyHTML.tag(checkbox) == ["button"],
             "the bulk-select control must be a real <button>, not a span"

      assert LazyHTML.attribute(checkbox, "role") == ["checkbox"]
      assert LazyHTML.attribute(checkbox, "aria-checked") == ["false"]
      assert LazyHTML.attribute(checkbox, "aria-label") == ["Select My Post"]
    end

    test "checked=true announces aria-checked=true on the checkbox control" do
      html =
        render_component(
          &Panes.pane_doc_item/1,
          Map.merge(base_assigns(), %{selectable: true, checked: true})
        )

      [checkbox] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-test-id="doc-checkbox-doc-abc"]))
        |> Enum.to_list()

      assert LazyHTML.attribute(checkbox, "aria-checked") == ["true"],
             "AT must hear the checked state from aria-checked, not a bare glyph"
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
