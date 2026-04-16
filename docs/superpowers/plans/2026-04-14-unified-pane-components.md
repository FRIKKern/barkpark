# Unified Pane Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the two hand-rolled pane layouts (Structure tab's drill-down and API Tester tab's docs+playground) into one shared set of `Phoenix.Component` function components, rich enough to serve both consumers. Consumer-specific behaviour (drill-down auto-collapse, collapsible categories, verdict badges, doc items) is expressed via slots and attrs — not duplicated markup.

**Architecture:** Extend `BarkparkWeb.StudioComponents` with seven new function components: `pane_layout/1`, `pane_column/1`, `pane_section_header/1`, `pane_item/1`, `pane_doc_item/1`, `pane_divider/0`, and `pane_empty/1`. Each owns its nested HEEx structure, class wiring, and slot contract. Consumers (`ApiTesterLive` first as the simpler case, then `StudioLive` as the complex one) call the components and pass per-item concerns via `:header_actions`, `:icon`, `:trailing`, `:badge` slots and attrs like `collapsed`, `selected`, `flex`, `last`. CSS stays in `root.html.heex` (already centralized). Auto-collapse policy stays in each LiveView as a small helper that computes `collapsed={boolean}` per pane — the component only renders what it's told.

**Tech Stack:** Phoenix LiveView 1.0, `Phoenix.Component` (`attr`, `slot`, `~H`), ExUnit with `Phoenix.LiveViewTest.render_component/2`. No new deps.

