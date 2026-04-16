# Pane Components Extraction Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the hand-rolled `.pane-layout` / `.pane-column` / `.pane-header` / `.pane-item` markup that's copy-pasted across every Studio LiveView into a small set of `Phoenix.Component` function components in `BarkparkWeb.StudioComponents`, so every pane uses the exact same structure and typos/shape drift become compile-time errors.

**Architecture:** Extend the existing `BarkparkWeb.StudioComponents` module (already auto-imported via `html_helpers/0` in `barkpark_web.ex`) with five new function components: `pane_layout/1`, `pane_column/1`, `pane_item/1`, `pane_section_header/1`, and `pane_empty/1`. Each uses `attr` for compile-time attribute checking and named slots (`:header_actions`, `:badge`) for per-consumer variation. CSS stays in `root.html.heex` — components only own the HEEx structure and attribute contract. Consumers (`ApiTesterLive` first, then `StudioLive`) are refactored to call `<.pane_column title="...">` instead of writing the nested div/span tree by hand.

**Tech Stack:** Phoenix LiveView 1.0, `Phoenix.Component` (`attr`, `slot`, `~H`), ExUnit with `Phoenix.LiveViewTest.render_component/2`. No new deps.

**Scope note:** This plan extracts **structural pane components only**. It does NOT refactor `.btn` / `.form-input` / `.badge` / `.h2` — those are single-class atoms where a component wrapper costs more than it saves. It does NOT touch `DashboardLive`, `DocumentListLive`, `DocumentEditLive`, or `MediaLive` unless one of them already uses the pane-* markup (Task 4 audits and decides). The plan's output is: working components + two consumers migrated + one audit report.

**Worktree:** Create a fresh isolated worktree at `.worktrees/pane-components` from `main`.

**Golden rule:** After every task, `MIX_ENV=test mix test` must stay green AND `mix compile` must stay warning-free for the components module (pre-existing warnings in other files are OK).

---

## File Structure

### Modified files

| File | Change |
|---|---|
| `api/lib/barkpark_web/components/studio_components.ex` | Add 5 new function components. Existing `status_badge` and `schema_card` stay untouched. |
| `api/lib/barkpark_web/live/studio/api_tester_live.ex` | Replace hand-rolled `<div class="pane-layout">…</div>` tree in `render/1` with `<.pane_layout><.pane_column>…</.pane_column></.pane_layout>`. Behaviour unchanged. |
| `api/lib/barkpark_web/live/studio/studio_live.ex` | Replace hand-rolled pane markup in `render/1` with the new components. This is the most complex migration — StudioLive has ~8 pane_columns with a mix of list panes and an editor pane. |

### New test files

| File | Responsibility |
|---|---|
| `api/test/barkpark_web/components/studio_components_pane_test.exs` | Render each of the 5 new components via `Phoenix.LiveViewTest.render_component/2` and assert on the emitted HTML. |

### Files touched but behavior unchanged

`root.html.heex` (CSS already in place from this morning), `barkpark_web.ex` (imports already in place — `StudioComponents` is already in `html_helpers/0`), all other LiveViews not in the migration target list.

---

