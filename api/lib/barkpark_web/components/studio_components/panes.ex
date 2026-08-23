defmodule BarkparkWeb.StudioComponents.Panes do
  @moduledoc """
  Pane-layout building blocks for the Barkpark Studio — the structural
  columns, rows, dividers, section headers, and doc-list items that every
  Studio LiveView pane composes from. Extracted from the former monolithic
  `BarkparkWeb.StudioComponents`; re-exported there as a thin facade so
  every `<.pane_column>` / `import BarkparkWeb.StudioComponents` call site
  keeps working unchanged.

  See `api/lib/barkpark_web/layouts/root.html.heex` for the CSS.

  ## The desk's selection vocabulary

  spd-bl-plugin-link-aria-current: this section is the ONE place the split is
  written down — do not fork it into per-site comments.

  The desk speaks selection in three ARIA vocabularies, each chosen by what
  the element IS, not by where it sits:

    * **`aria-current="true"`** — in-desk rows (`pane_item/1`,
      `pane_doc_item/1`, both `<button>`s). "true" because the selected row is
      the current item of an ad-hoc collection that is NOT a page, a step, or a
      date; `aria-selected` is refused because it is only meaningful inside a
      listbox/tab/grid container, which a pane's row list is not.
    * **`aria-current="page"`** — elements whose destination is a PAGE: the
      crumb trail's leaf, and the `:plugin_link` desk anchors
      (`a.pane-item.nav-plugin-entry` in `StudioLive.Components`). Those
      anchors navigate by plain href — deliberately anchors, never buttons —
      and carry `page` when the URL names them as the destination.
    * **`aria-selected`** — the desk filter chips ONLY, because they sit inside
      an explicit `role="tablist"` container, which is exactly the container
      that makes `aria-selected` meaningful.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={"status status-#{@status}"}>
      <span class="status-dot"></span>
      <%= @status %>
    </span>
    """
  end

  @doc """
  Flex container for one or more `<.pane_column>` children.

  `:phx_hook` is an optional LiveView client-hook name mounted on the container
  — used by the responsive space-priority desk to report the viewport width
  bucket back to StudioLive. It renders NO `phx-hook` attribute when nil, so
  every legacy call site stays byte-identical. A caller that passes it must also
  pass `:id` (LiveView requires a stable DOM id on a hooked element).
  """
  attr :id, :string, default: nil
  attr :phx_hook, :string, default: nil
  slot :inner_block, required: true

  def pane_layout(assigns) do
    ~H"""
    <div class="pane-layout" id={@id} phx-hook={@phx_hook}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc """
  A single pane column with a header row and a body area.

  Attrs: title (required), last (boolean), collapsed (boolean),
  phx_click / phx_value_idx (for collapsed click target), id.

  Column sizing is CSS-only: the default width comes from `.pane-column`, and
  a caller that needs a different proportion passes a `marker_class` whose
  rule lives in that caller's own stylesheet (see `.api-col-docs` /
  `.api-col-response` in `api_tester_live.ex`). There is deliberately no
  inline sizing style — an inline `min-width: 0` would override the
  space-priority protections the width buckets rely on.

  Slots: :header_actions (optional inline right-aligned), :inner_block (body).

  ## The collapsed strip is a real button (spd-s6)

  `collapsed: true` renders a `<button type="button">`, not a `<div>`. spd-s4
  promoted this 44px strip to the desk's PRIMARY back-navigation at narrow
  widths (`PaneBuilder.display_state/4` collapses the whole nav row to it), and
  a `phx-click` div is unreachable by keyboard and silent to a screen reader —
  a nav dead end for anyone not using a mouse. It therefore carries an explicit
  `aria-label` alongside the hover `title`, and `aria-hidden` on the decorative
  chevron — which points LEFT, the direction the action actually goes.

  ## The strip is NAVIGATION, not a disclosure (spd-w5, charter D79)

  It shipped with `aria-expanded="false"`, and a live browser reading of the
  authenticated desk found `[aria-expanded="true"]` returning **zero elements
  across the whole document in every state** — the attribute never flipped and
  carried no `aria-controls`, so it was decorative.

  That is structural, not an oversight. A disclosure button PERSISTS through
  both of its states — it is a control *beside* the region it shows and hides.
  This strip **is the pane, collapsed**: it and the expanded pane are ONE
  control in two states (same server-side pane, same `id`), and activating it
  DESTROYS it — the `<button>` is replaced by the expanded `<div>`, so no
  element survives to carry `aria-expanded="true"`. Making the attribute
  truthful would mean inventing a second, persistent toggle on every expanded
  pane; making it *appear* truthful (e.g. `aria-expanded` on the plain
  container `<div>`) would be invalid ARIA, since the attribute is only
  supported on a handful of roles. An ARIA state that can never change is a
  lie to assistive technology and is worse than its absence, so it is REMOVED.

  What remains is a navigation control that re-composes the pane row: it
  truncates `nav_path` and replaces the row's contents. `aria-controls`
  therefore names the region whose contents it changes — the pane row
  (`#studio-panes`), passed by the caller via `:controls`, an ancestor that
  provably exists in the DOM at the moment the attribute is read. It does NOT
  point at the pane's own `id`: the strip and the expanded pane share that id,
  so a self-reference would be the same decoration wearing a new name.

  ## Focus return (`:focus_on_mount`)

  Because the strip is destroyed by its own activation, the browser drops focus
  to `<body>` — measured live: a keyboard user who tabs to the only route back
  out of a drilled pane is thrown to the top of the tab order the moment they
  use it (D79; same defect class D54 recorded for the inspector). The expanded
  pane therefore renders `tabindex="-1" phx-mounted={JS.focus()}` when the
  caller passes `focus_on_mount: true` — LiveView's own declarative mount hook,
  not an imperative `element.focus()` grab and no JS hook of our own. The
  caller sets it only for the pane a just-handled `expand-pane` named, so an
  initial page load (where every pane mounts) never steals focus.

  Its `class` attribute is FROZEN byte-identical at
  `class="pane-column pane-column--collapsed"` (charter D55): the width-bucket
  suite counts strips with an exact regex including the closing quote, and
  `.pane-column` / `.pane-column--collapsed` are the selectors the button UA
  reset and the `:focus-visible` ring hang off in root.html.heex. Add
  ATTRIBUTES freely; never add, reorder or interpolate a class token here.
  """
  attr :title, :string, required: true
  attr :last, :boolean, default: false
  attr :collapsed, :boolean, default: false
  attr :phx_click, :string, default: nil
  attr :phx_value_idx, :string, default: nil
  attr :id, :string, default: nil
  # Optional dimmed item count shown next to the title (e.g. a doc-list pane's
  # document count). nil or 0 → no count chip. Callers pass the already-filtered
  # count (only :doc items) so :divider/:header/:plugin_link never inflate it.
  attr :count, :integer, default: nil
  # Optional extra class appended to the (non-collapsed) column wrapper —
  # used by callers to mark structurally-significant panes (e.g.
  # `bp-doc-list` on the document-list pane so Beta focus mode can hide it
  # via CSS). nil leaves the legacy class string byte-identical.
  attr :marker_class, :string, default: nil
  # Pane anatomy stamps (spd-s3 model, spd-s4 wiring): `data-role` is the
  # pane's structural kind (`nav` on the root desk pane, `list` on every
  # drilled pane) and `data-priority` its squeeze order (`0` root, index on
  # intermediates, `active` on the drilled-to leaf). Both render only when
  # supplied, so every legacy call site stays byte-identical. Any CSS written
  # against them MUST be scoped (charter D30) — `.pane-layout > [data-role=…]`
  # or `html[data-width-bucket=…] […]`, never a bare attribute selector: 130
  # foreign `data-role` values already live on the Tasks board surface.
  attr :data_role, :any, default: nil
  attr :data_priority, :any, default: nil
  # Collapsed strip only: the DOM id of the region whose contents this control
  # replaces (the pane row). Rendered as `aria-controls`; nil renders nothing,
  # so every legacy call site stays byte-identical. See the moduledoc — it is
  # deliberately NOT this pane's own id, which the strip already carries.
  attr :controls, :string, default: nil
  # Expanded column only: land keyboard focus on this pane when it mounts.
  # Set by the caller for the pane a just-handled `expand-pane` named, so the
  # initial page load (where every pane mounts) never steals focus.
  attr :focus_on_mount, :boolean, default: false

  slot :header_actions
  slot :inner_block, required: true

  def pane_column(assigns) do
    extra_classes =
      [
        assigns[:last] && "pane-column--last",
        assigns[:marker_class]
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    col_class =
      if extra_classes == "",
        do: "pane-column",
        else: "pane-column #{extra_classes}"

    assigns =
      assigns
      |> assign(:col_class, col_class)
      |> assign(:role_attr, assigns[:data_role] && to_string(assigns[:data_role]))
      |> assign(:priority_attr, assigns[:data_priority] && to_string(assigns[:data_priority]))

    ~H"""
    <%= if @collapsed do %>
      <button
        type="button"
        class="pane-column pane-column--collapsed"
        id={@id}
        data-role={@role_attr}
        data-priority={@priority_attr}
        phx-click={@phx_click}
        phx-value-idx={@phx_value_idx}
        title={"Back to #{@title}"}
        aria-label={"Back to #{@title}"}
        aria-controls={@controls}
      >
        <div class="pane-header">
          <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24"
            fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
            style="display:inline-block;vertical-align:middle;flex-shrink:0;" aria-hidden="true">
            <path d="m15 18-6-6 6-6"/>
          </svg>
        </div>
        <div class="pane-column-collapsed-label"><%= @title %></div>
      </button>
    <% else %>
      <div
        class={@col_class}
        id={@id}
        data-role={@role_attr}
        data-priority={@priority_attr}
        tabindex={@focus_on_mount && "-1"}
        phx-mounted={@focus_on_mount && JS.focus()}
      >
        <div class="pane-header">
          <span class="pane-header-titlewrap">
            <span class="pane-header-title"><%= @title %></span>
            <span :if={@count && @count > 0} class="pane-header-count"><%= @count %></span>
          </span>
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
  Read-only document preview pane (Task #12 WI3). Wraps the
  `<bp-document-preview>` Web Component with `phx-update="ignore"` so
  LiveView leaves the rendered child DOM alone. The WC owns its own
  rendering — it observes `document-json` + `schema-name` attribute
  changes and re-renders client-side.

  Unlike the other three Studio Web Components (`bp-rich-text-editor`,
  `bp-media-picker`, `bp-reference-picker`), this one is read-only.
  It does NOT emit `bp-change` and does NOT participate in the
  `BarkparkFieldBridge` form-mirror pipeline; there is no hidden input.

  Attrs:
    * `:document` — (required) the document map (will be JSON-encoded).
    * `:schema_name` — (default `""`) schema name used to pick a
      curated renderer in the WC. Anything the WC does not recognise
      falls back to a pretty-printed JSON dump.
    * `:id` — (default `"bp-dp-default"`) DOM id for the wrapper. Must
      be unique per page; phx-hook lifecycle and phx-update="ignore"
      both rely on a stable id.
  """
  attr :document, :any, required: true
  attr :schema_name, :string, default: ""
  attr :id, :string, default: "bp-dp-default"

  def document_preview(assigns) do
    json =
      case assigns.document do
        nil -> ""
        v -> Jason.encode!(v)
      end

    assigns = Phoenix.Component.assign(assigns, :json, json)

    ~H"""
    <div id={@id} phx-update="ignore" class="bp-dp-wrap">
      <bp-document-preview
        document-json={@json}
        schema-name={@schema_name}
      ></bp-document-preview>
    </div>
    """
  end

  @doc """
  Placeholder rendered when there's nothing to show in a pane column.

  Optional `:icon` slot renders a dimmed type glyph above the message (the
  caller passes `<.icon>` so this module stays icon-authority-free); the
  `:inner_block` holds the create affordance (e.g. a `+ New` button).
  """
  attr :message, :string, required: true
  slot :icon
  slot :inner_block

  def pane_empty(assigns) do
    ~H"""
    <div class="empty-state">
      <div :if={@icon != []} class="empty-state-icon"><%= render_slot(@icon) %></div>
      <div class="empty-state-text"><%= @message %></div>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc """
  Uppercase category heading inside a pane column. Two modes:

  * Static (default): `<div class="pane-section-header">` wrapping the
    inner block.
  * Collapsible: `collapsible: true`, `phx_click: "event"`, and
    `phx_value_category: "Cat"` make it a clickable button with a
    rotating chevron. `collapsed: true` shows the collapsed state.
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
  Thin horizontal divider between groups inside a pane body.
  """
  def pane_divider(assigns) do
    ~H"""
    <div class="pane-divider"></div>
    """
  end

  @doc """
  Clickable row inside a pane column.

  Renders a `<button type="button" class="pane-item">` — a desk row is an
  activatable control, so it must be a real button: keyboard-reachable by
  Tab, activatable by Enter/Space, and announced as a button by assistive
  tech. (It used to be a `<div phx-click>`, which no keyboard could ever
  reach.) The `:inner_block` goes inside a `.pane-item-label` span.
  Optional `:icon`, `:badge`, and `:trailing` slots fill their respective
  positions. Source order in the rendered HTML: icon → label → badge →
  trailing. The accessible name comes from the button's own content.

  Selection is exposed as `aria-current="true"` (never `aria-selected`,
  which is only meaningful inside a listbox/tab/grid container).

  ## Attributes

    * `:phx_click`    — (required) LiveView event name
    * `:phx_value_id` — (required) stable id forwarded to the handler
    * `:selected`     — optional boolean, adds `.selected` modifier
    * `:id`           — optional HTML id

  ## Slots

    * `:inner_block` — (required) label contents
    * `:icon`        — optional leading icon
    * `:badge`       — optional right-aligned inline content
    * `:trailing`    — optional terminal element (usually a chevron)
  """
  attr :phx_click, :string, required: true
  attr :phx_value_id, :string, required: true
  attr :phx_value_pane, :string, default: nil
  attr :selected, :boolean, default: false
  attr :id, :string, default: nil

  slot :inner_block, required: true
  slot :icon
  slot :badge
  slot :trailing

  def pane_item(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={@phx_click}
      phx-value-id={@phx_value_id}
      phx-value-pane={@phx_value_pane}
      aria-current={@selected && "true"}
      class={["pane-item", @selected && "selected"] |> Enum.filter(& &1) |> Enum.join(" ")}
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
    </button>
    """
  end

  @doc """
  Rich row for a document inside a pane's doc list.

  Two visual lines: title with leading status dot, below it a real subtitle
  (`:meta` — a declared/manifest summary or a humanized "updated" time). The
  published doc id is demoted to a hover `title=` tooltip on the row (it is
  machine metadata, not a subtitle). A hover-revealed drill chevron sits at
  the trailing edge. Optional trailing slot for inline content (e.g. presence
  dots). `is_draft: true` overrides the status dot's class to `"draft"`
  regardless of the `status` string.

  The outer `.pane-doc-item` stays a `<div>` — it hosts the bulk-publish
  checkbox as a SIBLING of the row body, and a button may not contain a
  button. The inner `.bp-doc-row-body` is the activatable control and is a
  real `<button type="button">`, so the row is Tab-reachable and
  Enter/Space-activatable; its children are `<span>`s because button
  content is phrasing content. Its accessible name is composed from the
  title (see `doc_row_label/1`), never from the `title={@doc_id}` tooltip.
  Selection is `aria-current="true"`.

  ## Attributes

    * `:phx_click`      — (required) LiveView event name
    * `:phx_value_pane` — (required) pane index forwarded to the handler
    * `:phx_value_id`   — (required) document id forwarded to the handler
    * `:title`          — (required) document title
    * `:doc_id`         — (required) published document id
    * `:status`         — (required) document status string; used as
                          the dot's modifier class (unless is_draft)
    * `:is_draft`       — optional boolean; when true, the dot shows
                          "draft" regardless of status
    * `:selected`       — optional boolean, adds `.selected` modifier
    * `:id`             — optional HTML id
    * `:badge`          — optional string; renders right-aligned as a
                          `.pane-doc-badge` pill (with a generic
                          value-derived modifier class). nil → no markup.
                          Fed by the schema's `list_preview` declaration
                          via PaneBuilder — generic for every doc type.
    * `:meta`           — optional string; renders as the `.pane-doc-sub`
                          subtitle line under the title (a declared/manifest
                          summary, or a humanized updated-at fallback supplied
                          by PaneBuilder). nil → no subtitle line.

  ## Slots

    * `:trailing` — optional inline content appended after the title
                    (e.g. presence dots). Rendered inside the
                    `.pane-doc-title` div, right after the title text.
  """
  attr :phx_click, :string, required: true
  attr :phx_value_pane, :string, required: true
  attr :phx_value_id, :string, required: true
  attr :title, :string, required: true
  attr :doc_id, :string, required: true
  attr :status, :string, required: true
  attr :is_draft, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :badge, :string, default: nil
  attr :meta, :string, default: nil

  # ── Bulk-publish multi-select (Task barkpark-3yq) ─────────────────────
  # When `selectable` is true, the row renders a left-anchored checkbox
  # whose `phx-click="toggle-doc-checkbox"` event toggles inclusion in
  # the parent LV's `selected_doc_ids` MapSet. `checked` reflects whether
  # this row's id is in the set. Default false → no checkbox, no
  # behavioural change on legacy callers.
  attr :selectable, :boolean, default: false
  attr :checked, :boolean, default: false
  attr :id, :string, default: nil

  slot :trailing

  def pane_doc_item(assigns) do
    assigns = assign(assigns, :aria_label, doc_row_label(assigns))

    ~H"""
    <div
      id={@id}
      class={
        ["pane-doc-item", @selected && "selected", @checked && "is-bulk-checked"]
        |> Enum.filter(& &1)
        |> Enum.join(" ")
      }
    >
      <%= if @selectable do %>
        <%!-- A REAL control (spd-bl-doc-checkbox-is-an-unfocusable-span): this
              was a bare <span phx-click> — unreachable by keyboard, silent to
              AT, its checked state a bare glyph. Now a <button role="checkbox">
              (legal here: the row body is a SIBLING button inside the outer
              div, so no button-in-button) — Tab-reachable, Enter/Space
              activatable, with aria-checked carrying the state and an
              aria-label naming WHAT gets selected. The ✓ glyph stays visual
              only; AT reads aria-checked. --%>
        <button
          type="button"
          role="checkbox"
          class="bp-doc-checkbox"
          aria-checked={to_string(@checked)}
          aria-label={"Select #{@title}"}
          phx-click="toggle-doc-checkbox"
          phx-value-id={@phx_value_id}
          data-test-id={"doc-checkbox-#{@phx_value_id}"}
        >
          <span class={"bp-doc-checkbox-box " <> if(@checked, do: "is-checked", else: "")}>
            <%= if @checked, do: "✓" %>
          </span>
        </button>
      <% end %>
      <button
        type="button"
        class="bp-doc-row-body"
        title={@doc_id}
        aria-label={@aria_label}
        aria-current={@selected && "true"}
        phx-click={@phx_click}
        phx-value-pane={@phx_value_pane}
        phx-value-id={@phx_value_id}
      >
        <span class="pane-doc-main">
          <span class="pane-doc-title">
            <span class={"pane-doc-dot #{if @is_draft, do: "draft", else: @status}"}></span>
            <%= @title %>
            <%= if @trailing != [] do %>
              <%= render_slot(@trailing) %>
            <% end %>
            <%= if @badge do %>
              <span class={"pane-doc-badge pane-doc-badge--#{badge_slug(@badge)}"}><%= @badge %></span>
            <% end %>
          </span>
          <%= if @meta do %>
            <span class="pane-doc-sub"><%= @meta %></span>
          <% end %>
        </span>
        <span class="pane-doc-chevron" aria-hidden="true">
          <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24"
            fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
            style="display:inline-block;vertical-align:middle;flex-shrink:0;">
            <path d="m9 18 6-6-6-6"/>
          </svg>
        </span>
      </button>
    </div>
    """
  end

  # Accessible name for a doc row, composed FROM THE TITLE plus the state
  # a sighted reader gets from the row's other glyphs: the status dot, the
  # list_preview badge, and the :meta subtitle. Composing is not optional —
  # the row carries `title={@doc_id}` as its sighted tooltip, and `title=`
  # is the accname fallback of last resort, so a button with no explicit
  # label would announce the raw draft id ("drafts.paper-7780f97…") instead
  # of the document. The `:trailing` slot (presence dots) is decorative and
  # deliberately not spoken.
  defp doc_row_label(assigns) do
    status = if assigns.is_draft, do: "draft", else: assigns.status

    [assigns.title, status, assigns[:badge], assigns[:meta]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(", ")
  end

  # Generic CSS-modifier slug for a badge value: downcase, any run of
  # non-alphanumerics → "-" (e.g. "in_progress" → "in-progress"). Lets a
  # stylesheet color badge values without the component ever branching
  # on a specific document type's vocabulary.
  defp badge_slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