**Scope note:** Migrates **two** LiveViews: `ApiTesterLive` (simpler — flat nav with collapsible categories) and `StudioLive` (complex — dynamic `@panes` loop with auto-collapse, editor column, doc items). Leaves the StudioLive editor column hand-rolled (its combined `pane-header editor-header` class wants a custom header slot that's out of scope here — TODO comment added). Does NOT touch `MediaLive` unless it turns out to already use pane-* classes (Task 8 audit). Does NOT touch the dead `DashboardLive`, `DocumentListLive`, `DocumentEditLive` files — those are separate cleanup.

**Worktree:** Create a fresh isolated worktree at `.worktrees/unified-pane-components` from `main`. Do not touch `/root/barkpark` directly during implementation.

**Golden rule:** Every task ends with `MIX_ENV=test mix test` green and `/studio/production` + `/studio/production/api-tester` returning HTTP 200 via a curl smoke.

---

## File Structure

### Modified files

| File | Change |
|---|---|
| `api/lib/barkpark_web/components/studio_components.ex` | Add 7 new function components alongside the existing `status_badge/1` and `schema_card/1`. |
| `api/lib/barkpark_web/live/studio/api_tester_live.ex` | Replace the hand-rolled pane markup in `render/1` with component calls. Keep the `collapse_categories` state + toggle handler (it becomes the `collapsed` attr on `pane_section_header`). |
| `api/lib/barkpark_web/live/studio/studio_live.ex` | Replace the pane loop in `render/1` with component calls. Replace `collapse_pane?/3` with a call to the helper that drives the `collapsed` attr. Keep `handle_event("expand-pane", ...)` and `build_list_items/1` as-is — they're data transformation, not rendering. Leave the editor column hand-rolled. |

### New test files

| File | Responsibility |
|---|---|
| `api/test/barkpark_web/components/studio_components_pane_test.exs` | Unit tests for every new component, one `describe` block per component. Uses `Phoenix.LiveViewTest.render_component/2`. |

### Files touched but behavior unchanged

`root.html.heex` (CSS already in place — `.pane-layout`, `.pane-column`, `.pane-column--collapsed`, `.pane-header`, `.pane-item`, `.pane-section-header`, `.pane-divider`, `.pane-doc-item`, `.pane-doc-title`, `.pane-doc-dot`, `.pane-doc-id`, `.pane-item-icon`, `.pane-item-label`, `.pane-item-chevron`, `.pane-column-collapsed-label`, `.empty-state` — all already exist), `barkpark_web.ex` (imports already in place), every LiveView not in the migration target list.

---

## Phase 1 — Build the component set

### Task 1: `pane_layout/1` + `pane_column/1` + `pane_empty/1`

**Files:**
- Modify: `api/lib/barkpark_web/components/studio_components.ex`
- Create: `api/test/barkpark_web/components/studio_components_pane_test.exs`

- [ ] **Step 1: Write failing tests**

Create `api/test/barkpark_web/components/studio_components_pane_test.exs`:

```elixir
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

    test "header_actions slot renders right-aligned inside the header" do
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
end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: FAIL with `pane_layout/1 is undefined` or similar.

- [ ] **Step 3: Add the three components**

Open `api/lib/barkpark_web/components/studio_components.ex` and append (above the final `end` of the module):

```elixir
  # ── Pane layout components ──────────────────────────────────────────
  #
  # Shared structural building blocks for every Studio LiveView pane.
  # See api/lib/barkpark_web/layouts/root.html.heex for the CSS that
  # powers them (.pane-layout, .pane-column, .pane-header, etc.).

  @doc """
  Flex container for one or more `<.pane_column>` children.

  ## Example

      <.pane_layout id="studio-panes">
        <.pane_column title="Endpoints">...</.pane_column>
        <.pane_column title="Docs">...</.pane_column>
      </.pane_layout>
  """
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def pane_layout(assigns) do
    ~H"""
    <div class="pane-layout" id={@id}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc """
  A single pane column with a header row and a body area.

  The body is rendered from the `:inner_block` slot; consumers decide
  whether to wrap it in an overflow-scroll container, add padding, etc.

  ## Attributes

    * `:title`     — (required) string rendered in the column header
    * `:flex`      — optional CSS flex shorthand (e.g. `"1"` or `"1.1 1 0"`).
                     When set, also clears the default 260px fixed width.
    * `:last`      — optional boolean. `true` removes the right border so
                     the last column doesn't show a double separator.
    * `:collapsed` — optional boolean. When `true`, renders a narrow
                     vertical strip showing the title rotated 90deg and
                     a right-chevron icon; the inner_block is NOT rendered.
    * `:phx_click` / `:phx_value_idx` — event wiring for the collapsed
                     strip click target. Ignored when `collapsed == false`.
    * `:id`        — optional HTML id.

  ## Slots

    * `:header_actions` — optional content rendered right-aligned in the
                          header (buttons, badges, metadata). Not rendered
                          in collapsed state.
    * `:inner_block`    — (required) column body. Ignored in collapsed state.
  """
  attr :title, :string, required: true
  attr :flex, :string, default: nil
  attr :last, :boolean, default: false
  attr :collapsed, :boolean, default: false
  attr :phx_click, :string, default: nil
  attr :phx_value_idx, :string, default: nil
  attr :id, :string, default: nil

  slot :header_actions
  slot :inner_block, required: true

  def pane_column(assigns) do
    ~H"""
    <%= if @collapsed do %>
      <div
        class="pane-column pane-column--collapsed"
        id={@id}
        phx-click={@phx_click}
        phx-value-idx={@phx_value_idx}
        title={"Back to #{@title}"}
      >
        <div class="pane-header">
          <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24"
            fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
            style="display:inline-block;vertical-align:middle;flex-shrink:0;">
            <path d="m9 18 6-6-6-6"/>
          </svg>
        </div>
        <div class="pane-column-collapsed-label"><%= @title %></div>
      </div>
    <% else %>
      <div
        class={[
          "pane-column",
          @last && "pane-column--last",
          @flex && "pane-column--flex"
        ]}
        id={@id}
        style={if @flex, do: "flex: #{@flex}; width: auto; min-width: 0;", else: nil}
      >
        <div class="pane-header">
          <span class="pane-header-title"><%= @title %></span>
          <%= if @header_actions != [] do %>
            <div class="pane-header-actions"><%= render_slot(@header_actions) %></div>
          <% end %>
        </div>
        <%= render_slot(@inner_block) %>
      </div>
    <% end %>
    """
  end

  @doc """
  Placeholder rendered inside a `<.pane_column>` when there's nothing to show.

  ## Attributes

    * `:message` — short hint displayed in the empty-state box

  ## Slots

    * `:inner_block` — optional extra content (button, link) appended below the message
  """
  attr :message, :string, required: true
  slot :inner_block

  def pane_empty(assigns) do
    ~H"""
    <div class="empty-state">
      <div class="empty-state-text"><%= @message %></div>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end
```

- [ ] **Step 4: Add the `.pane-column--last` CSS rule**

The existing `.pane-column` in `root.html.heex` already has `border-right`. Add one line immediately after it:

```bash
grep -n ".pane-column {" api/lib/barkpark_web/layouts/root.html.heex
```

Open the file and, directly after the closing `}` of the `.pane-column {` block, add:

```css
    .pane-column--last { border-right: none; }
```

Do NOT add a `.pane-column--flex` rule — the inline style from the component covers it.

- [ ] **Step 5: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: 8 tests, 0 failures (2 pane_layout + 5 pane_column + 1 pane_empty).

- [ ] **Step 6: Full suite sanity**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 56 tests (48 baseline + 8 new), 0 failures.

- [ ] **Step 7: Commit**

```bash
git add api/lib/barkpark_web/components/studio_components.ex api/lib/barkpark_web/layouts/root.html.heex api/test/barkpark_web/components/studio_components_pane_test.exs
git commit -m "feat(studio): pane_layout/pane_column/pane_empty components"
```

---

### Task 2: `pane_section_header/1` + `pane_divider/0`

**Files:**
- Modify: `api/lib/barkpark_web/components/studio_components.ex`
- Modify: `api/test/barkpark_web/components/studio_components_pane_test.exs`

- [ ] **Step 1: Add failing tests**

Append to `api/test/barkpark_web/components/studio_components_pane_test.exs` (inside the module, before the final `end`):

```elixir
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
      # Chevron is present and NOT marked collapsed (pointing down)
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
      html = render_component(&StudioComponents.pane_divider/0, %{})
      assert html =~ ~s(class="pane-divider")
    end
  end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: 4 new failures.

- [ ] **Step 3: Add the components**

In `api/lib/barkpark_web/components/studio_components.ex`, append below `pane_empty/1`:

```elixir
  @doc """
  Uppercase category heading inside a pane column. Two modes:

  * **Static** (default): renders a `<div class="pane-section-header">`
    with the inner block as the label. Non-clickable.
  * **Collapsible**: set `collapsible: true` and wire up `phx_click` +
    `phx_value_category`. Renders as a `<button>` with a rotating
    chevron on the left. Set `collapsed: true` to show the collapsed
    state (chevron rotated 0deg). The parent LiveView owns the
    collapsed state.

  ## Attributes

    * `:collapsible`        — optional boolean, default `false`
    * `:collapsed`          — optional boolean, default `false`
    * `:phx_click`          — optional event name, required when collapsible
    * `:phx_value_category` — optional category name forwarded to the handler

  ## Slots

    * `:inner_block` — (required) label content
  """
  attr :collapsible, :boolean, default: false
  attr :collapsed, :boolean, default: false
  attr :phx_click, :string, default: nil
  attr :phx_value_category, :string, default: nil

  slot :inner_block, required: true

  def pane_section_header(assigns) do
    ~H"""
    <%= if @collapsible do %>
      <button
        type="button"
        class="pane-section-header"
        phx-click={@phx_click}
        phx-value-category={@phx_value_category}
      >
        <span class={"pane-section-header-chevron #{if @collapsed, do: "collapsed"}"}>
          <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 24 24"
            fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
            style="display:inline-block;vertical-align:middle;flex-shrink:0;">
            <path d="m9 18 6-6-6-6"/>
          </svg>
        </span>
        <%= render_slot(@inner_block) %>
      </button>
    <% else %>
      <div class="pane-section-header"><%= render_slot(@inner_block) %></div>
    <% end %>
    """
  end

  @doc """
  Thin horizontal divider between groups inside a pane body. Zero attrs,
  zero slots — just a styled line.
  """
  def pane_divider(assigns) do
    ~H"""
    <div class="pane-divider"></div>
    """
  end
```

- [ ] **Step 4: Add CSS for the collapsible variant + the button reset**

In `api/lib/barkpark_web/layouts/root.html.heex`, find the existing `.pane-section-header` rule and replace/augment it. Look for the rule (around the pane-section-header line) and extend it to cover the button variant:

```css
    .pane-section-header {
      display: flex; align-items: center; gap: 6px;
      padding: 14px 14px 6px; font-size: 11px; font-weight: 600;
      color: var(--fg-dim); text-transform: uppercase; letter-spacing: 0.05em;
      background: none; border: 0; width: 100%; text-align: left;
      font-family: inherit; cursor: default;
    }
    button.pane-section-header { cursor: pointer; }
    button.pane-section-header:hover { color: var(--fg-muted); }
    .pane-section-header-chevron {
      display: inline-flex; align-items: center; justify-content: center;
      width: 10px; height: 10px;
      transition: transform 0.1s;
      transform: rotate(90deg);
    }
    .pane-section-header-chevron.collapsed { transform: rotate(0deg); }
```

The existing `.pane-section-header` rule was text-only; this version adds the button reset rules + chevron styles. Static (div) usage still renders identically — the `display: flex` adds a leading icon slot but doesn't change spacing for text-only contents.

Check the existing file first with:
```bash
grep -n "pane-section-header" api/lib/barkpark_web/layouts/root.html.heex
```

Then update the one matching rule (not the tester-specific `.api-category-*` rules in `api_tester_live.ex`).

- [ ] **Step 5: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: 12 tests (8 from Task 1 + 4 new), 0 failures.

- [ ] **Step 6: Full suite**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 60 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add api/lib/barkpark_web/components/studio_components.ex api/lib/barkpark_web/layouts/root.html.heex api/test/barkpark_web/components/studio_components_pane_test.exs
git commit -m "feat(studio): pane_section_header (collapsible) + pane_divider"
```

---

### Task 3: `pane_item/1` with icon/trailing/badge slots

**Files:**
- Modify: `api/lib/barkpark_web/components/studio_components.ex`
- Modify: `api/test/barkpark_web/components/studio_components_pane_test.exs`

- [ ] **Step 1: Failing tests**

Append to `api/test/barkpark_web/components/studio_components_pane_test.exs`:

```elixir
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
      # Uses div, not button — matches StudioLive's current pattern
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
          icon: [%{inner_block: fn _, _ -> "📄" end}]
        })

      assert html =~ ~s(class="pane-item-icon")
      assert html =~ "📄"
      # Icon appears before label in source order
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
          trailing: [%{inner_block: fn _, _ -> "›" end}]
        })

      assert html =~ ~s(class="pane-item-chevron")
      assert html =~ "›"
      label_pos = :binary.match(html, "pane-item-label") |> elem(0)
      chev_pos = :binary.match(html, "pane-item-chevron") |> elem(0)
      assert label_pos < chev_pos
    end

    test "badge slot renders right-aligned, after label, before/instead-of trailing" do
      html =
        render_component(&StudioComponents.pane_item/1, %{
          phx_click: "select",
          phx_value_id: "x",
          inner_block: [%{inner_block: fn _, _ -> "Label" end}],
          badge: [%{inner_block: fn _, _ -> ~s(<span class="badge">PASS</span>) end}]
        })

      assert html =~ ~s(<span class="badge">PASS</span>)
      label_pos = :binary.match(html, "pane-item-label") |> elem(0)
      badge_pos = :binary.match(html, "badge") |> elem(0)
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
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: 6 new failures.