## Phase 1 — Components

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

  test "pane_layout wraps inner block in .pane-layout div" do
    html =
      render_component(&StudioComponents.pane_layout/1, %{
        inner_block: [%{inner_block: fn _, _ -> "hello" end}]
      })

    assert html =~ ~s(<div class="pane-layout">)
    assert html =~ "hello"
  end

  test "pane_column renders header title and inner block" do
    html =
      render_component(&StudioComponents.pane_column/1, %{
        title: "Endpoints",
        inner_block: [%{inner_block: fn _, _ -> "body content" end}]
      })

    assert html =~ ~s(class="pane-column)
    assert html =~ ~s(class="pane-header")
    assert html =~ ~s(class="pane-header-title")
    assert html =~ "Endpoints"
    assert html =~ "body content"
  end

  test "pane_column last=true drops the trailing border-right" do
    html =
      render_component(&StudioComponents.pane_column/1, %{
        title: "Response",
        last: true,
        inner_block: [%{inner_block: fn _, _ -> "" end}]
      })

    assert html =~ "pane-column--last"
  end

  test "pane_column with a flex attr applies an inline flex style" do
    html =
      render_component(&StudioComponents.pane_column/1, %{
        title: "Docs",
        flex: "1.1",
        inner_block: [%{inner_block: fn _, _ -> "" end}]
      })

    assert html =~ "flex: 1.1"
  end

  test "pane_empty renders message inside .empty-state" do
    html =
      render_component(&StudioComponents.pane_empty/1, %{
        message: "Nothing selected",
        inner_block: [%{inner_block: fn _, _ -> "" end}]
      })

    assert html =~ ~s(class="empty-state")
    assert html =~ "Nothing selected"
  end
end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: FAIL with `pane_layout/1 undefined` or similar.

- [ ] **Step 3: Add the three components to `StudioComponents`**

Open `api/lib/barkpark_web/components/studio_components.ex` and add at the bottom of the module (above the final `end`):

```elixir
  # ── Pane layout components ──────────────────────────────────────────
  #
  # Shared structural building blocks for every Studio LiveView pane.
  # See api/lib/barkpark_web/layouts/root.html.heex for the CSS that
  # powers them (.pane-layout, .pane-column, .pane-header, etc.).

  @doc """
  Flex container for one or more `<.pane_column>` children.

  ## Example

      <.pane_layout>
        <.pane_column title="Endpoints">...</.pane_column>
        <.pane_column title="Docs">...</.pane_column>
      </.pane_layout>
  """
  slot :inner_block, required: true

  def pane_layout(assigns) do
    ~H"""
    <div class="pane-layout">
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc """
  A single pane column with a header row and a scrollable body.

  ## Attributes

    * `:title`   — (required) string rendered in the column header
    * `:flex`    — optional CSS flex shorthand (e.g. `"1"` or `"1.1 1 0"`)
                   applied as inline style. When set, also clears the
                   default 260px fixed width from .pane-column.
    * `:last`    — optional boolean. `true` removes the right border so
                   the last column doesn't show a double separator.

  ## Slots

    * `:header_actions` — optional content rendered right-aligned in the
                          header row (badges, buttons, metadata).
    * `:inner_block`    — (required) column body, rendered inside
                          `.pane-column` after the header.
  """
  attr :title, :string, required: true
  attr :flex, :string, default: nil
  attr :last, :boolean, default: false

  slot :header_actions
  slot :inner_block, required: true

  def pane_column(assigns) do
    ~H"""
    <div
      class={[
        "pane-column",
        @last && "pane-column--last",
        @flex && "pane-column--flex"
      ]}
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
    """
  end

  @doc """
  Placeholder rendered inside a `<.pane_column>` when there's nothing
  to show (no selection, no data, etc.).

  ## Attributes

    * `:message` — short hint displayed in the empty-state box

  ## Slots

    * `:inner_block` — optional extra content (a button, a link) appended
                       below the message
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

- [ ] **Step 4: Add the `.pane-column--last` CSS rule to root layout**

The existing `.pane-column` in `root.html.heex` has `border-right: 1px solid var(--border-muted)`. The new `--last` modifier needs to drop that border. Open `api/lib/barkpark_web/layouts/root.html.heex` and find the `.pane-column` block (around line 314). Add one line immediately after it:

```css
    .pane-column--last { border-right: none; }
```

(Don't add a `.pane-column--flex` rule — `pane_column` applies the width/min-width overrides inline when `:flex` is set, so the class is just a marker for potential future CSS hooks.)

- [ ] **Step 5: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: 5 tests, 0 failures.

- [ ] **Step 6: Full suite sanity**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 53 tests (48 existing + 5 new), 0 failures.

- [ ] **Step 7: Commit**

```bash
git add api/lib/barkpark_web/components/studio_components.ex api/lib/barkpark_web/layouts/root.html.heex api/test/barkpark_web/components/studio_components_pane_test.exs
git commit -m "feat(studio): pane_layout/pane_column/pane_empty components"
```

---

### Task 2: `pane_item/1` + `pane_section_header/1`

**Files:**
- Modify: `api/lib/barkpark_web/components/studio_components.ex`
- Modify: `api/test/barkpark_web/components/studio_components_pane_test.exs`

- [ ] **Step 1: Add failing tests**

Append to the existing `studio_components_pane_test.exs`:

```elixir
  test "pane_section_header renders category heading with correct class" do
    html =
      render_component(&StudioComponents.pane_section_header/1, %{
        inner_block: [%{inner_block: fn _, _ -> "Query" end}]
      })

    assert html =~ ~s(class="pane-section-header")
    assert html =~ "Query"
  end

  test "pane_item renders a clickable row with label and phx attrs" do
    html =
      render_component(&StudioComponents.pane_item/1, %{
        phx_click: "select",
        phx_value_id: "query-list",
        inner_block: [%{inner_block: fn _, _ -> "List documents" end}]
      })

    assert html =~ ~s(phx-click="select")
    assert html =~ ~s(phx-value-id="query-list")
    assert html =~ ~s(class="pane-item)
    assert html =~ "List documents"
    refute html =~ "selected"
  end

  test "pane_item with selected=true gets the selected class" do
    html =
      render_component(&StudioComponents.pane_item/1, %{
        phx_click: "select",
        phx_value_id: "query-list",
        selected: true,
        inner_block: [%{inner_block: fn _, _ -> "List documents" end}]
      })

    assert html =~ "pane-item selected"
  end

  test "pane_item renders :badge slot when provided" do
    html =
      render_component(&StudioComponents.pane_item/1, %{
        phx_click: "select",
        phx_value_id: "query-list",
        inner_block: [%{inner_block: fn _, _ -> "List documents" end}],
        badge: [%{inner_block: fn _, _ -> ~s(<span class="badge">Pass</span>) end}]
      })

    assert html =~ ~s(class="badge")
    assert html =~ "Pass"
  end
```

- [ ] **Step 2: Run — expect fail**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: 4 new failures.

- [ ] **Step 3: Add the two components**

In `api/lib/barkpark_web/components/studio_components.ex`, immediately below `pane_empty/1`, append:

```elixir
  @doc """
  Uppercase category heading used inside a pane column to group nav
  items. Wraps the inner block in a `.pane-section-header` div.

  ## Example

      <.pane_section_header>Query</.pane_section_header>
  """
  slot :inner_block, required: true

  def pane_section_header(assigns) do
    ~H"""
    <div class="pane-section-header"><%= render_slot(@inner_block) %></div>
    """
  end

  @doc """
  Clickable row inside a pane column. Emits a `<button>` with the
  `phx-click` / `phx-value-*` attrs bound and the `.pane-item`
  class (+ `.selected` when `selected` is true).

  ## Attributes

    * `:phx_click`     — (required) LiveView event name
    * `:phx_value_id`  — (required) stable id the handler uses to look
                          up what was clicked
    * `:selected`      — optional boolean, adds `.selected` modifier
    * `:rest`          — any extra HTML/phx- attributes pass through

  ## Slots

    * `:inner_block` — (required) label contents
    * `:badge`       — optional right-aligned content (verdict badge,
                       count, indicator dot)
  """
  attr :phx_click, :string, required: true
  attr :phx_value_id, :string, required: true
  attr :selected, :boolean, default: false
  attr :rest, :global

  slot :inner_block, required: true
  slot :badge

  def pane_item(assigns) do
    ~H"""
    <button
      phx-click={@phx_click}
      phx-value-id={@phx_value_id}
      class={["pane-item", @selected && "selected"]}
      {@rest}
    >
      <span class="pane-item-label"><%= render_slot(@inner_block) %></span>
      <%= if @badge != [] do %>
        <span class="pane-item-badge"><%= render_slot(@badge) %></span>
      <% end %>
    </button>
    """
  end
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: 9 tests (5 from Task 1 + 4 new), 0 failures.

- [ ] **Step 5: Full suite**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: 57 tests (53 + 4 new), 0 failures.

- [ ] **Step 6: Commit**

```bash
git add api/lib/barkpark_web/components/studio_components.ex api/test/barkpark_web/components/studio_components_pane_test.exs
git commit -m "feat(studio): pane_item + pane_section_header components"
```

---

## Phase 2 — Consumer migration

### Task 3: Refactor `ApiTesterLive` to use the new components

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/api_tester_live.ex`

The current `render/1` hand-writes `<div class="pane-layout">`, three `<div class="pane-column">` nestings, and a `<div class="pane-section-header">` / `<button class="pane-item">` loop. Replace them with component calls. Leave the docs + playground function components (`endpoint_docs/1`, `endpoint_playground/1`, `response_view/1`, `render_reference/2`) untouched — they render the column *body*, not the column structure.

- [ ] **Step 1: Locate the render/1 pane markup**

```bash
grep -n 'pane-layout\|pane-column\|pane-header\|pane-item\|pane-section-header\|empty-state' api/lib/barkpark_web/live/studio/api_tester_live.ex
```

You should see these hits inside the large `~H"""` block in `render/1` (approximately lines 189–260):

- `class="pane-layout api-tester-panes"` — the outer flex container
- 3× `class="pane-column api-col-nav"` / `api-col-docs` / `api-col-response`
- 3× `class="pane-header"` with nested `.pane-header-title`
- `class="pane-section-header"` (inside the nav loop)
- `class="pane-item api-nav-item selected"` (the nav row button)
- `class="empty-state"` (2× for "no selection" and "no response")

- [ ] **Step 2: Replace the pane structure in `render/1`**

Open `api/lib/barkpark_web/live/studio/api_tester_live.ex`. Find the block that currently looks like:

```heex
      <div class="pane-layout api-tester-panes">
        <div class="pane-column api-col-nav">
          <div class="pane-header">
            <span class="pane-header-title">Endpoints</span>
          </div>
          <div class="api-nav-body">
            <%= for category <- @categories do %>
              <div class="pane-section-header"><%= category %></div>
              <%= for ep <- Enum.filter(@endpoints, &(&1.category == category)) do %>
                <button
                  phx-click="select"
                  phx-value-id={ep.id}
                  class={"pane-item api-nav-item #{if @selected_id == ep.id, do: "selected"}"}
                >
                  <span class="api-nav-item-label"><%= ep.label %></span>
                  <%= render_verdict_badge(Map.get(@last_result_by_id, ep.id)) %>
                </button>
              <% end %>
            <% end %>
          </div>
        </div>

        <div class="pane-column api-col-docs">
          <div class="pane-header">
            <%= if @endpoint do %>
              <%= if @endpoint.kind == :reference do %>
                <span class="pane-header-title"><%= @endpoint.label %></span>
              <% else %>
                <span class="pane-header-title">
                  <span class={"api-method api-method-#{String.downcase(@endpoint.method)}"}><%= @endpoint.method %></span>
                  <span class="api-url"><%= @endpoint.path_template %></span>
                </span>
                <span class={"badge #{auth_badge_class(@endpoint.auth)}"}><%= @endpoint.auth %></span>
              <% end %>
            <% else %>
              <span class="pane-header-title">—</span>
            <% end %>
          </div>
          <div class="api-col-body">
            <%= cond do %>
              <% @endpoint == nil -> %>
                <div class="empty-state"><div class="empty-state-text">Select an endpoint on the left.</div></div>
              <% @endpoint.kind == :reference -> %>
                <%= render_reference(assigns, @endpoint.render_key) %>
              <% true -> %>
                <.endpoint_docs endpoint={@endpoint} />
                <.endpoint_playground endpoint={@endpoint} form_state={@form_state} token={@token} />
            <% end %>
          </div>
        </div>

        <div class="pane-column api-col-response">
          <div class="pane-header">
            <span class="pane-header-title">Response</span>
            <%= if @last_result do %>
              <div class="api-response-meta">
                <%= render_verdict_badge(@last_result) %>
                <span class="text-xs text-dim api-response-timing">HTTP <%= @last_result.status %> · <%= @last_result.duration_ms %>ms</span>
              </div>
            <% end %>
          </div>
          <div class="api-col-body">
            <%= if @last_result do %>
              <.response_view result={@last_result} />
            <% else %>
              <div class="empty-state"><div class="empty-state-text">No response yet. Click <strong>Run</strong>.</div></div>
            <% end %>
          </div>
        </div>
      </div>
```

Replace it with:

```heex
      <.pane_layout>
        <.pane_column title="Endpoints">
          <div class="api-nav-body">
            <%= for category <- @categories do %>
              <.pane_section_header><%= category %></.pane_section_header>
              <%= for ep <- Enum.filter(@endpoints, &(&1.category == category)) do %>
                <.pane_item
                  phx_click="select"
                  phx_value_id={ep.id}
                  selected={@selected_id == ep.id}
                >
                  <%= ep.label %>
                  <:badge><%= render_verdict_badge(Map.get(@last_result_by_id, ep.id)) %></:badge>
                </.pane_item>
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
            <%= render_verdict_badge(@last_result) %>
            <span class="text-xs text-dim api-response-timing">HTTP <%= @last_result.status %> · <%= @last_result.duration_ms %>ms</span>
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

The new code calls `docs_column_title(@endpoint)` to compute the header title (either the method+path for endpoints or the label for reference pages). Add this helper above the existing `auth_badge_class/1`:

```elixir
  # Build the docs-column header title for an endpoint or reference page.
  # Returns an iodata so HEEx renders method pills alongside the path.
  defp docs_column_title(nil), do: "—"
  defp docs_column_title(%{kind: :reference, label: label}), do: label
  defp docs_column_title(%{kind: :endpoint, method: method, path_template: path}) do
    # Plain string — the HTTP method pill is rendered via :header_actions in
    # a follow-up refinement. For now, prepend method inline.
    "#{method} #{path}"
  end
```

Note: this is a deliberate regression — the previous version rendered the `GET`/`POST` pill in a coloured badge. Accept the plain-text regression in this task so the migration stays surgical. Follow-up (not in this plan) can move the method pill into a `pane_header` slot enhancement.

- [ ] **Step 4: Remove the now-unused inline CSS that duplicated `.pane-column` overrides**

In the `<style>` block inside `render/1`, find and delete these lines:

```css
      /* Nav column inherits .pane-column's 260px; docs/response override it. */
      .api-col-nav { }
      .api-col-docs {
        width: auto; min-width: 0; flex: 1.1 1 0;
      }
      .api-col-response {
        width: auto; min-width: 0; flex: 1 1 0; border-right: none;
      }
```

These are no longer needed — `pane_column` with `flex="1.1"` / `flex="1"` / `last` attributes handles the sizing inline.

Also delete any `.api-col-nav` / `.api-col-docs` / `.api-col-response` references in the HEEx — they're gone now, the `pane_column` component is the source of truth.

- [ ] **Step 5: Compile + test**

```bash
cd api && MIX_ENV=dev mix compile 2>&1 | grep -iE "error|undefined" | head
MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: clean compile, full suite still green (57 tests from Task 2).

- [ ] **Step 6: Visual smoke test**

```bash
systemctl status barkpark --no-pager 2>&1 | head -3
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://89.167.28.206/studio/production/api-tester
curl -s http://89.167.28.206/studio/production/api-tester | grep -oE 'pane-layout|pane-column|pane-header|pane-item|pane-section-header' | sort -u
```

Expected: service active, HTTP 200, all 5 pane-* classes present in the rendered HTML.

Note: this only verifies the dev worktree tests pass — actual prod smoke happens after merge in Task 5.

- [ ] **Step 7: Commit**

```bash
git add -u api/lib/barkpark_web/live/studio/api_tester_live.ex
git commit -m "refactor(api-tester): use pane_layout/pane_column/pane_item components"
```

---

### Task 4: Refactor `StudioLive` to use the new components

**Files:**
- Modify: `api/lib/barkpark_web/live/studio/studio_live.ex`

`StudioLive` is more complex than `ApiTesterLive`: it renders a dynamic list of `.pane-column` elements (from `@panes`) PLUS a terminal editor column. It uses `.pane-item`, `.pane-section-header`, `.pane-doc-item`, `.pane-doc-title`, `.pane-doc-dot`, and `.pane-doc-id`. This task migrates only the structural wrappers — `.pane-layout`, `.pane-column`, `.pane-header`, `.pane-section-header`, and the simple `.pane-item` rows. It leaves `.pane-doc-item` / `.pane-doc-title` / `.pane-doc-dot` / `.pane-doc-id` alone since they're a different shape with their own sub-elements — extracting them is a bigger follow-up.

- [ ] **Step 1: Find the pane layout in StudioLive**

```bash
grep -n 'class="pane-layout"\|class="pane-column\|class="pane-header\|class="pane-item\b\|class="pane-section-header"' api/lib/barkpark_web/live/studio/studio_live.ex
```

Expected hits (approximately):
- `<div class="pane-layout" id="studio-panes">` — the outer flex
- `<div class="pane-column"` — inside `for pane <- @panes` loop
- `<div class="pane-header">` — column header with title + optional "+" add button
- `<div class="pane-section-header">` — category heading when rendering schema groups
- `<button class={"pane-item ..."}` — schema nav rows
- `<div class="pane-header editor-header">` — the editor column's header (combined class — do NOT migrate this one yet, see step 4)

- [ ] **Step 2: Migrate the outer layout**

Find:
```heex
    <div class="pane-layout" id="studio-panes">
```
Replace with:
```heex
    <.pane_layout>
```
And find the matching closing `</div>` that closes that specific flex container — replace with `</.pane_layout>`. Verify indentation by eye.

Note: the `id="studio-panes"` attribute is lost in this swap. If any JS hook or LiveView test depends on that id, restore it via `<.pane_layout id="studio-panes">` AND extend `pane_layout` in StudioComponents to accept `attr :id, :string, default: nil`. Check:

```bash
grep -rn "studio-panes" api/ /root/barkpark/api/
```

If no hits, drop the id silently. If there are hits, extend `pane_layout/1` in StudioComponents with:

```elixir
attr :id, :string, default: nil
# and in the markup:
<div class="pane-layout" id={@id}>
```

- [ ] **Step 3: Migrate list `pane-column` blocks**

Find the loop that renders each nav pane (approximately the `for pane <- @panes do` section). A typical column looks like:

```heex
<div class="pane-column" id={"pane-#{...}"}>
  <div class="pane-header">
    <span class="pane-header-title"><%= pane.title %></span>
    <%= if pane.kind == :root do %>
      <button ... class="pane-add-btn">+</button>
    <% end %>
  </div>

  <div class="pane-body">
    <%= for group <- pane.groups do %>
      <div class="pane-section-header"><%= group.label %></div>
      <%= for item <- group.items do %>
        <button phx-click="nav" phx-value-id={item.id} class={"pane-item #{if selected, do: "selected"}"}>
          <span class="pane-item-icon">...</span>
          <span class="pane-item-label"><%= item.label %></span>
          <span class="pane-item-chevron">›</span>
        </button>
      <% end %>
    <% end %>
  </div>
</div>
```

Replace the column wrapper with the component. Keep the `pane-body` div for scroll overflow (the component intentionally does NOT provide a body wrapper — consumers can choose padding/overflow themselves):

```heex
<.pane_column title={pane.title}>
  <:header_actions :if={pane.kind == :root}>
    <button phx-click="new-doc" phx-value-type={pane.type_name} class="pane-add-btn">+</button>
  </:header_actions>

  <div class="pane-body">
    <%= for group <- pane.groups do %>
      <.pane_section_header><%= group.label %></.pane_section_header>
      <%= for item <- group.items do %>
        <.pane_item
          phx_click="nav"
          phx_value_id={item.id}
          selected={item.selected}
        >
          <span class="pane-item-icon">...</span>
          <%= item.label %>
          <span class="pane-item-chevron">›</span>
        </.pane_item>
      <% end %>
    <% end %>
  </div>
</.pane_column>
```

Note: inspect the actual `pane` struct shape in `structure.ex` and match the field names (`pane.title`, `pane.kind`, `pane.groups`, `group.items`, `item.id`, `item.selected`, `item.label`, `item.icon`) — the code block above uses placeholder names. Find the real field names first with:

```bash
grep -n "pane.\|@panes\|pane_item" api/lib/barkpark_web/live/studio/studio_live.ex | head -30
```

Do NOT invent field names. If a field is `pane.label` not `pane.title`, use `pane.label`.

The `.pane-item-icon` and `.pane-item-chevron` sub-elements stay as plain spans inside the `<.pane_item>` body — the component renders its `inner_block` inside `.pane-item-label`, but the slot receives raw content, so icon + label + chevron work as positional children.

Actually — the `pane_item` component from Task 2 wraps the inner block in `<span class="pane-item-label">...</span>`, which nests your icon and chevron inside the label span. That breaks the flex layout (icon shouldn't be inside the label). **Before migrating StudioLive, extend `pane_item` to accept named `:icon` and `:trailing` slots.** Do this as a prerequisite:

**Step 3a (prerequisite): Extend `pane_item/1`**

In `api/lib/barkpark_web/components/studio_components.ex`, modify `pane_item/1`:

```elixir
  @doc """
  ...existing doc...

  ## Slots

    * `:inner_block` — (required) label contents
    * `:icon`        — optional leading icon span
    * `:trailing`    — optional right-most element (e.g. chevron)
    * `:badge`       — optional right-aligned content between label and trailing
  """
  attr :phx_click, :string, required: true
  attr :phx_value_id, :string, required: true
  attr :selected, :boolean, default: false
  attr :rest, :global

  slot :inner_block, required: true
  slot :icon
  slot :trailing
  slot :badge

  def pane_item(assigns) do
    ~H"""
    <button
      phx-click={@phx_click}
      phx-value-id={@phx_value_id}
      class={["pane-item", @selected && "selected"]}
      {@rest}
    >
      <%= if @icon != [] do %>
        <span class="pane-item-icon"><%= render_slot(@icon) %></span>
      <% end %>
      <span class="pane-item-label"><%= render_slot(@inner_block) %></span>
      <%= if @badge != [] do %>
        <span class="pane-item-badge"><%= render_slot(@badge) %></span>
      <% end %>
      <%= if @trailing != [] do %>
        <span class="pane-item-chevron"><%= render_slot(@trailing) %></span>
      <% end %>
    </button>
    """
  end
```

Add a test for the new slots in `studio_components_pane_test.exs`:

```elixir
  test "pane_item renders :icon and :trailing slots in the correct order" do
    html =
      render_component(&StudioComponents.pane_item/1, %{
        phx_click: "select",
        phx_value_id: "x",
        inner_block: [%{inner_block: fn _, _ -> "Label" end}],
        icon: [%{inner_block: fn _, _ -> "📄" end}],
        trailing: [%{inner_block: fn _, _ -> "›" end}]
      })

    assert html =~ ~s(class="pane-item-icon")
    assert html =~ "📄"
    assert html =~ ~s(class="pane-item-chevron")
    assert html =~ "›"
    # Icon comes before label, chevron after — check source order
    icon_pos = :binary.match(html, "pane-item-icon") |> elem(0)
    label_pos = :binary.match(html, "pane-item-label") |> elem(0)
    chev_pos = :binary.match(html, "pane-item-chevron") |> elem(0)
    assert icon_pos < label_pos
    assert label_pos < chev_pos
  end
```

Run the new test:

```bash
cd api && MIX_ENV=test mix test test/barkpark_web/components/studio_components_pane_test.exs
```
Expected: 10 tests passing, 0 failures.

Now resume step 3 with the updated component:

```heex
<.pane_item
  phx_click="nav"
  phx_value_id={item.id}
  selected={item.selected}
>
  <:icon><%= item.icon %></:icon>
  <%= item.label %>
  <:trailing>›</:trailing>
</.pane_item>
```

- [ ] **Step 4: Leave the editor column alone**

The editor column uses `<div class="pane-header editor-header">` — a combined class. Migrating it requires extending `pane_column` to accept an extra header class or a custom header slot that fully replaces the title row. That's scope creep for this plan. Leave the editor column as hand-rolled HEEx, with a `# TODO: migrate to pane_column once editor_header merges with pane_header` comment above it so future cleanup has a pointer.

Write exactly this Elixir line immediately before the editor column's opening div:

```elixir
# TODO: migrate to <.pane_column> once editor_header merges with pane_header
```

Preserving the editor column as-is is explicit — the goal is structural extraction of the nav panes, not a full rewrite.

- [ ] **Step 5: Compile + full test suite**

```bash
cd api && MIX_ENV=dev mix compile 2>&1 | grep -iE "error|undefined" | head
MIX_ENV=test mix test 2>&1 | tail -5
```

Expected: clean compile, tests green.

If compile fails with `undefined function pane_item/1` from inside studio_live.ex, the import is wrong — verify `BarkparkWeb.StudioComponents` is listed in `barkpark_web.ex` under `html_helpers/0`. It should be (it was there for the existing `status_badge` / `schema_card`).

If compile fails with slot-related errors, re-check Step 3a's `pane_item` signature: `slot :icon`, `slot :trailing`, `slot :badge`, `slot :inner_block, required: true`.

- [ ] **Step 6: Commit**

```bash
git add -u api/lib/barkpark_web/components/studio_components.ex api/test/barkpark_web/components/studio_components_pane_test.exs api/lib/barkpark_web/live/studio/studio_live.ex
git commit -m "refactor(studio): StudioLive uses pane_layout/pane_column/pane_item"
```

---

## Phase 3 — Other Studio LiveViews audit

### Task 5: Audit `DashboardLive`, `MediaLive`, `DocumentListLive`, `DocumentEditLive`

**Files:**
- Read-only first, then potentially modify each of:
  - `api/lib/barkpark_web/live/studio/dashboard_live.ex`
  - `api/lib/barkpark_web/live/studio/media_live.ex`
  - `api/lib/barkpark_web/live/studio/document_list_live.ex`
  - `api/lib/barkpark_web/live/studio/document_edit_live.ex`

- [ ] **Step 1: Grep for pane-* usage in each file**

```bash
for f in dashboard_live document_list_live document_edit_live media_live; do
  echo "=== $f ==="
  grep -nE 'class="pane-(layout|column|header|item|section-header|body)\b' api/lib/barkpark_web/live/studio/$f.ex || echo "  (no pane-* markup)"
done
```

- [ ] **Step 2: For each file that has pane-* markup, migrate it**

If a file shows hits, apply the same pattern as Task 3 (ApiTesterLive — simpler, no dynamic loops) or Task 4 (StudioLive — complex, dynamic panes).

If a file has no hits, report "no migration needed" for that file and move on.

Typical easy migration (one column with a header + body):

```heex
<!-- Before -->
<div class="pane-layout">
  <div class="pane-column">
    <div class="pane-header">
      <span class="pane-header-title">Media</span>
    </div>
    <div class="pane-body">
      <!-- ... -->
    </div>
  </div>
</div>

<!-- After -->
<.pane_layout>
  <.pane_column title="Media">
    <div class="pane-body">
      <!-- ... -->
    </div>
  </.pane_column>
</.pane_layout>
```

- [ ] **Step 3: Compile + test after each file**

After migrating each LiveView:

```bash
cd api && MIX_ENV=dev mix compile 2>&1 | grep -iE "error|undefined" | head
MIX_ENV=test mix test 2>&1 | tail -5
```

Must stay green after each file. If it breaks, roll back that single file's changes with `git checkout -- path/to/file.ex` and report what went wrong.

- [ ] **Step 4: Commit per migrated file (or one commit for "no migration needed" files)**

If a file was migrated:

```bash
git add -u api/lib/barkpark_web/live/studio/<name>.ex
git commit -m "refactor(studio): <name> uses pane_layout component"
```

If none of the four files needed migration, commit a single doc-only note (or skip this step entirely — no commit needed for a zero-change audit).

---

## Phase 4 — Deploy + verify

### Task 6: Merge, deploy, browser smoke

**Files:** None.

- [ ] **Step 1: Run the full ExUnit suite**

```bash
cd api && MIX_ENV=test mix test 2>&1 | tail -5
```
Expected: all green, approximately 57+ tests (48 baseline + 5 Task 1 + 4 Task 2).

- [ ] **Step 2: Merge the branch to main**

```bash
cd /root/barkpark && git checkout main && git merge --ff-only pane-components 2>&1 | tail -5
git push origin main
```

- [ ] **Step 3: Deploy to /opt/barkpark**

```bash
cd /opt/barkpark && git pull 2>&1 | tail -10
systemctl is-active barkpark
```

Expected: `[post-merge] Done. Service restarted.` and `active`.

- [ ] **Step 4: HTTP smoke test against public IP**

```bash
B="http://89.167.28.206"

echo "=== API tester renders with pane classes ==="
curl -s "$B/studio/production/api-tester" | grep -oE 'pane-layout|pane-column|pane-header|pane-item|pane-section-header|empty-state' | sort -u

echo "=== Structure renders (StudioLive) ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" "$B/studio/production"

echo "=== Media renders ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" "$B/studio/production/media"

echo "=== Still only one .pane-layout rule in the bundle ==="
# CSS lives in root.html.heex now — confirm there's no duplicate in studio_live.ex or any LiveView
grep -rn "^\.pane-column {" api/lib/ || echo "  (no duplicate .pane-column definition)"
```

Expected:
- API tester: all 6 classes present
- Structure: `HTTP 200`
- Media: `HTTP 200`
- No duplicate `.pane-column` rules across `api/lib/`

- [ ] **Step 5: Browser sanity check**

Open `http://89.167.28.206/studio/production/api-tester` in a real browser and confirm:

1. Left sidebar shows category headers ("Reference", "Query", "Mutate", "Real-time", "Schemas") as small-caps headings
2. Each category has a vertical list of `.pane-item` rows with proper padding, hover state, and 3px left-border accent on the selected row
3. Three columns are visible — narrow sidebar (~260px), wider docs column, wider response column — with vertical separator borders
4. Clicking a reference page ("Document envelope") shows docs only, no Run button
5. Clicking "List documents" shows docs + playground form + Run + Copy curl
6. Click Run on "List documents" → response column populates

Also open `http://89.167.28.206/studio/production` (Structure tab) and confirm nothing regressed: schema list pane, doc list pane, and editor pane all render, nav items have the same styling they had before the refactor.

If anything looks broken, stop and dispatch a fix — do not call the plan complete.

- [ ] **Step 6: Nothing to commit**

If all smoke checks pass, the plan is done.

---

## Self-Review

**1. Spec coverage:**

- Pane layout components as single source of truth → Tasks 1, 2 ✓
- `pane_layout` / `pane_column` / `pane_header` via slots → Task 1 ✓
- `pane_item` (+ selected state + badge slot + icon/trailing slots) → Tasks 2 + 3a ✓
- `pane_section_header` → Task 2 ✓
- `pane_empty` → Task 1 ✓
- Import via `BarkparkWeb.StudioComponents` → already in place in `html_helpers/0`, nothing to change ✓
- ApiTesterLive migrated → Task 3 ✓
- StudioLive migrated (except editor column) → Task 4 ✓
- Other Studio LiveViews audited → Task 5 ✓
- Deploy + smoke → Task 6 ✓

**Gap I'm explicitly accepting:** the StudioLive editor column stays hand-rolled. Migrating it requires extending `pane_column` with a custom header slot that fully replaces the title row (to accommodate the doc title + status badge + publish button row the editor currently uses). Left as a TODO comment in Task 4 Step 4.

**2. Placeholder scan:** No TBD / TODO / "similar to" / "handle edge cases" — every step has the code or grep command inline. Task 4 Step 3 explicitly calls out that field names (`pane.title`, `item.selected`, etc.) must be verified against the real struct definitions in `structure.ex` before substituting — the implementer grep the real names first. That's a verify-then-apply instruction, not a placeholder.

**3. Type consistency:**
- `pane_layout/1` signature consistent in Task 1 implementation + Task 3 + Task 4 callers
- `pane_column/1` attrs (`title`, `flex`, `last`, `:header_actions`, `:inner_block`) consistent across Tasks 1, 3, 4
- `pane_item/1` attrs and slots consistent across Tasks 2, 3, 4 — Task 3a (inside Task 4) extends the component to add `:icon` and `:trailing` slots before Task 4 step 3 uses them
- `pane_section_header/1` / `pane_empty/1` consistent
- `BarkparkWeb.StudioComponents` module path consistent everywhere

---

## Execution

**Plan complete and saved to `docs/superpowers/plans/2026-04-14-pane-components.md`.**

**Two execution options:**

1. **Subagent-Driven (recommended)** — 6 tasks, each producing one commit. Task 3a's `pane_item` extension happens inside Task 4 and the subagent handles it in the same session. Best for keeping StudioLive's migration focused.

2. **Inline Execution** — run in this session with checkpoints at each task boundary.

Which approach?
