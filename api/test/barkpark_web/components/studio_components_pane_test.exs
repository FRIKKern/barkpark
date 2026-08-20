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

    test "renders no phx-hook attribute by default (inert seam — spd-s2)" do
      html =
        render_component(&StudioComponents.pane_layout/1, %{
          inner_block: [%{inner_block: fn _, _ -> "" end}]
        })

      refute html =~ "phx-hook"
    end

    test "phx_hook attr mounts the named client hook on the container (spd-s2)" do
      html =
        render_component(&StudioComponents.pane_layout/1, %{
          id: "studio-panes",
          phx_hook: "StudioWidthBucket",
          inner_block: [%{inner_block: fn _, _ -> "" end}]
        })

      assert html =~ ~s(phx-hook="StudioWidthBucket")
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

    test "the collapsed strip is a real button, not a click-wired div (spd-s6)" do
      # spd-s4 promoted this 44px strip to the desk's ONLY back affordance at
      # narrow widths. As a <div phx-click> it was unreachable by keyboard
      # (tabIndex -1, role null) and silent to a screen reader — the primary
      # navigation control of a whole viewport band, invisible to anyone not
      # using a mouse.
      html =
        render_component(&StudioComponents.pane_column/1, %{
          title: "Post",
          collapsed: true,
          phx_click: "expand-pane",
          phx_value_idx: "1",
          inner_block: [%{inner_block: fn _, _ -> "hidden body" end}]
        })

      assert html =~ ~s(<button type="button")

      # It says which pane it goes back to out loud — the hover `title` alone
      # reaches neither keyboard nor screen-reader users. (`aria-expanded` was
      # dropped here by spd-w5/D79: it never flipped and never could, because
      # activating the strip destroys it. See the panes.ex moduledoc.)
      assert html =~ ~s(aria-label="Back to Post")
      assert html =~ ~s(title="Back to Post")

      # The chevron is decoration on a labelled control, and it points the way
      # the action actually goes: LEFT (`m15 18-6-6 6-6`), not right.
      assert html =~ ~s(aria-hidden="true")
      assert html =~ ~s(<path d="m15 18-6-6 6-6">)
      refute html =~ ~s(d="m9 18 6-6-6-6")
    end

    test "the collapsed strip's class attribute is frozen byte-identical (D55)" do
      # `studio_live_width_bucket_test.exs` counts strips with an exact regex
      # INCLUDING the closing quote, and `.pane-column--collapsed` is the
      # selector root.html.heex hangs the button UA reset and the
      # :focus-visible ring off. New ATTRIBUTES are free; a new class token,
      # a reorder or a `class={...}` interpolation is not.
      html =
        render_component(&StudioComponents.pane_column/1, %{
          title: "Post",
          collapsed: true,
          last: true,
          marker_class: "bp-doc-list",
          inner_block: [%{inner_block: fn _, _ -> "" end}]
        })

      assert html =~ ~s(class="pane-column pane-column--collapsed")

      # Even `last` and `marker_class` — which DO extend the expanded column's
      # class string — leave the strip's frozen.
      refute html =~ ~s(pane-column--collapsed pane-column--last)
      refute html =~ ~s(pane-column--collapsed bp-doc-list)
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

    test "column sizing is class-only — no inline style is emitted" do
      # The retired :flex attr used to inline `flex: …; width: auto;
      # min-width: 0;`, which beat every width-bucket rule in root.html.heex.
      # Callers that need a different proportion now pass marker_class and
      # keep the declarations in their own stylesheet (.api-col-docs).
      html =
        render_component(&StudioComponents.pane_column/1, %{
          title: "Docs",
          marker_class: "api-col-docs",
          inner_block: [%{inner_block: fn _, _ -> "" end}]
        })

      assert html =~ ~s(class="pane-column api-col-docs")
      refute html =~ "style="
      refute html =~ "min-width: 0"
    end

    test "header_actions slot renders inside the header" do
      # Slot content must be safe markup (a Phoenix.HTML `{:safe, iodata}`
      # tuple or a Rendered struct) — that's what HEEx produces at real
      # call sites. A plain binary would get HTML-escaped by render_slot.
      safe_button = {:safe, ~s(<button class="pane-add-btn">+</button>)}

      html =
        render_component(&StudioComponents.pane_column/1, %{
          title: "Post",
          inner_block: [%{inner_block: fn _, _ -> "" end}],
          header_actions: [%{inner_block: fn _, _ -> safe_button end}]
        })

      assert html =~ ~s(class="pane-header-actions")
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
    test "renders as a real focusable button with label" do
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
      # A desk row is an activatable control: it must be a <button>, not a
      # <div phx-click> (which no keyboard can reach). This assertion used to
      # read `html =~ "<div"` — the written-down convention that reproduced
      # the defect in every component copied from pane_item/1.
      assert html =~ ~s(<button type="button")
      refute html =~ ~s(<div)
      # Unselected rows carry no aria-current at all.
      refute html =~ "aria-current"
    end

    test "selected=true adds the selected class and aria-current (never aria-selected)" do
      html =
        render_component(&StudioComponents.pane_item/1, %{
          phx_click: "select",
          phx_value_id: "x",
          selected: true,
          inner_block: [%{inner_block: fn _, _ -> "X" end}]
        })

      assert html =~ ~s(class="pane-item selected")
      # aria-selected is only meaningful inside a listbox/tab/grid container;
      # a standalone nav row states its selection with aria-current.
      assert html =~ ~s(aria-current="true")
      refute html =~ "aria-selected"
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

    test "phx_value_pane is forwarded when provided" do
      html =
        render_component(&StudioComponents.pane_item/1, %{
          phx_click: "select",
          phx_value_id: "x",
          phx_value_pane: "2",
          inner_block: [%{inner_block: fn _, _ -> "Label" end}]
        })

      assert html =~ ~s(phx-value-pane="2")
    end

    test "phx_value_pane is omitted when not provided" do
      html =
        render_component(&StudioComponents.pane_item/1, %{
          phx_click: "select",
          phx_value_id: "x",
          inner_block: [%{inner_block: fn _, _ -> "Label" end}]
        })

      refute html =~ ~s(phx-value-pane=")
    end
  end

  describe "pane_doc_item/1" do
    test "renders title, subtitle, hover doc-id, and status dot" do
      html =
        render_component(&StudioComponents.pane_doc_item/1, %{
          phx_click: "select",
          phx_value_pane: "1",
          phx_value_id: "p1",
          title: "Hello World",
          doc_id: "p1",
          status: "published",
          is_draft: false,
          meta: "Updated 2h ago"
        })

      assert html =~ ~s(class="pane-doc-item)
      assert html =~ ~s(class="pane-doc-title")
      # sup-w2: the second line is a real subtitle (:meta), not a mono doc id.
      assert html =~ ~s(class="pane-doc-sub")
      assert html =~ "Updated 2h ago"
      refute html =~ ~s(class="pane-doc-id")
      # the raw doc id is demoted to a hover title= tooltip on the row body.
      assert html =~ ~s(title="p1")
      assert html =~ ~s(class="pane-doc-dot published")
      assert html =~ "Hello World"
      assert html =~ ~s(phx-click="select")
      assert html =~ ~s(phx-value-pane="1")
      assert html =~ ~s(phx-value-id="p1")
    end

    test "the row body is a button whose accessible name comes from the title, not the doc id" do
      html =
        render_component(&StudioComponents.pane_doc_item/1, %{
          phx_click: "select",
          phx_value_pane: "1",
          phx_value_id: "drafts.paper-7780f97",
          title: "Hello World",
          doc_id: "drafts.paper-7780f97",
          status: "published",
          is_draft: true,
          badge: "In progress",
          meta: "Updated 2h ago"
        })

      # The activatable control is a real <button>, so a keyboard can reach it.
      assert html =~ ~s(<button type="button" class="bp-doc-row-body")
      # title= is the accname fallback of LAST resort: without an explicit
      # label, this button would announce the raw draft id. Composed, so the
      # dot / badge / subtitle a sighted reader gets are spoken too.
      assert html =~ ~s(aria-label="Hello World, draft, In progress, Updated 2h ago")
      # and the raw id survives only as the sighted tooltip.
      assert html =~ ~s(title="drafts.paper-7780f97")
      # button content is phrasing content — the three inner divs are spans.
      assert html =~ ~s(<span class="pane-doc-main">)
      assert html =~ ~s(<span class="pane-doc-title">)
      assert html =~ ~s(<span class="pane-doc-sub">)
      # the OUTER row stays a div: it hosts the bulk-publish checkbox as a
      # sibling, and a button may not contain a button. Asserted on the
      # ROOT element, not with a `=~ "<div"` anywhere-match — the anywhere
      # form is the shape of the stale assertion this diff deletes, and it
      # would stay green if the outer row became a <button> tomorrow.
      assert html |> String.trim_leading() |> String.starts_with?("<div"),
             "the outer .pane-doc-item must stay a div (it hosts the checkbox " <>
               "as a sibling); got: #{html |> String.trim_leading() |> String.slice(0, 60)}"
    end

    test "selected doc row states selection with aria-current, never aria-selected" do
      html =
        render_component(&StudioComponents.pane_doc_item/1, %{
          phx_click: "select",
          phx_value_pane: "1",
          phx_value_id: "p1",
          title: "Hello",
          doc_id: "p1",
          status: "published",
          selected: true
        })

      assert html =~ ~s(aria-current="true")
      refute html =~ "aria-selected"
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