- [ ] **Step 3: Add the component**

Append below `pane_divider/1` in `studio_components.ex`:

```elixir
  @doc """
  Clickable row inside a pane column.

  Renders a `<div class="pane-item">` (NOT a `<button>` — matches the
  StudioLive convention and avoids browser button-chrome overriding the
  flex layout). The `:inner_block` goes inside a `.pane-item-label`
  span; optional `:icon`, `:badge`, and `:trailing` slots fill their
  respective slots.

  ## Attributes

    * `:phx_click`    — (required) LiveView event name
    * `:phx_value_id` — (required) stable id the handler uses
    * `:selected`     — optional boolean, adds `.selected` modifier
    * `:id`           — optional HTML id

  ## Slots

    * `:inner_block` — (required) label contents (text, or markup)
    * `:icon`        — optional leading icon
    * `:badge`       — optional right-aligned inline content (verdict badge, count)
    * `:trailing`    — optional terminal element (usually a chevron-right)
                       — shown AFTER `:badge` if both are provided
  """
  attr :phx_click, :string, required: true
  attr :phx_value_id, :string, required: true
  attr :selected, :boolean, default: false
  attr :id, :string, default: nil

  slot :inner_block, required: true
  slot :icon
  slot :badge
  slot :trailing

  def pane_item(assigns) do
    ~H"""
    <div
      id={@id}
      phx-click={@phx_click}
      phx-value-id={@phx_value_id}
      class={["pane-item", @selected && "selected"]}
    >
      <%= if @icon != [] do %>
        <span class="pane-item-icon"><%= render_slot(@icon) %></span>
      <% end %>
      <span class="pane-item-label"><%= render_slot(@inner_block) %></span>
      <%= if @badge != [] do %>
        <%= render_slot(@badge) %>
      <% end %>
      <%= if @trailing != [] do %>
        <span class="pane-item-chevron"><%= render_slot(@trailing) %></span>
      <% end %>
    </div>
    """
  end
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: 18 tests, 0 failures.

- [ ] **Step 5: Full suite**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 66 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add api/lib/barkpark_web/components/studio_components.ex api/test/barkpark_web/components/studio_components_pane_test.exs
git commit -m "feat(studio): pane_item with icon/badge/trailing slots"
```

