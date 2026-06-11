defmodule BarkparkWeb.StudioComponents do
  @moduledoc "Reusable components for the Barkpark Studio."
  use Phoenix.Component

  import BarkparkWeb.Icons

  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={"status status-#{@status}"}>
      <span class="status-dot"></span>
      <%= @status %>
    </span>
    """
  end

  # ── Pane layout components ──────────────────────────────────────────
  #
  # Shared structural building blocks for every Studio LiveView pane.
  # See api/lib/barkpark_web/layouts/root.html.heex for the CSS.

  @doc """
  Flex container for one or more `<.pane_column>` children.
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

  Attrs: title (required), flex (e.g. "1.1"), last (boolean), collapsed
  (boolean), phx_click / phx_value_idx (for collapsed click target), id.

  Slots: :header_actions (optional inline right-aligned), :inner_block (body).
  """
  attr :title, :string, required: true
  attr :flex, :string, default: nil
  attr :last, :boolean, default: false
  attr :collapsed, :boolean, default: false
  attr :phx_click, :string, default: nil
  attr :phx_value_idx, :string, default: nil
  attr :id, :string, default: nil
  # Optional extra class appended to the (non-collapsed) column wrapper —
  # used by callers to mark structurally-significant panes (e.g.
  # `bp-doc-list` on the document-list pane so Beta focus mode can hide it
  # via CSS). nil leaves the legacy class string byte-identical.
  attr :marker_class, :string, default: nil

  slot :header_actions
  slot :inner_block, required: true

  def pane_column(assigns) do
    extra_classes =
      [
        assigns[:last] && "pane-column--last",
        assigns[:flex] && "pane-column--flex",
        assigns[:marker_class]
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    col_class =
      if extra_classes == "",
        do: "pane-column",
        else: "pane-column #{extra_classes}"

    assigns = assign(assigns, :col_class, col_class)

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
        class={@col_class}
        id={@id}
        style={@flex && "flex: #{@flex}; width: auto; min-width: 0;"}
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
  Sanity-style document chrome header for the editor pane. Emits the
  legacy `<div class="pane-header editor-header">` markup so it can
  replace StudioLive's hand-rolled header at studio_live.ex:1107
  byte-identically. The component was originally also consumed by the
  plugin BookView / BookEditor LVs (removed in Goal `barkpark-zdy`);
  StudioLive is the sole caller today. The corresponding CSS lives in
  `root.html.heex` (hoisted from StudioLive's inline `<style>`).

  Attributes:
    * `:dataset`   — (required) string, current dataset name. Carried
                     so callers can compose other links if needed.
    * `:title`     — (required) document title text.
    * `:back_href` — (optional) when present, render a `←` arrow link
                     before the status pill (used by plugin LVs;
                     StudioLive omits this).

  Slots:
    * `:status_pill` — small badge rendered before the title (e.g.
                       Draft/Published). Matches the legacy badge
                       slot order in `editor-header`.
    * `:presence`    — presence-dot block rendered after the title
                       (StudioLive only — plugin LVs leave empty).
    * `:meta`        — extra inline meta tokens (e.g. _id, _type,
                       timestamps). Rendered as a small muted row at
                       the end of the left flex container; empty for
                       StudioLive (no rendered output) so byte-identity
                       holds.
    * `:actions`     — top-right action buttons (History/Delete/
                       Publish in StudioLive; previously Bokbasen/
                       ONIX export and Open-in-editor in the removed
                       plugin LVs). Slot contents render verbatim —
                       preserve any `data-test-id` attributes.
  """
  attr :dataset, :string, required: true
  attr :title, :string, required: true
  attr :back_href, :string, default: nil

  slot :status_pill
  slot :presence
  slot :meta
  slot :actions

  def document_header(assigns) do
    ~H"""
    <div class="pane-header editor-header">
      <div style="display: flex; align-items: center; gap: 8px;">
        <%= if @back_href do %>
          <a href={@back_href} class="btn btn-ghost btn-sm" aria-label="Back to Studio">&larr;</a>
        <% end %>
        <%= render_slot(@status_pill) %>
        <span class="pane-header-title"><%= @title %></span>
        <%= render_slot(@presence) %>
        <%= if @meta != [] do %>
          <div class="editor-header-meta" style="font-size: 11px; color: var(--fg-dim); display: flex; gap: 12px; flex-wrap: wrap; margin-left: 4px;">
            <%= render_slot(@meta) %>
          </div>
        <% end %>
      </div>
      <div style="display: flex; gap: 6px; min-width: 0; flex: 1; justify-content: flex-end;">
        <%= render_slot(@actions) %>
      </div>
    </div>
    """
  end

  @doc """
  Wrapper for a single field row in the editor body. Emits the legacy
  `<div class="editor-field">` markup with `<label class="editor-field-label">`
  containing the field title, optional `*` required indicator, and
  optional type pill. Used by StudioLive (line 1143 + 1159) and plugin
  LVs to keep field rhythm consistent. CSS in `root.html.heex`.

  Attributes:
    * `:label`    — (required) field label text.
    * `:type`     — (optional) field type tag (e.g. "string", "image");
                     when set renders the small `editor-field-type`
                     pill next to the label.
    * `:required` — (optional, default false) renders a `*` indicator.
    * `:errors`   — (optional, default []) list of error strings; when
                     non-empty adds the `has-error` class and renders a
                     `<div class="field-errors">` below the input.

  Default slot: the input/control itself.
  """
  attr :label, :string, required: true
  attr :type, :string, default: nil
  attr :required, :boolean, default: false
  attr :errors, :list, default: []
  attr :onix_element, :string, default: nil
  slot :inner_block, required: true

  def editor_field(assigns) do
    ~H"""
    <div class={"editor-field #{if @errors != [], do: "has-error"}"}>
      <label class="editor-field-label">
        <%= @label %>
        <%= if @required do %><span class="field-required">*</span><% end %>
        <%= if @type do %><span class="editor-field-type"><%= @type %></span><% end %>
      </label>
      <%= if @onix_element do %>
        <span class="bp-onix-hint" data-onix-element>
          ONIX: <code><%= @onix_element %></code>
        </span>
      <% end %>
      <%= render_slot(@inner_block) %>
      <%= if @errors != [] do %>
        <div class="field-errors"><%= Enum.join(@errors, ", ") %></div>
      <% end %>
    </div>
    """
  end

  @doc false
  # Extract the ONIX element name from a field. Handles both atom-keyed
  # `%Field{}` structs (post-adapter) and string-keyed raw maps (book.json
  # passthrough). Returns the element string, or nil if not present.
  def onix_element(%{onix: %{} = o}), do: Map.get(o, "element") || Map.get(o, :element)
  def onix_element(%{"onix" => %{} = o}), do: Map.get(o, "element") || Map.get(o, :element)
  def onix_element(_), do: nil

  @doc """
  Centered placeholder for the editor pane when no document is loaded
  or loading failed. Emits the legacy `<div class="editor-empty">`
  markup. CSS in `root.html.heex`.

  Attributes:
    * `:message` — (required) primary message text.

  Optional `:icon` slot for a leading icon/glyph (e.g. `<.icon name="file-text">`).
  """
  attr :message, :string, required: true
  slot :icon

  def empty_editor(assigns) do
    ~H"""
    <div class="editor-empty">
      <div style="color: var(--fg-dim); text-align: center;">
        <%= if @icon != [] do %>
          <div style="margin-bottom: 12px; opacity: 0.4;"><%= render_slot(@icon) %></div>
        <% end %>
        <div class="text-sm"><%= @message %></div>
      </div>
    </div>
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

  Renders a `<div class="pane-item">` (NOT a `<button>` — matches the
  Studio convention). The `:inner_block` goes inside a
  `.pane-item-label` span. Optional `:icon`, `:badge`, and `:trailing`
  slots fill their respective positions. Source order in the rendered
  HTML: icon → label → badge → trailing.

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
    <div
      id={@id}
      phx-click={@phx_click}
      phx-value-id={@phx_value_id}
      phx-value-pane={@phx_value_pane}
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
    </div>
    """
  end

  @doc """
  Rich row for a document inside a pane's doc list.

  Two visual lines: title with leading status dot, below it the doc id
  in mono font. Optional trailing slot for inline content (e.g. presence
  dots). `is_draft: true` overrides the status dot's class to `"draft"`
  regardless of the `status` string.

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
    * `:meta`           — optional string; renders as a dimmed
                          `.pane-doc-meta` suffix right after the title.
                          nil → no markup.

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
        <span
          class="bp-doc-checkbox"
          phx-click="toggle-doc-checkbox"
          phx-value-id={@phx_value_id}
          data-test-id={"doc-checkbox-#{@phx_value_id}"}
        >
          <span class={"bp-doc-checkbox-box " <> if(@checked, do: "is-checked", else: "")}>
            <%= if @checked, do: "✓" %>
          </span>
        </span>
      <% end %>
      <div
        class="bp-doc-row-body"
        phx-click={@phx_click}
        phx-value-pane={@phx_value_pane}
        phx-value-id={@phx_value_id}
      >
        <div class="pane-doc-title">
          <span class={"pane-doc-dot #{if @is_draft, do: "draft", else: @status}"}></span>
          <%= @title %>
          <%= if @meta do %>
            <span class="pane-doc-meta"><%= @meta %></span>
          <% end %>
          <%= if @trailing != [] do %>
            <%= render_slot(@trailing) %>
          <% end %>
          <%= if @badge do %>
            <span class={"pane-doc-badge pane-doc-badge--#{badge_slug(@badge)}"}><%= @badge %></span>
          <% end %>
        </div>
        <div class="pane-doc-id"><%= @doc_id %></div>
      </div>
    </div>
    """
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

  # ── Chrome components (Task #11 WI2) ────────────────────────────────
  #
  # Net-new wrappers around the chrome markup that today lives inline in
  # `api/lib/barkpark_web/layouts/studio.html.heex` and (for flash only)
  # `app.html.heex`. Each emits byte-identical HTML to the legacy
  # markup so the WI1 layout snapshot tests stay green.

  @doc """
  Renders Studio flash banners (info + error) using the canonical
  `style="margin: 8px 16px 0;"` margin. Both `studio.html.heex` and
  `app.html.heex` call this — the markup is byte-identical between
  layouts, so consolidating eliminates duplication.

  When neither flash key is set, emits no markup (no leaked wrapper).
  """
  attr :flash, :map, required: true

  def studio_flash(assigns) do
    ~H"""
    <%= if Phoenix.Flash.get(@flash, :info) do %>
      <div class="flash flash-info" style="margin: 8px 16px 0;"><%= Phoenix.Flash.get(@flash, :info) %></div>
    <% end %>
    <%= if Phoenix.Flash.get(@flash, :error) do %>
      <div class="flash flash-error" style="margin: 8px 16px 0;"><%= Phoenix.Flash.get(@flash, :error) %></div>
    <% end %>
    """
  end

  @doc """
  Sign-out form for the Studio topbar. POSTs to `logout_path` (default
  `/logout`). Renders byte-identical to the legacy inline form in
  `studio.html.heex`. Caller wraps with `:if={assigns[:api_token]}` —
  the component itself does NOT guard, so an empty `<div class="studio-bar-actions">`
  wrapper does not leak into the topbar when no api_token is set.

  Uses a hardcoded path string rather than the `~p` sigil because
  `BarkparkWeb.StudioComponents` does not import `:verified_routes`.
  """
  attr :logout_path, :string, default: "/logout"

  def studio_signout_button(assigns) do
    ~H"""
    <div class="studio-bar-actions">
      <.form :let={_f} for={%{}} as={:session} action={@logout_path} method="post">
        <%!-- Icon-only (Sanity-style right rail); the accessible name and
              tooltip both say "Sign out". --%>
        <button type="submit" class="btn btn-ghost btn-sm" aria-label="Sign out" title="Sign out">
          <.icon name="log-out" size={15} />
        </button>
      </.form>
    </div>
    """
  end

  @doc """
  Dark/light theme toggle for the Studio topbar. Client-only — the
  `ThemeToggle` JS hook (root.html.heex) flips
  `document.documentElement.dataset.theme`, persists the choice to
  `localStorage`, and mirrors the live theme onto this button's own
  `data-theme` attribute. Sun vs moon icon visibility is driven purely
  by CSS off that mirror (`.theme-toggle-sun` / `.theme-toggle-moon`),
  so no server round-trip is needed to reflect the current theme.
  `phx-update="ignore"` keeps LiveView patches from clobbering the
  hook-set attribute.
  """
  def studio_theme_toggle(assigns) do
    ~H"""
    <div class="studio-bar-actions">
      <button
        id="studio-theme-toggle"
        type="button"
        class="btn btn-ghost btn-sm theme-toggle"
        phx-hook="ThemeToggle"
        phx-update="ignore"
        aria-label="Toggle dark / light theme"
        title="Toggle dark / light theme"
      >
        <span class="theme-toggle-sun"><.icon name="sun" size={16} /></span>
        <span class="theme-toggle-moon"><.icon name="moon" size={16} /></span>
      </button>
    </div>
    """
  end

  @doc """
  Studio top-level tab navigation. Seeds the registry resolver chain
  with the host's built-in tabs (`default_top_menu_entries/1`,
  derived from `BarkparkWeb.Studio.Nav.tabs/1`) as `:baseline` and
  passes `%{dataset, current_path}` as `:ctx`. Plugins that override
  `resolve_top_menu_entries/2` see the host tabs in `prev` and may
  drop, reorder, or amend them symmetric with how they treat
  sibling-plugin entries. Renders the canonical
  `<div class="studio-bar-tabs">` wrapper with one anchor per tab.
  The active tab is determined uniformly by `plugin_tab_active?/2` —
  built-ins carry an explicit `:active_when` rule so the existing
  highlight behaviour for `…/d/:ds/studio`, `…/d/:ds/studio/media`, and
  `…/d/:ds/studio/api-tester` is preserved.

  The "API" tab points at the legacy `BarkparkWeb.Studio.ApiTesterLive`
  (`…/d/:ds/studio/api-tester`) — restored in task barkpark-7xne after
  the misjudged route-removal in commit f1e5a21. Plugin api_tests/0
  specs ride this same UI under a "Plugins" sidebar category seeded by
  `Barkpark.ApiTester.Endpoints.all/1`.

  The `:nav_section` assign is preserved for backwards compatibility
  but no longer drives active-state — `default_top_menu_entries/1`'s
  `:active_when` rules cover the same routes.

  Caller wraps with `:if={assigns[:dataset]}` — the component itself
  does NOT guard, so an empty `<div class="studio-bar-tabs">` does not
  leak into the topbar when no dataset is set.
  """
  attr :dataset, :string, required: true
  attr :scope_prefix, :string, default: ""
  attr :nav_section, :atom, default: nil
  attr :current_path, :string, default: nil

  def studio_tabs(assigns) do
    ctx = %{
      dataset: assigns.dataset,
      current_path: assigns[:current_path],
      scope_prefix: assigns[:scope_prefix] || ""
    }

    baseline = default_top_menu_entries(assigns.dataset, assigns[:scope_prefix] || "")

    tabs =
      try do
        Barkpark.Plugins.Registry.collect_top_menu_entries(baseline: baseline, ctx: ctx)
      rescue
        _ -> baseline
      catch
        _, _ -> baseline
      end

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <div class="studio-bar-tabs">
      <%= for tab <- @tabs do %>
        <% active = plugin_tab_active?(tab, @current_path) %>
        <a
          href={tab.path}
          class={"studio-tab #{if active, do: "active"}"}
          aria-current={if active, do: "page"}
          data-test-id="top-menu-tab"
        ><%= tab.label %></a>
      <% end %>
    </div>
    """
  end

  # Host's built-in top-menu tabs in the resolver-compatible shape.
  # Threaded as `:baseline` through `Registry.collect_top_menu_entries/1`
  # so plugins can see, reorder, or drop host tabs (Q4 in the plan).
  #
  # `:active_when` is set explicitly per tab so the post-resolution
  # render loop can highlight the active tab uniformly via
  # `plugin_tab_active?/2`:
  #
  #   * Structure: regex matching the Studio base path and any sub-route
  #     *except* `/media` and `/api-tester` (those are owned by the
  #     other two built-ins).
  #   * Media / API: exact path prefix.
  #
  # Orders 10 / 20 / 30 keep built-ins sorted ahead of plugin tabs
  # (which default to 100 via `normalize_top_menu_entry/1`).
  defp default_top_menu_entries(dataset, scope_prefix) when is_binary(dataset) do
    ds = URI.encode(dataset)

    # Scoped surface (tsk-url-p2): tabs address the SAME workspace/project
    # the page is on via the /d/ canonical. "" on a flat surface (e.g. the
    # /studio/:dataset/_plugins admin LV) keeps the legacy flat paths —
    # those ride the flat→scoped 302 funnel.
    base =
      case scope_prefix || "" do
        "" -> "/studio/#{ds}"
        prefix -> "#{prefix}/d/#{ds}/studio"
      end

    base_re = Regex.escape(base)

    structure_active =
      Regex.compile!("^#{base_re}(?:$|/(?!media(?:/|$)|api-tester(?:/|$)).*)")

    media_path = "#{base}/media"
    api_path = "#{base}/api-tester"

    [
      %{
        label: "Structure",
        path: base,
        icon: nil,
        order: 10,
        active_when: structure_active
      },
      %{
        label: "Media",
        path: media_path,
        icon: nil,
        order: 20,
        active_when: media_path
      },
      %{
        label: "API",
        path: api_path,
        icon: nil,
        order: 30,
        active_when: api_path
      }
    ]
  end

  @doc false
  # Decide whether a plugin tab is active. Rule:
  #
  #   * explicit `:active_when` always wins
  #     - string  → `String.starts_with?(current_path, active_when)`
  #     - regex   → `Regex.match?(active_when, current_path)`
  #   * absent → exact match on `tab.path`
  #
  # `current_path` may be nil in contexts that don't track it (back-compat;
  # the assign isn't required on every LV). In that case nothing is active.
  def plugin_tab_active?(_tab, nil), do: false
  def plugin_tab_active?(_tab, ""), do: false

  def plugin_tab_active?(%{active_when: %Regex{} = re}, current_path)
      when is_binary(current_path),
      do: Regex.match?(re, current_path)

  def plugin_tab_active?(%{active_when: prefix}, current_path)
      when is_binary(prefix) and is_binary(current_path),
      do: String.starts_with?(current_path, prefix)

  def plugin_tab_active?(%{path: path}, current_path)
      when is_binary(path) and is_binary(current_path),
      do: current_path == path

  def plugin_tab_active?(_tab, _current_path), do: false

  @doc """
  Studio topbar wrapper. Emits the canonical `<div class="studio-bar">`
  shell and renders three slots in order: `:brand` (single, optional),
  `:tabs` (single, optional), `:actions` (multi, optional).

  Each slot is rendered verbatim — slot content is responsible for its
  own inner wrapper (e.g. `<div class="studio-bar-brand">`,
  `<div class="studio-bar-actions">`). Self-contained sub-components
  like `<.studio_signout_button />` already include their own wrapper.

  Callers use `:if=` on each slot invocation to gate rendering — e.g.
  `<:actions :if={assigns[:api_token]}>…</:actions>`. This avoids
  empty-wrapper leak when the gate is false.
  """
  slot :brand
  slot :tabs
  slot :actions

  def studio_topbar(assigns) do
    ~H"""
    <div class="studio-bar">
      <%= render_slot(@brand) %>
      <%= render_slot(@tabs) %>
      <%= for a <- @actions do %><%= render_slot(a) %><% end %>
    </div>
    """
  end

  @doc """
  Outermost Studio chrome wrapper. Emits `<div class={@class}>` with
  the inner block rendered inside. Default class is `studio-shell`,
  the canonical full-viewport flex column. Override `:class` if a
  caller needs a different shell (rare — kept as an escape hatch).
  """
  attr :class, :string, default: "studio-shell"
  slot :inner_block, required: true

  def studio_shell(assigns) do
    ~H"""
    <div class={@class}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  # ── Body components (Task #11 WI2) ──────────────────────────────────
  #
  # Net-new wrappers extracted from `StudioLive.render/1`. Each emits
  # byte-identical HTML to the legacy inline markup so the WI1 layout
  # snapshot tests and the Task #10 byte-identity test stay green.

  alias BarkparkWeb.Components.FieldInputs
  alias BarkparkWeb.Components.Fields.Visibility
  alias BarkparkWeb.Studio.Plugins.Adapter, as: PluginAdapter

  @doc """
  Renders one schema field row: the `<.editor_field>` wrapper plus the
  v1/v2 fork that dispatches to either `FieldInputs.input/1` (v1 leaf
  controls) or `PluginAdapter.render/2` (v2 composite/arrayOf/codelist/
  localizedText). Output is byte-identical to the inline markup at the
  former `studio_live.ex:1157-1168` call site.

  The plain `<input type="text" name="doc[title]">` for the title row is
  NOT a schema field and stays inline inside `studio_editor_shell/1`.

  Attributes:
    * `:field`             — (required) one schema field map.
    * `:editor_form`       — (required) form state map keyed by field name.
    * `:dataset`           — (default `"production"`) plumbed to FieldInputs.
    * `:validation_errors` — (default `%{}`) keyed by field name; values are
                              error string lists.
    * `:parent_assigns`    — (default `%{}`) full parent LV assigns map,
                              required by `PluginAdapter.render/2` for v2
                              schema fields (OnixEdit `book` etc.).
  """
  attr :field, :map, required: true
  attr :editor_form, :map, required: true
  attr :dataset, :string, default: "production"
  attr :validation_errors, :map, default: %{}
  attr :parent_assigns, :map, default: %{}

  def studio_field_renderer(assigns) do
    ~H"""
    <% field_name = @field["name"] %>
    <% type = @field["type"] %>
    <% rules = @field["validation"] || %{} %>
    <% required? = rules["required"] == true %>
    <% errors = Map.get(@validation_errors, field_name, []) %>
    <%= if self_titled?(type) do %>
      <%!-- v2 structural types render their own <legend>; skip outer label,
           but keep error display + onix hint as inline rows below the field. --%>
      <div class={"editor-field editor-field-self-titled #{if errors != [], do: "has-error"}"}>
        <%= if PluginAdapter.v2?(@field) do %>
          <%= PluginAdapter.render(@parent_assigns, @field) %>
        <% else %>
          <FieldInputs.input
            field={@field}
            editor_form={@editor_form}
            dataset={@dataset}
            scope_prefix={Map.get(@parent_assigns, :scope_prefix, "")}
            api_token_raw={Map.get(@parent_assigns, :api_token_raw, "")}
          />
        <% end %>
        <%= if onix = onix_element(@field) do %>
          <span class="bp-onix-hint" data-onix-element>
            ONIX: <code><%= onix %></code>
          </span>
        <% end %>
        <%= if errors != [] do %>
          <div class="field-errors"><%= Enum.join(errors, ", ") %></div>
        <% end %>
      </div>
    <% else %>
      <.editor_field
        label={@field["title"] || field_name}
        type={type}
        required={required?}
        errors={errors}
        onix_element={onix_element(@field)}
      >
        <%= if PluginAdapter.v2?(@field) do %>
          <%= PluginAdapter.render(@parent_assigns, @field) %>
        <% else %>
          <FieldInputs.input
            field={@field}
            editor_form={@editor_form}
            dataset={@dataset}
            scope_prefix={Map.get(@parent_assigns, :scope_prefix, "")}
            api_token_raw={Map.get(@parent_assigns, :api_token_raw, "")}
          />
        <% end %>
      </.editor_field>
    <% end %>
    """
  end

  # v2 structural field types own their own title via <fieldset><legend>.
  # Routing them through `editor_field` would render the same title twice
  # — once in `<label class="editor-field-label">`, once in the legend.
  # See `barkpark-jwcb`.
  defp self_titled?(type), do: type in ~w(arrayOf composite localizedText)

  @doc """
  Image-picker modal extracted from the legacy inline block at
  `studio_live.ex:1184-1215`. Renders the overlay + media-grid card when
  `image_picker_field` is non-nil. All `phx-*` events bubble to the
  parent LV's `handle_event/3` (StudioLive owns: close-image-picker,
  validate-upload, upload-image, select-media).

  The `uploads` attr is the LV's full uploads struct; function
  components render in the parent process so the upload config scopes
  correctly. Do NOT promote this to a LiveComponent — `@uploads.image`
  scoping does not carry across LiveComponent boundaries.
  """
  attr :image_picker_field, :string, default: nil
  attr :uploads, :map, required: true
  attr :media_files, :list, default: []

  def image_picker_modal(assigns) do
    ~H"""
    <%= if @image_picker_field do %>
      <div class="image-picker-overlay" phx-click="close-image-picker"></div>
      <div class="image-picker">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Select Image</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-image-picker">x</button>
        </div>
        <div class="image-picker-upload">
          <form phx-change="validate-upload" phx-submit="upload-image" phx-value-field={@image_picker_field} id="upload-form">
            <.live_file_input upload={@uploads.image} class="image-file-input" />
            <%= for entry <- @uploads.image.entries do %>
              <div class="image-upload-entry">
                <.live_img_preview entry={entry} width="60" height="60" />
                <span class="text-sm"><%= entry.client_name %></span>
                <button type="submit" class="btn btn-primary btn-sm">Upload</button>
              </div>
            <% end %>
          </form>
        </div>
        <div class="image-picker-grid">
          <%= if @media_files == [] do %>
            <div class="text-sm text-muted" style="padding: 16px; text-align: center;">No images yet. Upload one above.</div>
          <% end %>
          <%= for file <- @media_files do %>
            <div class="image-picker-item" phx-click="select-media" phx-value-url={"/media/files/#{file.path}"} phx-value-field={@image_picker_field}>
              <img src={"/media/files/#{file.path}"} alt={file.original_name} />
              <div class="image-picker-name"><%= file.original_name %></div>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Network shares panel (scoped-sharing P6).

  Lists the live shares (env baseline + persisted) and, for an admin caller,
  offers an add form pre-filled with the current scope plus a remove button per
  STORED share. Follows the image-picker overlay idiom. The whole feature is
  admin-only: `@admin?` gates the mutate UI here, and the StudioLive handlers
  re-check admin server-side (the button being hidden is UX, not the security
  boundary).

  `@rows` is a pre-flattened list of maps (`:scope`, `:surfaces`, `:access`,
  `:source`, `:url`) so this component stays presentation-only.
  """
  attr :show, :boolean, default: false
  attr :admin?, :boolean, default: false
  attr :scope_prefill, :string, default: ""
  attr :prefill_surfaces, :list, default: []
  attr :rows, :list, default: []
  attr :error, :string, default: nil

  def shares_modal(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="image-picker-overlay" phx-click="shares-close"></div>
      <div class="image-picker shares-modal">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Network shares</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="shares-close" aria-label="Close">x</button>
        </div>

        <%= if @admin? do %>
          <form phx-submit="shares-add" class="shares-add-form">
            <label class="shares-field">
              <span class="shares-field-label">Scope</span>
              <input
                type="text"
                name="scope"
                value={@scope_prefill}
                placeholder="workspace/project/dataset"
                class="form-input"
                autocomplete="off"
                required
              />
            </label>
            <div class="shares-field">
              <span class="shares-field-label">Surfaces</span>
              <div class="shares-surfaces">
                <label :for={surface <- ~w(papers docs media)}>
                  <input
                    type="checkbox"
                    name="surfaces[]"
                    value={surface}
                    checked={surface in @prefill_surfaces}
                  />
                  <%= String.capitalize(surface) %>
                </label>
              </div>
            </div>
            <p class="shares-note">
              Read-only — anyone on the local network can view this scope, not edit it.
            </p>
            <p :if={@error} class="shares-error"><%= @error %></p>
            <div class="shares-add-actions">
              <button type="submit" class="btn btn-primary btn-sm">Share</button>
            </div>
          </form>
        <% else %>
          <p class="shares-note" style="padding: 16px;">
            An admin token is required to manage network shares.
          </p>
        <% end %>

        <div class="shares-list">
          <div class="shares-list-title">Active shares</div>
          <%= if @rows == [] do %>
            <div class="shares-empty">Nothing is shared — this scope is private.</div>
          <% else %>
            <div :for={row <- @rows} class="share-row">
              <div class="share-row-main">
                <div class="share-row-scope"><%= row.scope %></div>
                <div class="share-row-meta">
                  <%= row.surfaces %> · <%= row.access %> · <span class="share-row-source"><%= row.source %></span>
                </div>
                <div :if={row.url} class="share-row-url"><%= row.url %></div>
              </div>
              <button
                :if={@admin? and row.source == "stored"}
                type="button"
                class="btn btn-ghost btn-sm share-row-remove"
                phx-click="shares-remove"
                phx-value-scope={row.scope}
                title="Stop sharing this scope"
              >
                Remove
              </button>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  ITEM share popover (P7) — Google-Docs-style "share THIS one item" for a paper
  or document. Distinct from `shares_modal` (which shares a whole workspace
  SECTION): this mints a direct, stable `/s/<token>` link to the single open
  item, with Copy + Revoke. Admin-only (the handlers re-check server-side).

  `@links` is a pre-flattened list of `%{id, access, url}`.
  """
  attr :show, :boolean, default: false
  attr :admin?, :boolean, default: false
  attr :title, :string, default: "this item"
  attr :links, :list, default: []
  attr :error, :string, default: nil

  def item_share_popover(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="image-picker-overlay" phx-click="item-share-close"></div>
      <div class="image-picker item-share-modal">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Share &ldquo;<%= @title %>&rdquo;</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="item-share-close" aria-label="Close">x</button>
        </div>

        <%= if @admin? do %>
          <div class="item-share-body">
            <div class="item-share-lead">
              <span class="item-share-lead-icon"><.icon name="share-2" size={18} /></span>
              <div>
                <div class="item-share-lead-title">Anyone with the link</div>
                <div class="item-share-lead-sub">can open just this item — no account needed.</div>
              </div>
            </div>

            <%= if @links == [] do %>
              <div class="item-share-empty">No link yet.</div>
            <% else %>
              <div :for={link <- @links} class="item-share-link-row">
                <span class={"item-share-access item-share-access-#{link.access}"}>
                  <%= String.capitalize(link.access) %>
                </span>
                <input
                  type="text"
                  readonly
                  value={link.url}
                  class="form-input item-share-url"
                  onclick="this.select()"
                />
                <button
                  type="button"
                  class="btn btn-ghost btn-sm"
                  onclick={"if(navigator.clipboard){var u='#{link.url}';navigator.clipboard.writeText(/^https?:/.test(u)?u:location.origin+u);this.textContent='Copied'}"}
                  title="Copy link"
                >
                  Copy
                </button>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm item-share-revoke"
                  phx-click="item-share-revoke"
                  phx-value-id={link.id}
                  title="Revoke this link"
                >
                  Revoke
                </button>
              </div>
            <% end %>

            <p :if={@error} class="shares-error"><%= @error %></p>

            <div class="item-share-footer">
              <span class="shares-note">Edit links are coming next.</span>
              <button
                type="button"
                class="btn btn-primary btn-sm"
                phx-click="item-share-create"
                phx-value-access="read"
              >
                Create view link
              </button>
            </div>
          </div>
        <% else %>
          <p class="shares-note" style="padding: 16px;">An admin token is required to share items.</p>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  Reference-picker modal extracted from the legacy inline block at
  `studio_live.ex:1218-1240`. Shares the `.image-picker` overlay styling
  (deliberate — same modal chrome). Caller pre-filters candidates via
  `ref_search` so this component is data-only.

  Events bubble to StudioLive: close-ref-picker, ref-search, select-ref.
  """
  attr :ref_picker_field, :string, default: nil
  attr :ref_search, :string, default: ""
  attr :ref_candidates, :list, default: []

  def ref_picker_modal(assigns) do
    ~H"""
    <%= if @ref_picker_field do %>
      <div class="image-picker-overlay" phx-click="close-ref-picker"></div>
      <div class="image-picker">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Select reference</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-ref-picker">x</button>
        </div>
        <div style="padding: 10px 16px; border-bottom: 1px solid var(--border-muted);">
          <input type="text" placeholder="Search..." class="form-input" phx-keyup="ref-search" phx-debounce="200" value={@ref_search} />
        </div>
        <div style="max-height: 400px; overflow-y: auto;">
          <% filtered = filter_ref_candidates(@ref_candidates, @ref_search) %>
          <%= for candidate <- filtered do %>
            <div class="ref-candidate" phx-click="select-ref" phx-value-id={candidate.id} phx-value-field={@ref_picker_field}>
              <span class="ref-candidate-title"><%= candidate.title %></span>
              <span class="ref-candidate-id"><%= candidate.id %></span>
            </div>
          <% end %>
          <%= if filtered == [] do %>
            <div class="text-sm text-muted" style="padding: 20px; text-align: center;">No documents found</div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp filter_ref_candidates(candidates, ""), do: candidates
  defp filter_ref_candidates(candidates, nil), do: candidates

  defp filter_ref_candidates(candidates, query) do
    q = String.downcase(query)

    Enum.filter(candidates, fn c ->
      String.contains?(String.downcase(c.title), q) or String.contains?(String.downcase(c.id), q)
    end)
  end

  @doc """
  History modal extracted from `studio_live.ex:1243-1268`. Renders the
  list of past revisions with restore buttons. The `format_history_time/1`
  helper migrates from StudioLive into this module (private).

  Events bubble to StudioLive: close-history, restore-revision.
  """
  attr :show_history, :boolean, default: false
  attr :revisions, :list, default: []

  def history_modal(assigns) do
    ~H"""
    <%= if @show_history do %>
      <div class="image-picker-overlay" phx-click="close-history"></div>
      <div class="history-modal">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Document history</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-history">x</button>
        </div>
        <div class="history-list">
          <%= if @revisions == [] do %>
            <div class="text-sm text-muted" style="padding: 24px; text-align: center;">No history yet</div>
          <% end %>
          <%= for rev <- @revisions do %>
            <div class="history-item">
              <div class="history-item-info">
                <div class="history-item-action">
                  <span class={"history-action-badge history-action-#{rev.action}"}><%= rev.action %></span>
                  <span class="history-item-title"><%= rev.title || "Untitled" %></span>
                </div>
                <div class="history-item-time"><%= format_history_time(rev.inserted_at) %></div>
              </div>
              <button class="btn btn-sm" phx-click="restore-revision" phx-value-id={rev.id} data-confirm="Restore this version? Current changes will be overwritten.">Restore</button>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp format_history_time(dt) do
    Calendar.strftime(dt, "%b %d, %Y at %H:%M:%S")
  end

  @doc """
  Delete-confirmation modal extracted from `studio_live.ex:1271-1307`.
  Two visual states: clean delete (no incoming references) and
  disconnect+delete (refs exist; lists each one).

  Events bubble to StudioLive: close-delete, confirm-delete (with or
  without `phx-value-disconnect="true"`).
  """
  attr :show_delete, :boolean, default: false
  attr :delete_refs, :list, default: []
  attr :editor_doc, :map, default: nil

  def delete_modal(assigns) do
    ~H"""
    <%= if @show_delete do %>
      <div class="image-picker-overlay" phx-click="close-delete"></div>
      <div class="delete-modal">
        <div class="delete-modal-header">
          <span style="font-weight: 600; font-size: 16px;">Delete document</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-delete">x</button>
        </div>
        <div class="delete-modal-body">
          <%= if @delete_refs == [] do %>
            <p class="text-sm">Are you sure you want to delete <strong><%= @editor_doc && @editor_doc.title %></strong>? This action cannot be undone.</p>
            <div class="delete-modal-actions">
              <button class="btn btn-sm" phx-click="close-delete">Cancel</button>
              <button class="btn btn-destructive btn-sm" phx-click="confirm-delete">Delete</button>
            </div>
          <% else %>
            <div class="delete-warning">
              <p class="text-sm" style="margin-bottom: 12px;">
                <strong><%= @editor_doc && @editor_doc.title %></strong> is referenced by
                <strong><%= length(@delete_refs) %></strong> document<%= if length(@delete_refs) != 1, do: "s" %>:
              </p>
              <div class="delete-ref-list">
                <%= for ref <- @delete_refs do %>
                  <div class="delete-ref-item">
                    <span class="delete-ref-title"><%= ref.title || "Untitled" %></span>
                    <span class="delete-ref-meta"><%= ref.type %> / <%= ref.field %></span>
                  </div>
                <% end %>
              </div>
            </div>
            <div class="delete-modal-actions">
              <button class="btn btn-sm" phx-click="close-delete">Cancel</button>
              <button class="btn btn-destructive btn-sm" phx-click="confirm-delete" phx-value-disconnect="true">Disconnect references and delete</button>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Confirmation modal for "Discard draft". Shown only when the editor is on
  a draft that has a published twin. Two-step: user clicks the overflow-menu
  action → this modal appears; clicking Discard fires `confirm-discard`.

  Guard semantics: the button that opens this modal is already gated on
  `has_published_twin` in `default_doc_actions/2`, so the modal itself is
  always reached with a valid published twin in scope. The handler adds a
  second server-side guard via `editor_has_published`.

  Events bubble to StudioLive: close-discard, confirm-discard.
  """
  attr :show_discard, :boolean, default: false
  attr :editor_doc, :map, default: nil

  def discard_modal(assigns) do
    ~H"""
    <%= if @show_discard do %>
      <div class="image-picker-overlay" phx-click="close-discard"></div>
      <div class="delete-modal" data-test-id="discard-draft-modal">
        <div class="delete-modal-header">
          <span style="font-weight: 600; font-size: 16px;">Discard draft</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-discard">x</button>
        </div>
        <div class="delete-modal-body">
          <p class="text-sm">
            Discard all unsaved changes to <strong><%= @editor_doc && @editor_doc.title %></strong>?
            The published version will remain untouched.
          </p>
          <div class="delete-modal-actions">
            <button class="btn btn-sm" phx-click="close-discard">Cancel</button>
            <button
              class="btn btn-destructive btn-sm"
              phx-click="confirm-discard"
              data-test-id="confirm-discard"
            >
              Discard draft
            </button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Profile-edit modal extracted from `studio_live.ex:986-1025`. Shown
  when `show_profile` is true. Form `phx-change="preview-profile"` lets
  StudioLive preview the new color/name before commit; `phx-submit="save-profile"`
  persists.

  Events bubble to StudioLive: close-profile, save-profile, preview-profile.
  """
  attr :show_profile, :boolean, default: false
  attr :user_name, :string, required: true
  attr :user_color, :string, required: true

  def profile_modal(assigns) do
    ~H"""
    <%= if @show_profile do %>
      <div class="image-picker-overlay" phx-click="close-profile"></div>
      <div class="profile-modal">
        <div class="image-picker-header">
          <span style="font-weight: 600; font-size: 14px;">Your profile</span>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close-profile">x</button>
        </div>
        <form phx-submit="save-profile" phx-change="preview-profile" style="padding: 20px;">
          <div style="display: flex; align-items: center; gap: 12px; margin-bottom: 20px;">
            <div class="presence-me" style={"background: #{@user_color}; width: 40px; height: 40px; font-size: 16px;"}>
              <%= String.first(@user_name) %>
            </div>
            <div>
              <div style="font-weight: 600;"><%= @user_name %></div>
              <div class="text-xs text-muted">This is how others see you</div>
            </div>
          </div>
          <div class="form-group">
            <label class="form-label">Name</label>
            <input type="text" name="name" value={@user_name} class="form-input" autofocus phx-debounce="200" />
          </div>
          <div class="form-group">
            <label class="form-label">Color</label>
            <div class="profile-colors">
              <%= for c <- ~w(#3b82f6 #ef4444 #10b981 #f59e0b #8b5cf6 #ec4899 #06b6d4 #f97316) do %>
                <label class={"profile-color-option #{if c == @user_color, do: "selected"}"}>
                  <input type="radio" name="color" value={c} checked={c == @user_color} style="display:none" />
                  <span class="profile-color-swatch" style={"background: #{c}"}></span>
                </label>
              <% end %>
            </div>
          </div>
          <div style="display: flex; justify-content: flex-end; gap: 8px; margin-top: 8px;">
            <button type="button" class="btn btn-sm" phx-click="close-profile">Cancel</button>
            <button type="submit" class="btn btn-primary btn-sm">Save</button>
          </div>
        </form>
      </div>
    <% end %>
    """
  end

  @doc """
  Umbrella that composes the five Studio modal components into a single
  call site. Each child renders only when its gate assign is set, so the
  umbrella's emitted DOM is byte-identical to the legacy five top-level
  `<%= if … %>` blocks formerly inline in StudioLive.

  Per-modal components remain individually exported for testability and
  for any future LV that wants only one modal in isolation.

  Order matches the legacy render order: profile, image_picker,
  ref_picker, history, delete. (Profile sits OUTSIDE pane_layout in the
  legacy markup; the other four sit INSIDE. Caller chooses placement.)
  """
  attr :show_profile, :boolean, default: false
  attr :user_name, :string, default: ""
  attr :user_color, :string, default: ""

  attr :image_picker_field, :string, default: nil
  attr :uploads, :map, required: true
  attr :media_files, :list, default: []

  attr :ref_picker_field, :string, default: nil
  attr :ref_search, :string, default: ""
  attr :ref_candidates, :list, default: []

  attr :show_history, :boolean, default: false
  attr :revisions, :list, default: []

  attr :show_delete, :boolean, default: false
  attr :delete_refs, :list, default: []
  attr :editor_doc, :map, default: nil
  attr :show_discard, :boolean, default: false

  def studio_modals(assigns) do
    ~H"""
    <.profile_modal
      show_profile={@show_profile}
      user_name={@user_name}
      user_color={@user_color}
    />
    <.image_picker_modal
      image_picker_field={@image_picker_field}
      uploads={@uploads}
      media_files={@media_files}
    />
    <.ref_picker_modal
      ref_picker_field={@ref_picker_field}
      ref_search={@ref_search}
      ref_candidates={@ref_candidates}
    />
    <.history_modal show_history={@show_history} revisions={@revisions} />
    <.delete_modal
      show_delete={@show_delete}
      delete_refs={@delete_refs}
      editor_doc={@editor_doc}
    />
    <.discard_modal show_discard={@show_discard} editor_doc={@editor_doc} />
    """
  end

  @doc """
  Presence-nav overlay (top-right) extracted from `studio_live.ex:947-984`.
  Renders one avatar+tooltip per other user plus the self pill. The
  outer wrapper preserves the LV hook contract:

      <div class="presence-nav" id="presence-hook" phx-hook="PresenceIdentity">

  Both `id="presence-hook"` AND `phx-hook="PresenceIdentity"` are
  load-bearing — the localStorage-sync mechanism declared in
  `root.html.heex` listens on this element. Do NOT change either.

  Events bubble to the parent LV: `jump-to-user`, `show-profile`.
  Helpers `truncate_text/2` and `resolve_presence_doc_title/2` migrate
  from StudioLive into module-private of this component.
  """
  attr :user_id, :string, required: true
  attr :user_name, :string, required: true
  attr :user_color, :string, required: true
  attr :presences, :list, default: []
  attr :editor_doc, :map, default: nil
  attr :dataset, :string, required: true
  attr :current_workspace, :map, default: nil
  attr :current_project, :map, default: nil

  def presence_nav(assigns) do
    ~H"""
    <div class="presence-nav" id="presence-hook" phx-hook="PresenceIdentity">
      <% scope_opts = build_scope_opts(@current_workspace, @current_project) %>
      <% others = Enum.reject(@presences, & &1.user_id == @user_id) %>
      <%= for p <- others do %>
        <% p_doc_title = resolve_presence_doc_title(p, @dataset, scope_opts) %>
        <%= if p.doc_id && p.type do %>
          <div class="presence-user-wrap"
               phx-click="jump-to-user" phx-value-type={p.type} phx-value-doc-id={p.doc_id}>
            <div class="presence-avatar clickable" style={"background: #{p.color}"}>
              <%= String.first(Map.get(p, :name, "U")) %>
            </div>
            <div class="presence-tooltip">
              <div class="presence-tooltip-name"><%= Map.get(p, :name, "User") %></div>
              <div class="presence-tooltip-location">editing <strong><%= truncate_text(p_doc_title, 24) %></strong></div>
              <div class="presence-tooltip-hint">Click to jump there</div>
            </div>
          </div>
        <% else %>
          <div class="presence-user-wrap">
            <div class="presence-avatar" style={"background: #{p.color}"}>
              <%= String.first(Map.get(p, :name, "U")) %>
            </div>
            <div class="presence-tooltip">
              <div class="presence-tooltip-name"><%= Map.get(p, :name, "User") %></div>
              <div class="presence-tooltip-location">browsing</div>
            </div>
          </div>
        <% end %>
      <% end %>
      <div class="presence-me-group" phx-click="show-profile" title={"#{@user_name} — profile"}>
        <div class="presence-me-info">
          <span class="presence-me-name"><%= @user_name %></span>
          <span class="presence-me-location"><%= truncate_text(if(@editor_doc, do: @editor_doc.title || "Untitled", else: "browsing"), 24) %></span>
        </div>
        <div class="presence-me" style={"background: #{@user_color}"}>
          <%= String.first(@user_name) %>
        </div>
      </div>
    </div>
    """
  end

  defp truncate_text(nil, _max), do: ""
  defp truncate_text(text, max) when byte_size(text) <= max, do: text
  defp truncate_text(text, max), do: String.slice(text, 0, max - 1) <> "..."

  # Build scope opts from the workspace/project assigns the parent LV holds.
  # Mirrors `BarkparkWeb.ScopeHelpers.scope_opts(%Socket{})` for the Socket
  # variant — no `memoize: true` (LV processes are long-lived; see sknf).
  # Nil-safe: an absent workspace or project drops its key entirely.
  defp build_scope_opts(workspace, project) do
    []
    |> put_scope_key(:workspace_id, workspace)
    |> put_scope_key(:project_id, project)
  end

  defp put_scope_key(opts, _key, nil), do: opts
  defp put_scope_key(opts, key, %{id: id}), do: Keyword.put(opts, key, id)
  defp put_scope_key(opts, _key, _other), do: opts

  defp resolve_presence_doc_title(presence, dataset, scope_opts) do
    type = presence.type
    doc_id = presence.doc_id

    if type && doc_id do
      case Barkpark.Content.get_document(doc_id, type, dataset, scope_opts) do
        {:ok, doc} ->
          doc.title || doc_id

        _ ->
          case Barkpark.Content.get_document("drafts.#{doc_id}", type, dataset, scope_opts) do
            {:ok, doc} -> doc.title || doc_id
            _ -> doc_id
          end
      end
    else
      "browsing"
    end
  end

  @doc """
  StudioLive editor column extracted from `studio_live.ex:1106-1181`.
  Renders the `<.document_header>` (Task #9) + form-with-fields when an
  `editor_doc` is loaded, or `<.empty_editor>` (Task #9) otherwise.
  Schema fields delegate to `<.studio_field_renderer>` (which itself
  wraps `FieldInputs.input/1` per Task #10 byte-identity contract).

  The TODO at studio_live.ex:1099-1103 (hand-rolled editor column)
  is preserved verbatim — WI2 does NOT absorb that debt; it requires a
  `<.pane_column>` API change (design plan archived).

  Historical note: the plugin BookView / BookEditor LVs (removed in
  Goal `barkpark-zdy`) deliberately did NOT consume this component —
  their action sets diverged enough (Bokbasen pills, ONIX export,
  custom tab nav) that wrapping forced endless slots. They called
  `<.document_header>` directly. StudioLive is the only consumer today.

  Events bubble to StudioLive: save, autosave, show-history, delete-doc,
  publish, unpublish, plus the studio_field_renderer phx-click events
  (open-image-picker, clear-image). The reference field is now owned
  client-side by `<bp-reference-picker>` (Task #12 WI2) and bridges
  through autosave; open-ref-picker / clear-ref handlers in StudioLive
  are orphaned-but-harmless until v2 cleanup.

  Slots:
    * `:extra_actions` — (optional) appended after Publish/Unpublish.
                          Currently unused; documented for plugin LVs.
    * `:empty_state`   — (optional) overrides the default
                          `<.empty_editor message="Select a document …">`.
  """
  attr :editor_doc, :map, default: nil
  attr :editor_schema, :map, default: nil
  attr :editor_type, :string, default: nil
  attr :editor_form, :map, required: true
  attr :editor_is_draft, :boolean, default: false
  attr :dataset, :string, required: true
  attr :validation_errors, :map, default: %{}
  attr :save_status, :string, default: ""
  attr :presences, :list, default: []
  attr :parent_assigns, :map, default: %{}
  attr :nav_group, :string, default: nil

  # ── Cross-field validations (Task barkpark-cgn) ────────────────────
  # List of unsatisfied rule maps (string-keyed: name, title, level,
  # fields). Empty list → banner not rendered, no visual cost on
  # schemas that declare no rules.
  attr :cross_violations, :list, default: []
  # ── Content preview side-pane (Goal barkpark-G1, task s3) ──────────
  # Doc-type-agnostic. Parent passes pre-rendered iodata + a soft
  # toggle. The pane is rendered iff `content_preview_rendered != nil`
  # AND the toggle is on — there is NO hardcoded doc-type gate.
  attr :content_preview_rendered, :any, default: nil
  attr :content_preview_visible, :boolean, default: true

  # ── Draft-vs-Published diff view (Task barkpark-uix) ───────────────
  # `diff_visible` flips the editor body between the form and the
  # field-level diff. `published_doc` is the published twin of the open
  # draft (nil when no draft is open, or when the draft has no
  # published counterpart). The toggle button is gated on both
  # editor_is_draft AND a non-nil published_doc — i.e. exactly the
  # case where a meaningful diff exists.
  attr :diff_visible, :boolean, default: false
  attr :published_doc, :map, default: nil

  # ── Editor-header doc actions (Goal barkpark-cjs, s4) ──────────────────
  # List of resolved doc-action maps from
  # `StudioLive.resolved_doc_actions/1`. Each entry is a string-keyed map
  # matching the `Barkpark.Plugin.doc_action` typespec — `"name"`,
  # `"label"`, `"kind"` (`"event"` | `"modal"` | `"link"`), `"scope"`
  # (`"editor_header"` | `"overflow"`), and an `"opts"` map carrying
  # per-kind payload (the phx-click event for `"event"`, an href template
  # for `"link"`, a modal payload for `"modal"`). When empty (e.g. legacy
  # callers that haven't been migrated yet), the editor header renders no
  # action buttons — the action bar should be considered authoritative.
  attr :doc_actions, :list, default: []

  slot :extra_actions
  slot :empty_state

  def studio_editor_shell(assigns) do
    show_diff_toggle =
      assigns.editor_doc != nil and assigns.editor_is_draft and
        assigns.published_doc != nil

    assigns =
      assigns
      |> assign(
        :show_content_preview,
        assigns.content_preview_rendered != nil and assigns.content_preview_visible and
          not (assigns.diff_visible and show_diff_toggle)
      )
      |> assign(:show_diff_toggle, show_diff_toggle)
      |> assign(:show_diff, show_diff_toggle and assigns.diff_visible)

    ~H"""
    <%= if @editor_doc do %>
      <div class="editor-panel">
        <.document_header
          dataset={@dataset}
          title={@editor_doc.title || "Untitled"}
        >
          <:status_pill>
            <span class={"badge badge-#{if @editor_is_draft, do: "draft", else: @editor_doc.status}"}>
              <%= if @editor_is_draft, do: "draft", else: @editor_doc.status %>
            </span>
          </:status_pill>
          <:presence>
            <% doc_presences = presences_on_doc(@presences, Barkpark.Content.published_id(@editor_doc.doc_id), @dataset) %>
            <%= if doc_presences != [] do %>
              <div class="presence-dots">
                <%= for p <- doc_presences do %>
                  <div class="presence-dot" style={"background: #{p.color}"} title={"#{Map.get(p, :name, "User")} is editing"}></div>
                <% end %>
              </div>
            <% end %>
          </:presence>
          <:actions>
            <bp-overflow-menu class="bp-overflow-menu">
              <%= for action <- @doc_actions do %>
                <.doc_action_button
                  action={action}
                  editor_doc={@editor_doc}
                  dataset={@dataset}
                  workspace_slug={scope_slug(@parent_assigns, :current_workspace)}
                  project_slug={scope_slug(@parent_assigns, :current_project)}
                />
              <% end %>
              <%= render_slot(@extra_actions) %>
            </bp-overflow-menu>
          </:actions>
        </.document_header>

        <div class={"editor-with-preview " <> if(@show_content_preview, do: "has-onix-preview", else: "")}>
        <div class="editor-body editor-panel-main">
          <%= if @editor_schema do %>
            <div class="editor-meta">
              <.icon name={@editor_schema.icon} size={14} /> <%= @editor_schema.title %> &middot; <%= length(@editor_schema.fields) %> fields
            </div>
          <% end %>

          <.cross_violations_banner violations={@cross_violations} />

          <%= if @show_diff do %>
            <BarkparkWeb.Components.DraftDiff.draft_diff
              draft={@editor_doc}
              published={@published_doc}
              schema={@editor_schema}
            />
          <% else %>
            <%= if schema_groups(@editor_schema) != [] do %>
              <div class="bp-tab-bar" role="tablist">
                <%= for grp <- schema_groups(@editor_schema) do %>
                  <button
                    type="button"
                    phx-click="select-group"
                    phx-value-group={grp["name"]}
                    role="tab"
                    aria-selected={@nav_group == grp["name"]}
                    title={grp["title"]}
                    aria-label={grp["title"]}
                    class={"bp-tab " <> if(@nav_group == grp["name"], do: "is-active", else: "")}
                  ><span class="bp-tab-icon" aria-hidden="true"><.icon name={tab_icon(grp)} /></span></button>
                <% end %>
              </div>
            <% end %>

            <form phx-submit="save" phx-change="autosave" id="editor-form">
              <.editor_field
                label="Title"
                required={(get_title_validation(@editor_schema) || %{})["required"] == true}
                errors={Map.get(@validation_errors, "title", [])}
              >
                <input type="text" name="doc[title]" value={@editor_form["title"]} class="form-input" phx-debounce="300" />
              </.editor_field>
              <%= if @editor_schema do %>
                <%= for field <- visible_fields(Enum.reject(@editor_schema.fields, & &1["name"] == "title"), @nav_group),
                        Visibility.visible?(field, @editor_form) do %>
                  <.studio_field_renderer
                    field={field}
                    editor_form={@editor_form}
                    dataset={@dataset}
                    validation_errors={@validation_errors}
                    parent_assigns={@parent_assigns}
                  />
                <% end %>
              <% end %>
              <div class="editor-actions">
                <span class="save-status"><%= @save_status %></span>
              </div>
            </form>
          <% end %>
        </div>
        <BarkparkWeb.Components.OnixPreview.content_preview
          :if={@show_content_preview}
          rendered={@content_preview_rendered}
          type={@editor_type || ""}
        />
        </div>
      </div>
    <% else %>
      <%= if @empty_state != [] do %>
        <%= render_slot(@empty_state) %>
      <% else %>
        <.empty_editor message="Select a document to edit">
          <:icon><.icon name="file-text" size={40} /></:icon>
        </.empty_editor>
      <% end %>
    <% end %>
    """
  end

  # Dataset arm mirrors PresenceState.on_doc/3 (tsk-url-p0): the same doc_id
  # in another dataset is NOT co-presence.
  defp presences_on_doc(presences, doc_id, dataset) do
    Enum.filter(presences, &(&1.doc_id == doc_id and Map.get(&1, :dataset) == dataset))
  end

  # Slug off the parent LV's resolved scope structs — "" when unscoped
  # (flat surface) so href interpolation degrades to empty segments.
  defp scope_slug(parent_assigns, key) do
    case Map.get(parent_assigns || %{}, key) do
      %{slug: slug} when is_binary(slug) -> slug
      _ -> ""
    end
  end

  @doc """
  Renders a single editor-header doc-action — `"event"`, `"modal"`, or
  `"link"` — from a resolved doc-action map (see
  `Barkpark.Plugin.doc_action` typespec + `StudioLive.default_doc_actions/2`).

  Used by `studio_editor_shell/1` to walk the resolved list inside
  `<bp-overflow-menu>`. Splits out so the case statement stays out of the
  shell's main HEEx.

    * `"event"` → `<button phx-click=<opts.event>>`
    * `"modal"` → `<button phx-click="schema_action" phx-value-name=<name>>`
    * `"link"`  → `<a href=<interpolated-href>>`

  Class / style / `data-test-id` are read off `opts` so the host's built-in
  buttons preserve their existing attrs (`btn btn-primary btn-sm` on
  Publish, `color: var(--destructive)` on Delete, `data-test-id` on
  Duplicate / Open another / schema actions). Plugin-contributed actions
  without those opts fall back to `btn btn-ghost btn-sm`.
  """
  attr :action, :map, required: true
  attr :editor_doc, :map, default: nil
  attr :dataset, :string, required: true
  # Scope slugs for href interpolation (tsk-url-p2): a schema action may
  # carry :workspace / :project placeholders alongside :dataset / :id.
  attr :workspace_slug, :string, default: ""
  attr :project_slug, :string, default: ""

  def doc_action_button(assigns) do
    ~H"""
    <%= case @action["kind"] do %>
      <% "link" -> %>
        <a
          href={
            interpolate_doc_action_href(
              @action,
              @editor_doc,
              @dataset,
              @workspace_slug,
              @project_slug
            )
          }
          class={action_button_class(@action)}
          title={@action["label"]}
          aria-label={@action["label"]}
          data-test-id={doc_action_test_id(@action)}
        ><.doc_action_glyph action={@action} /></a>
      <% "modal" -> %>
        <button
          type="button"
          class={action_button_class(@action)}
          style={action_button_style(@action)}
          title={@action["label"]}
          aria-label={@action["label"]}
          data-test-id={doc_action_test_id(@action)}
          phx-click="schema_action"
          phx-value-name={@action["name"]}
        ><.doc_action_glyph action={@action} /></button>
      <% _ -> %>
        <%!-- default: "event" — dispatch the named phx-click event --%>
        <button
          type="button"
          class={action_button_class(@action)}
          style={action_button_style(@action)}
          title={@action["label"]}
          aria-label={@action["label"]}
          data-test-id={doc_action_test_id(@action)}
          phx-click={doc_action_event(@action)}
        ><.doc_action_glyph action={@action} /></button>
    <% end %>
    """
  end

  # Renders the action's icon if one is declared, falling back to the
  # text label so plugin-contributed actions that pre-date the icon
  # convention still render a clickable button. The icon SVG is
  # aria-hidden so screen readers announce the parent button's
  # aria-label exactly once. See task barkpark-jl4x.
  attr :action, :map, required: true

  defp doc_action_glyph(assigns) do
    icon_name = doc_action_icon(assigns.action)
    assigns = assign(assigns, :icon_name, icon_name)

    ~H"""
    <%= if @icon_name do %>
      <span class="bp-action-icon" aria-hidden="true"><.icon name={@icon_name} size={16} /></span>
    <% else %>
      <%= @action["label"] %>
    <% end %>
    """
  end

  # Read the icon name from either `opts.icon` (task barkpark-jl4x
  # convention for built-ins) or the top-level `"icon"` key (existing
  # schema-action spec — see `Barkpark.Plugin.doc_action` typespec and
  # `OnixEdit.document_actions/0`). Returns nil when neither is set;
  # callers fall back to the text label so the button stays usable.
  defp doc_action_icon(action) do
    case action do
      %{"opts" => %{"icon" => icon}} when is_binary(icon) -> icon
      %{"icon" => icon} when is_binary(icon) -> icon
      _ -> nil
    end
  end

  defp doc_action_event(action) do
    case action["opts"] do
      %{"event" => ev} when is_binary(ev) -> ev
      _ -> action["name"]
    end
  end

  defp action_button_class(action) do
    case action["opts"] do
      %{"class" => c} when is_binary(c) -> c
      _ -> "btn btn-ghost btn-sm"
    end
  end

  defp action_button_style(action) do
    case action["opts"] do
      %{"style" => s} when is_binary(s) -> s
      _ -> nil
    end
  end

  defp doc_action_test_id(action) do
    case action["opts"] do
      %{"data_test_id" => id} when is_binary(id) ->
        id

      _ ->
        case action["kind"] do
          k when k in ["modal", "link"] -> "schema-action-#{action["name"]}"
          _ -> nil
        end
    end
  end

  # Same interpolation StudioLive used for schema-declared `"link"`
  # actions. Falls back to `"#"` when href is missing. Substitutes
  # `:dataset` and `:id` (published id — drafts. prefix stripped).
  defp interpolate_doc_action_href(action, doc, dataset, ws_slug, proj_slug) do
    case action["opts"] do
      %{"href" => href} when is_binary(href) ->
        do_interpolate_href(href, doc, dataset, ws_slug, proj_slug)

      _ ->
        case action["href"] do
          href when is_binary(href) -> do_interpolate_href(href, doc, dataset, ws_slug, proj_slug)
          _ -> "#"
        end
    end
  end

  # Placeholder vocabulary: :dataset · :id · :workspace · :project
  # (tsk-url-p2 added the scope pair — a plugin action can address the
  # scoped API, e.g. href: "/w/:workspace/p/:project/v1/data/doc/:dataset/...").
  # :workspace is replaced before :w-anything ambiguity can arise because
  # the replacements run longest-token-first.
  defp do_interpolate_href(href, doc, dataset, ws_slug, proj_slug) do
    id =
      case doc do
        %{doc_id: doc_id} -> Barkpark.Content.published_id(doc_id)
        _ -> ""
      end

    href
    |> String.replace(":workspace", to_string(ws_slug || ""))
    |> String.replace(":project", to_string(proj_slug || ""))
    |> String.replace(":dataset", to_string(dataset || ""))
    |> String.replace(":id", id)
  end

  @doc """
  Renders the cross-field validation banner at the top of the editor pane
  (Task barkpark-cgn). Empty list → nothing renders. Each violation
  surfaces its title and level (error|warning) plus the first involved
  field as a hint.

  This is the first-pass UI from the task spec — count + per-rule rows.
  The inline-per-field highlight pass lives behind future work, gated on
  stable per-field DOM ids (currently absent from `editor_field`).
  """
  attr :violations, :list, default: []

  def cross_violations_banner(assigns) do
    assigns =
      assign(
        assigns,
        :counts,
        %{
          error: Enum.count(assigns.violations, &(&1["level"] == "error")),
          warning: Enum.count(assigns.violations, &(&1["level"] == "warning"))
        }
      )

    ~H"""
    <%= if @violations != [] do %>
      <div class="bp-violations" role="status" aria-live="polite" data-test-id="cross-violations">
        <div class="bp-violations-summary">
          <span class="bp-violations-count">
            <%= length(@violations) %> issue<%= if length(@violations) != 1, do: "s" %>:
          </span>
          <%= if @counts.error > 0 do %>
            <span class="bp-violations-error"><%= @counts.error %> error<%= if @counts.error != 1, do: "s" %></span>
          <% end %>
          <%= if @counts.error > 0 and @counts.warning > 0 do %>
            <span>·</span>
          <% end %>
          <%= if @counts.warning > 0 do %>
            <span class="bp-violations-warning"><%= @counts.warning %> warning<%= if @counts.warning != 1, do: "s" %></span>
          <% end %>
        </div>
        <ul class="bp-violations-list">
          <%= for v <- @violations do %>
            <li class={"bp-violation-item bp-violations-#{v["level"] || "error"}"}
                data-test-id={"cross-violation-#{v["name"]}"}>
              <span class="bp-violation-title"><%= v["title"] || v["name"] %></span>
              <%= if is_list(v["fields"]) and v["fields"] != [] do %>
                <span class="bp-violation-fields">&nbsp;— <%= List.first(v["fields"]) %></span>
              <% end %>
            </li>
          <% end %>
        </ul>
      </div>
    <% end %>
    """
  end

  defp get_title_validation(nil), do: nil

  defp get_title_validation(schema) do
    case Enum.find(schema.fields, &(&1["name"] == "title")) do
      %{"validation" => v} -> v
      _ -> nil
    end
  end

  @doc """
  Read the `groups` declaration from a schema map (Sanity-style field-group
  tabs). Tolerates atom or string keys; returns `[]` for legacy schemas that
  never declared any groups so the editor's tab bar is hidden entirely
  (back-compat invariant — post/page/author/etc. render unchanged).
  """
  def schema_groups(nil), do: []

  def schema_groups(schema) do
    case Map.get(schema, :groups) || Map.get(schema, "groups") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # Per-group icon (task barkpark-sfzn). Plugins that omit "icon" still
  # render — falls back to a neutral "circle" so the tab bar never blanks.
  defp tab_icon(%{"icon" => icon}) when is_binary(icon) and icon != "", do: icon
  defp tab_icon(_), do: "circle"

  @doc """
  Filter top-level fields to those visible on the currently selected tab.

  `nav_group == nil` — no active tab → show everything (legacy / no-groups
  schemas, plus the back-compat path while StudioLive is mounting).

  `nav_group` set — keep only fields whose `"group"` attribute matches the
  active tab. Fields without a `"group"` are not surfaced on any tab; the
  ONIX book schema tags every top-level field explicitly so this is a
  deliberate signal, not an oversight (decision recorded in this task).
  """
  def visible_fields(fields, nil), do: fields

  def visible_fields(fields, group_name) when is_binary(group_name) do
    Enum.filter(fields, fn f -> Map.get(f, "group") == group_name end)
  end

  # ── Document actions chrome (Task barkpark-3yq) ───────────────────────────
  # Three small components for the Sanity-style document actions: bulk
  # publish floating action bar, read-only secondary editor card, and the
  # secondary-doc picker modal. Kept here next to the other Studio chrome.

  @doc """
  Floating action bar shown at the bottom of the viewport when one or
  more documents are checkbox-selected on the active list pane. Hidden
  entirely when the set is empty so the bar never crowds normal browsing.

  Buttons emit `phx-click="bulk-publish"` / `"bulk-unpublish"` /
  `"bulk-clear"` against the parent LV. The "Selected" count comes from
  `MapSet.size(@selected_doc_ids)`.
  """
  attr :selected_doc_ids, :any, required: true

  def bulk_action_bar(assigns) do
    count = MapSet.size(assigns.selected_doc_ids)
    assigns = assign(assigns, :count, count)

    ~H"""
    <%= if @count > 0 do %>
      <div class="bp-bulk-action-bar" role="region" aria-label="Bulk actions" data-test-id="bulk-action-bar">
        <span class="bp-bulk-action-count">
          <%= @count %> selected
        </span>
        <div class="bp-bulk-action-buttons">
          <button
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="bulk-publish"
            data-test-id="bulk-publish"
          >Publish selected</button>
          <button
            type="button"
            class="btn btn-sm"
            phx-click="bulk-unpublish"
            data-test-id="bulk-unpublish"
          >Unpublish selected</button>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="bulk-clear"
            data-test-id="bulk-clear"
          >Clear</button>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Read-only secondary editor card — the "Open in new pane" target. Shows
  the secondary doc's title, type, status pill, and a flat key-value
  table of its content fields. v1 is deliberately read-only so primary
  autosave never collides with a secondary edit (decision in task brief).
  The Close button reveals the floating "Open another" button again via
  the `close-secondary` event.
  """
  attr :secondary_doc, :map, default: nil
  attr :secondary_schema, :map, default: nil
  attr :secondary_type, :string, default: nil

  def secondary_editor_card(assigns) do
    ~H"""
    <%= if @secondary_doc do %>
      <aside class="bp-secondary-pane" data-test-id="secondary-pane">
        <header class="bp-secondary-pane-header">
          <div class="bp-secondary-pane-title">
            <span class="badge badge-draft" :if={Barkpark.Content.draft?(@secondary_doc.doc_id)}>
              draft
            </span>
            <span class="badge" :if={!Barkpark.Content.draft?(@secondary_doc.doc_id)}>
              <%= @secondary_doc.status %>
            </span>
            <span class="bp-secondary-pane-type"><%= @secondary_type %></span>
            <strong><%= @secondary_doc.title || "Untitled" %></strong>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="close-secondary"
            data-test-id="close-secondary"
            aria-label="Close secondary pane"
          >×</button>
        </header>
        <div class="bp-secondary-pane-body">
          <dl class="bp-secondary-pane-fields">
            <%= for field <- secondary_visible_fields(@secondary_schema) do %>
              <% key = field["name"] %>
              <dt><%= field["title"] || key %></dt>
              <dd><%= secondary_format_value(get_in(@secondary_doc.content || %{}, [key])) %></dd>
            <% end %>
          </dl>
          <p class="bp-secondary-pane-readonly">Read-only — edit via primary pane.</p>
        </div>
      </aside>
    <% end %>
    """
  end

  defp secondary_visible_fields(nil), do: []

  defp secondary_visible_fields(%{fields: fields}) when is_list(fields) do
    Enum.reject(fields, &(&1["name"] in ["title", "status"]))
  end

  defp secondary_visible_fields(_), do: []

  defp secondary_format_value(nil), do: "—"
  defp secondary_format_value(""), do: "—"
  defp secondary_format_value(v) when is_binary(v), do: v
  defp secondary_format_value(v) when is_boolean(v), do: to_string(v)
  defp secondary_format_value(v) when is_number(v), do: to_string(v)
  defp secondary_format_value(v), do: inspect(v, limit: 50)

  @doc """
  Secondary-doc picker modal — reuses the reference-picker visual
  treatment so users get a familiar interaction. Filter is client-side
  string-contains against the candidates list bound on `open-secondary-picker`.
  Selecting a row fires `select-secondary`; clicking the backdrop or the
  ✕ fires `close-secondary-picker`.
  """
  attr :show_secondary_picker, :boolean, default: false
  attr :secondary_search, :string, default: ""
  attr :secondary_candidates, :list, default: []

  def secondary_picker_modal(assigns) do
    filtered =
      if assigns.secondary_search == "" do
        assigns.secondary_candidates
      else
        q = String.downcase(assigns.secondary_search)

        Enum.filter(assigns.secondary_candidates, fn c ->
          String.contains?(String.downcase(c.title || ""), q) or
            String.contains?(String.downcase(c.id || ""), q)
        end)
      end

    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <%= if @show_secondary_picker do %>
      <div class="modal-backdrop" phx-click="close-secondary-picker" data-test-id="secondary-picker-modal">
        <div class="modal-card" phx-click-away="close-secondary-picker" onclick="event.stopPropagation()">
          <div class="modal-header">
            <h3>Open in new pane</h3>
            <button class="btn btn-ghost btn-sm" phx-click="close-secondary-picker" aria-label="Close">×</button>
          </div>
          <div class="modal-body">
            <input
              type="text"
              class="form-input"
              placeholder="Search documents…"
              value={@secondary_search}
              phx-keyup="secondary-search"
              phx-debounce="150"
              autofocus
            />
            <ul class="bp-secondary-candidates">
              <%= for c <- @filtered do %>
                <li
                  class="bp-secondary-candidate"
                  phx-click="select-secondary"
                  phx-value-id={c.id}
                  data-test-id={"secondary-candidate-#{c.id}"}
                >
                  <strong><%= c.title %></strong>
                  <span class="bp-secondary-candidate-id"><%= c.id %></span>
                </li>
              <% end %>
              <%= if @filtered == [] do %>
                <li class="bp-secondary-empty">No matches.</li>
              <% end %>
            </ul>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