---

### Task 4: `pane_doc_item/1`

**Files:**
- Modify: `api/lib/barkpark_web/components/studio_components.ex`
- Modify: `api/test/barkpark_web/components/studio_components_pane_test.exs`

- [ ] **Step 1: Failing tests**

Append to the test file:

```elixir
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

      assert html =~ ~s(class="presence-dot-sm")
    end
  end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: 4 new failures.

- [ ] **Step 3: Add the component**

Append below `pane_item/1`:

```elixir
  @doc """
  Rich row for a document in a pane's doc-list: title + status dot +
  doc id + optional trailing content (presence dots).

  ## Attributes

    * `:phx_click`      — (required) LiveView event name
    * `:phx_value_pane` — (required) pane index forwarded to the handler
    * `:phx_value_id`   — (required) document id forwarded to the handler
    * `:title`          — (required) document title string
    * `:doc_id`         — (required) published document id string
    * `:status`         — (required) document status ("published" / "draft" / etc.)
                          used as the dot's modifier class
    * `:is_draft`       — optional boolean; when true, the dot shows
                          "draft" regardless of the `status` value
    * `:selected`       — optional boolean, adds `.selected` modifier
    * `:id`             — optional HTML id

  ## Slots

    * `:trailing` — optional right-aligned inline content (e.g. presence dots)
  """
  attr :phx_click, :string, required: true
  attr :phx_value_pane, :string, required: true
  attr :phx_value_id, :string, required: true
  attr :title, :string, required: true
  attr :doc_id, :string, required: true
  attr :status, :string, required: true
  attr :is_draft, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :id, :string, default: nil

  slot :trailing

  def pane_doc_item(assigns) do
    ~H"""
    <div
      id={@id}
      class={["pane-doc-item", @selected && "selected"]}
      phx-click={@phx_click}
      phx-value-pane={@phx_value_pane}
      phx-value-id={@phx_value_id}
    >
      <div class="pane-doc-title">
        <span class={"pane-doc-dot #{if @is_draft, do: "draft", else: @status}"}></span>
        <%= @title %>
        <%= if @trailing != [] do %>
          <%= render_slot(@trailing) %>
        <% end %>
      </div>
      <div class="pane-doc-id"><%= @doc_id %></div>
    </div>
    """
  end
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: 22 tests, 0 failures.

- [ ] **Step 5: Full suite**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 70 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add api/lib/barkpark_web/components/studio_components.ex api/test/barkpark_web/components/studio_components_pane_test.exs
git commit -m "feat(studio): pane_doc_item for rich document rows"
```

---

## Phase 2 — Migrate consumers

### Task 5: Migrate `ApiTesterLive` to the shared components

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/api_tester_live.ex`

ApiTesterLive is the simpler consumer — migrate it first so any component ergonomics issues surface before touching StudioLive.

- [ ] **Step 1: Locate the pane markup in `render/1`**

```bash
grep -n 'pane-layout\|pane-column\|pane-header\|pane-item\b\|pane-section-header\|empty-state' api/lib/barkpark_web/live/studio/api_tester_live.ex
```

Expected hits:
- `<div class="pane-layout api-tester-panes">` (line ~204)
- 3× `<div class="pane-column ..."` (nav, docs, response columns)
- 3× `<div class="pane-header">` (one per column)
- The category loop that emits `<button class="pane-section-header">` with its collapsible chevron
- The nav row `<div class="pane-item ...">`
- The `empty-state` divs for "Select an endpoint" and "No response yet"

- [ ] **Step 2: Replace the pane structure**

Open `api/lib/barkpark_web/live/studio/api_tester_live.ex`. Find the `<div class="pane-layout api-tester-panes">` block in `render/1` (opens around line 204 and closes around line 280). Replace everything up through the closing `</div>` of that wrapper with:

```heex
      <.pane_layout id="api-tester-panes">
        <.pane_column title="API">
          <div class="pane-body">
            <%= for category <- @categories do %>
              <% collapsed = MapSet.member?(@collapsed_categories, category) %>
              <.pane_section_header
                collapsible
                collapsed={collapsed}
                phx_click="toggle-category"
                phx_value_category={category}
              >
                <.icon name={category_icon(category)} size={12} /> <%= category %>
              </.pane_section_header>
              <%= unless collapsed do %>
                <%= for ep <- Enum.filter(@endpoints, &(&1.category == category)) do %>
                  <.pane_item
                    id={"api-ep-#{ep.id}"}
                    phx_click="select"
                    phx_value_id={ep.id}
                    selected={@selected_id == ep.id}
                  >
                    <:icon><.icon name={endpoint_icon(ep)} size={16} /></:icon>
                    <%= ep.label %>
                    <:badge><%= render_verdict_badge(Map.get(@last_result_by_id, ep.id)) %></:badge>
                  </.pane_item>
                <% end %>
              <% end %>
            <% end %>
          </div>
        </.pane_column>

        <.pane_column title={docs_column_title(@endpoint)} flex="1.1">
          <:header_actions>
            <%= if @endpoint && @endpoint.kind == :endpoint do %>
              <span class={"badge #{auth_badge_class(@endpoint.auth)}"}><%= @endpoint.auth %></span>
            <% end %>
          </:header_actions>
          <div class="api-col-body">
            <%= cond do %>
              <% @endpoint == nil -> %>
                <.pane_empty message="Select an endpoint on the left." />
              <% @endpoint.kind == :reference -> %>
                <%= render_reference(assigns, @endpoint.render_key) %>
              <% true -> %>
                <.endpoint_docs endpoint={@endpoint} />
                <.endpoint_playground endpoint={@endpoint} form_state={@form_state} token={@token} />
            <% end %>
          </div>
        </.pane_column>

        <.pane_column title="Response" flex="1" last>
          <:header_actions :if={@last_result}>
            <div class="api-response-meta">
              <%= render_verdict_badge(@last_result) %>
              <span class="text-xs text-dim api-response-timing">HTTP <%= @last_result.status %> · <%= @last_result.duration_ms %>ms</span>
            </div>
          </:header_actions>
          <div class="api-col-body">
            <%= if @last_result do %>
              <.response_view result={@last_result} />
            <% else %>
              <.pane_empty message="No response yet. Click Run." />
            <% end %>
          </div>
        </.pane_column>
      </.pane_layout>
```

- [ ] **Step 3: Add the `docs_column_title/1` private helper**

The new code references `docs_column_title(@endpoint)`. Add this helper above `auth_badge_class/1`:

```elixir
  defp docs_column_title(nil), do: "—"
  defp docs_column_title(%{kind: :reference, label: label}), do: label
  defp docs_column_title(%{kind: :endpoint, method: method, path_template: path}), do: "#{method} #{path}"
```

- [ ] **Step 4: Delete the now-unused custom CSS**

In the `<style>` block inside `render/1`, find and delete these rules (they duplicated what the shared components now own):

- `.api-category-toggle` and everything under it (pane_section_header's collapsible variant replaces it)
- `.api-category-chevron` rules (replaced by `.pane-section-header-chevron`)
- `.api-category-label` (replaced by the component's label span)

Keep the rules that are API-tester-specific:
- `.api-tester`, `.api-tester-header`, `.api-tester-header-left`, `.api-tester-header-right`
- `.api-token-form`, `.api-token-label`, `.api-token-input`
- `.api-tester-panes`
- `.api-col-docs`, `.api-col-response` (flex overrides)
- `.api-col-body`
- `.api-method`, `.api-method-get`, `.api-method-post`
- `.api-url`, `.api-section`, `.api-description`
- `.api-table`, `.api-inline-code`
- `.api-playground`, `.api-param-row`, `.api-param-label`, `.api-body-textarea`
- `.api-actions`, `.api-code-block`, `.api-curl-block`
- `.api-response-meta`, `.api-response-timing`, `.api-verdict-reason`
- `.badge-verdict-*`
- `.pane-item .badge` override
- `.api-runnable-note`

- [ ] **Step 5: Compile + test**

```bash
cd api && MIX_ENV=dev mix compile 2>&1 | grep -iE "error|undefined.*api_tester" | head
MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: clean compile, full suite green.

- [ ] **Step 6: Commit**

```bash
git add -u api/lib/barkpark_web/live/studio/api_tester_live.ex
git commit -m "refactor(api-tester): use shared pane_layout/pane_column/pane_section_header/pane_item components"
```

---

### Task 6: Migrate `StudioLive` to the shared components

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/studio_live.ex`

StudioLive is the complex consumer: dynamic `@panes` loop, auto-collapse, dividers, doc items, full and collapsed pane variants, `pane-add-btn` in the header, and a terminal editor column. Migrate the nav loop to components; leave the editor column hand-rolled.

- [ ] **Step 1: Find the pane markup**

```bash
grep -n '<div class="pane-layout"\|<div class="pane-column\|<div class="pane-header">\|pane-section-header\|pane-divider\|pane-doc-item\|pane-item #{' api/lib/barkpark_web/live/studio/studio_live.ex
```

Expected hits: all inside the `for {pane, idx} <- Enum.with_index(@panes)` loop in `render/1` (around lines 800–870).

- [ ] **Step 2: Replace the pane loop**

Find the `<div class="pane-layout" id="studio-panes">` block and its loop body. Replace from the opening `<div class="pane-layout"` through the closing `</div>` of the `for` loop (stop BEFORE the `<!-- Editor -->` comment — the editor column stays hand-rolled) with:

```heex
    <.pane_layout id="studio-panes">
      <% has_editor = @editor_doc != nil %>
      <% num_panes = length(@panes) %>
      <%= for {pane, idx} <- Enum.with_index(@panes) do %>
        <% collapsed = collapse_pane?(idx, num_panes, has_editor) %>
        <.pane_column
          id={"pane-#{pane.title |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "-")}"}
          title={pane.title}
          collapsed={collapsed}
          phx_click={if collapsed, do: "expand-pane", else: nil}
          phx_value_idx={if collapsed, do: "#{idx}", else: nil}
        >
          <:header_actions :if={pane[:type_name]}>
            <button
              class="pane-add-btn"
              phx-click="new-document"
              phx-value-type={pane.type_name}
            ><.icon name="plus" size={14} /></button>
          </:header_actions>

          <div class="pane-body">
            <%= for item <- pane.items do %>
              <%= case item.type do %>
                <% :divider -> %>
                  <.pane_divider />

                <% :header -> %>
                  <.pane_section_header>
                    <.icon name={item.icon} size={12} /> <%= item.title %>
                  </.pane_section_header>

                <% :doc -> %>
                  <.pane_doc_item
                    id={"doc-#{item.id}"}
                    phx_click="select"
                    phx_value_pane={"#{idx}"}
                    phx_value_id={item.id}
                    title={item.title}
                    doc_id={item.id}
                    status={item.status}
                    is_draft={item.is_draft}
                    selected={item.id == pane[:selected]}
                  >
                    <% item_presences = presences_on_doc(@presences, item.id) %>
                    <:trailing :if={item_presences != []}>
                      <%= for p <- item_presences do %>
                        <span class="presence-dot-sm" style={"background: #{p.color}"}></span>
                      <% end %>
                    </:trailing>
                  </.pane_doc_item>

                <% _ -> %>
                  <.pane_item
                    id={"item-#{item.id}"}
                    phx_click="select"
                    phx_value_id={item.id}
                    selected={item.id == pane[:selected]}
                  >
                    <:icon><.icon name={item.icon} size={16} /></:icon>
                    <%= item.title %>
                    <:trailing :if={item[:drillable]}>
                      <.icon name="chevron-right" size={14} />
                    </:trailing>
                  </.pane_item>
              <% end %>
            <% end %>
          </div>
        </.pane_column>
      <% end %>

      <!-- Editor — left hand-rolled: its header combines pane-header with
           editor-header which needs a full custom-header slot on pane_column
           to replace cleanly. Out of scope for this migration; see TODO. -->
```

**Important:** the `phx-value-pane` attr used by the `pane_doc_item` calls — make sure it's a string. HEEx coerces to string but the explicit `"#{idx}"` is safer across Elixir versions.

**Important:** the existing `select` event handler in StudioLive expects `phx-value-pane` alongside `phx-value-id`. The old `:doc` branch passed both, but the new `:_` (generic item) branch only passes `id` (the old markup also only passed `id` for generic items, via `phx-value-id={item.id}` without pane). Check whether `handle_event("select", ...)` requires pane for non-doc items:

```bash
grep -n 'handle_event("select"' api/lib/barkpark_web/live/studio/studio_live.ex
```

If the handler pattern-matches `%{"pane" => _, "id" => _}`, you need to pass `phx_value_pane={"#{idx}"}` on the generic `pane_item` too. Add it if missing.

- [ ] **Step 3: Keep the editor column as-is**

The next lines in `render/1` should be the `<%= if @editor_doc do %>` block with `<div class="editor-panel">`. **Do NOT migrate this** — it uses a combined `pane-header editor-header` class with custom contents (badge + title + presence dots) that doesn't map cleanly onto `pane_column`'s `header_actions` slot. Add a comment above the editor-panel opening div:

```elixir
<!-- TODO: editor column is hand-rolled because its header merges pane-header
     with editor-header and has presence dots, publish buttons, etc. Migrating
     it cleanly requires a custom-header slot on pane_column that fully replaces
     the default title row. See plan 2026-04-14-unified-pane-components.md. -->
```

- [ ] **Step 4: Remove the old `collapse_pane?/3` helper — WAIT, keep it**

`collapse_pane?/3` is the policy helper that decides which panes collapse. It's still needed — the component doesn't own policy, only rendering. The new call site (`collapsed={collapse_pane?(idx, num_panes, has_editor)}`) passes its return to the component.

Do NOT delete `collapse_pane?/3`. It stays where it is, unchanged.

- [ ] **Step 5: Delete the per-pane id helper inline-repeat (if any)**

If the old markup computed `pane-#{pane.title ...}` inline multiple times, extract it to a private helper:

```elixir
defp pane_dom_id(pane), do: "pane-" <> (pane.title |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "-"))
```

And call it as `id={pane_dom_id(pane)}`. If the ID is only computed once (it is — just in the new `<.pane_column id={...}>`), skip this step. Inspection first.

- [ ] **Step 6: Compile + test**

```bash
cd api && MIX_ENV=dev mix compile 2>&1 | grep -iE "error|undefined.*studio_live" | head
MIX_ENV=test mix test 2>&1 | tail -5
```

Expected: clean compile, full suite green.

If compile fails with a HEEx attribute-slot error:
- `<:trailing :if={...}>` uses the new `:if` slot attr — supported in Phoenix LiveView 1.0. If the project is on an older version, rewrite as `<:trailing>…</:trailing>` unconditionally and put the `:if` on the content inside.

- [ ] **Step 7: HTTP smoke**

Prod service on port 4000 is already running. Hit the pages:

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:4000/studio/production
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:4000/studio/production/post
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:4000/studio/production/api-tester
```

Expected: three `HTTP 200`s. If any 500, tail the journalctl for the service and trace the stack.

- [ ] **Step 8: Commit**

```bash
git add -u api/lib/barkpark_web/live/studio/studio_live.ex
git commit -m "refactor(studio): StudioLive uses shared pane_layout/pane_column/pane_item/pane_doc_item"
```

---

## Phase 3 — Audit + deploy

### Task 7: Audit `MediaLive` for pane-* markup

**Files:**
- Read-only: `api/lib/barkpark_web/live/studio/media_live.ex`
- Maybe modify if hits are found

- [ ] **Step 1: Grep**

```bash
grep -nE 'class="pane-(layout|column|header|item|section-header|body|doc-item|divider)\b' api/lib/barkpark_web/live/studio/media_live.ex
```

- [ ] **Step 2: If there are no hits**

Report "no migration needed for MediaLive" and skip Step 3. Move to Task 8.

- [ ] **Step 3: If there are hits**

Migrate each one following the same pattern as Task 5 (ApiTesterLive was the simpler example with a flat nav). Run `mix compile` and `mix test` after each file. Commit with:

```bash
git add -u api/lib/barkpark_web/live/studio/media_live.ex
git commit -m "refactor(studio): MediaLive uses shared pane_layout components"
```

---

### Task 8: Merge + deploy + browser verification

**Files:** None.

- [ ] **Step 1: Full suite**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: all green, approximately 70+ tests.

- [ ] **Step 2: Merge and push**

```bash
cd /root/barkpark && git checkout main && git merge --ff-only unified-pane-components 2>&1 | tail -5
git push origin main
```

- [ ] **Step 3: Deploy**

```bash
cd /opt/barkpark && git pull 2>&1 | tail -10
systemctl is-active barkpark
```

Expected: `[post-merge] Done. Service restarted.` and `active`.

- [ ] **Step 4: HTTP smoke**

```bash
B="http://89.167.28.206"
curl -s -o /dev/null -w "/studio/production              HTTP %{http_code}\n" "$B/studio/production"
curl -s -o /dev/null -w "/studio/production/post         HTTP %{http_code}\n" "$B/studio/production/post"
curl -s -o /dev/null -w "/studio/production/post/post-all HTTP %{http_code}\n" "$B/studio/production/post/post-all"
curl -s -o /dev/null -w "/studio/production/media        HTTP %{http_code}\n" "$B/studio/production/media"
curl -s -o /dev/null -w "/studio/production/api-tester   HTTP %{http_code}\n" "$B/studio/production/api-tester"
```

Expected: 5× `HTTP 200`.

- [ ] **Step 5: Browser sanity check**

Open the following URLs in a real browser and confirm visual parity or improvement over main:

1. `http://89.167.28.206/studio/production` — Structure nav, 1 full pane
2. Click "Post" — Post pane opens to the right, still 2 full panes
3. Click "All post" — 3rd pane opens, Structure collapses to a narrow strip on the left, rest stay full
4. Click a document — editor opens, both earlier nav panes collapse to strips, "All post" and the editor stay full
5. Click a collapsed strip — drills back to that pane, deeper state drops
6. Click `API` tab — 3-column API Tester layout renders with collapsible category sections; click a category header to collapse/expand its items
7. Click a category with results — verdict badges still appear on individual rows

- [ ] **Step 6: No commit needed if all smoke checks pass**

---

## Self-Review

**1. Spec coverage:**

- One unified set of components serving both Studio and API Tester → Tasks 1–4 ✓
- `pane_layout`, `pane_column`, `pane_item`, `pane_section_header`, `pane_divider`, `pane_doc_item`, `pane_empty` → Tasks 1–4 ✓
- Per-consumer customization via slots (`:header_actions`, `:icon`, `:badge`, `:trailing`) and attrs (`collapsed`, `selected`, `flex`, `last`) → Tasks 1–4 ✓
- Collapsible category sections (API Tester) powered by `pane_section_header` with `collapsible` + `collapsed` attrs → Task 2 ✓
- Auto-collapse policy (Studio drill-down) kept in StudioLive as `collapse_pane?/3`, fed into `pane_column` via the `collapsed` attr → Task 6 ✓
- ApiTesterLive migrated → Task 5 ✓
- StudioLive nav panes migrated → Task 6 ✓
- Editor column explicitly left hand-rolled with TODO → Task 6 Step 3 ✓
- MediaLive audited → Task 7 ✓
- Deploy + smoke → Task 8 ✓

**Gap I'm explicitly accepting:** the editor column migration stays as a TODO. A future plan can add a `:custom_header` slot to `pane_column` that fully replaces the default title row, then migrate the editor column cleanly.

**2. Placeholder scan:** No TBD / TODO / "similar to" / "handle edge cases" — every step has the code or grep command inline. Task 6 Step 5 says "skip this if only computed once (it is)" which is a verify-then-apply, not a placeholder.

**3. Type consistency:**
- `pane_layout/1` signature consistent across Tasks 1, 5, 6.
- `pane_column/1` attrs (`title`, `flex`, `last`, `collapsed`, `phx_click`, `phx_value_idx`, `id`) + slots (`header_actions`, `inner_block`) consistent across Tasks 1, 5, 6.
- `pane_section_header/1` attrs (`collapsible`, `collapsed`, `phx_click`, `phx_value_category`) consistent between Task 2 tests, implementation, Task 5 call sites (collapsible), Task 6 call sites (static).
- `pane_item/1` attrs (`phx_click`, `phx_value_id`, `selected`, `id`) + slots (`inner_block`, `icon`, `badge`, `trailing`) consistent across Tasks 3, 5, 6.
- `pane_doc_item/1` attrs (`phx_click`, `phx_value_pane`, `phx_value_id`, `title`, `doc_id`, `status`, `is_draft`, `selected`, `id`) + `trailing` slot consistent across Tasks 4 and 6.

---

## Execution

**Plan complete and saved to `docs/superpowers/plans/2026-04-14-unified-pane-components.md`.**

**Two execution options:**

1. **Subagent-Driven (recommended)** — 8 tasks, one commit each. Fresh subagent per task with spec + quality review between them. Best for keeping Task 6 (StudioLive migration) in isolation — it's the riskiest step and benefits most from a clean review cycle.

2. **Inline Execution** — run in this session with checkpoints at each task boundary.

Which approach?
