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

  attr :schema, :map, required: true

  def schema_card(assigns) do
    ~H"""
    <a href={"/studio/#{@schema.name}"} class="schema-card">
      <div class="schema-icon"><%= @schema.icon %></div>
      <div class="schema-name"><%= @schema.title %></div>
      <span class={"badge badge-#{@schema.visibility}"}><%= @schema.visibility %></span>
    </a>
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

  slot :header_actions
  slot :inner_block, required: true

  def pane_column(assigns) do
    extra_classes =
      [
        assigns[:last] && "pane-column--last",
        assigns[:flex] && "pane-column--flex"
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
  Passive Studio sidebar — renders the top-level structure tree as plain
  anchor links. Used by plugin LiveViews (BookView, BookEditor) that
  render outside StudioLive's interactive `<.pane_layout>` so the user
  retains a way to navigate back into Studio.

  Intentionally has NO `phx-click` — events would otherwise route to the
  enclosing LiveView (BookView etc.) which has no matching handler. Each
  item is an `<a href>` that triggers a normal LiveView navigation back
  into StudioLive.

  Attributes:
    * `:dataset`       — (required) string, current dataset name
    * `:selected_path` — (optional) list, current nav path; the first
                         segment is matched against item ids to mark the
                         active link
  """
  attr :dataset, :string, required: true
  attr :selected_path, :list, default: []

  def studio_sidebar(assigns) do
    structure = Barkpark.Structure.build(assigns.dataset)
    selected_id = List.first(assigns.selected_path)

    assigns =
      assigns
      |> assign(:structure, structure)
      |> assign(:selected_id, selected_id)

    ~H"""
    <aside
      class="studio-sidebar"
      style="width:240px;flex-shrink:0;overflow-y:auto;border-right:1px solid var(--border-color, #e5e7eb);padding:.5rem;"
    >
      <div
        class="studio-sidebar-header"
        style="font-weight:600;padding:.5rem .75rem;color:var(--muted-color,#6b7280);"
      ><%= @structure.title %></div>
      <%= for item <- @structure.items do %>
        <%= case item.type do %>
          <% :divider -> %>
            <div class="studio-sidebar-divider" style="height:1px;background:var(--border-color,#e5e7eb);margin:.5rem 0;"></div>
          <% _ -> %>
            <a
              href={"/studio/#{@dataset}/#{item.id}"}
              class={
                ["studio-sidebar-item", item.id == @selected_id && "studio-sidebar-item--active"]
                |> Enum.filter(& &1)
                |> Enum.join(" ")
              }
              style={
                "display:block;padding:.4rem .75rem;border-radius:4px;text-decoration:none;color:inherit;" <>
                  if(item.id == @selected_id, do: "font-weight:600;background:rgba(0,0,0,.04);", else: "")
              }
            >
              <%= if item.icon do %><span style="margin-right:.4rem;"><%= item.icon %></span><% end %><%= item.title %>
            </a>
        <% end %>
      <% end %>
    </aside>
    """
  end

  @doc """
  Sanity-style document chrome header for the editor pane. Emits the
  legacy `<div class="pane-header editor-header">` markup so it can
  replace StudioLive's hand-rolled header at studio_live.ex:1107
  byte-identically and also be reused by plugin LiveViews
  (BookView, BookEditor). The corresponding CSS lives in
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
                       Publish in StudioLive; Bokbasen/ONIX export in
                       BookEditor; Open-in-editor in BookView). Slot
                       contents render verbatim — preserve any
                       `data-test-id` attributes.
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
      <div style="display: flex; gap: 6px;">
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
  slot :inner_block, required: true

  def editor_field(assigns) do
    ~H"""
    <div class={"editor-field #{if @errors != [], do: "has-error"}"}>
      <label class="editor-field-label">
        <%= @label %>
        <%= if @required do %><span class="field-required">*</span><% end %>
        <%= if @type do %><span class="editor-field-type"><%= @type %></span><% end %>
      </label>
      <%= render_slot(@inner_block) %>
      <%= if @errors != [] do %>
        <div class="field-errors"><%= Enum.join(@errors, ", ") %></div>
      <% end %>
    </div>
    """
  end

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
  attr :id, :string, default: nil

  slot :trailing

  def pane_doc_item(assigns) do
    ~H"""
    <div
      id={@id}
      class={["pane-doc-item", @selected && "selected"] |> Enum.filter(& &1) |> Enum.join(" ")}
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
        <button type="submit" class="btn btn-ghost btn-sm" aria-label="Sign out">
          <.icon name="log-out" size={14} />
          Sign out
        </button>
      </.form>
    </div>
    """
  end

  @doc """
  Studio top-level tab navigation. Reads tab data from
  `BarkparkWeb.Studio.Nav.tabs/1` (single source of truth) and renders
  the canonical `<div class="studio-bar-tabs">` wrapper with one anchor
  per tab. The active tab gets the `active` modifier when its `id`
  matches `nav_section`.

  Caller wraps with `:if={assigns[:dataset]}` — the component itself
  does NOT guard, so an empty `<div class="studio-bar-tabs">` does not
  leak into the topbar when no dataset is set.
  """
  attr :dataset, :string, required: true
  attr :nav_section, :atom, default: nil

  def studio_tabs(assigns) do
    ~H"""
    <div class="studio-bar-tabs">
      <%= for tab <- BarkparkWeb.Studio.Nav.tabs(@dataset) do %>
        <a
          href={tab.path}
          class={"studio-tab #{if @nav_section == tab.id, do: "active"}"}
        ><%= tab.label %></a>
      <% end %>
    </div>
    """
  end

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
    <% rules = @field["validation"] || %{} %>
    <.editor_field
      label={@field["title"] || field_name}
      type={@field["type"]}
      required={rules["required"] == true}
      errors={Map.get(@validation_errors, field_name, [])}
    >
      <%= if PluginAdapter.v2?(@field) do %>
        <%= PluginAdapter.render(@parent_assigns, @field) %>
      <% else %>
        <FieldInputs.input field={@field} editor_form={@editor_form} dataset={@dataset} />
      <% end %>
    </.editor_field>
    """
  end

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

  def presence_nav(assigns) do
    ~H"""
    <div class="presence-nav" id="presence-hook" phx-hook="PresenceIdentity">
      <% others = Enum.reject(@presences, & &1.user_id == @user_id) %>
      <%= for p <- others do %>
        <% p_doc_title = resolve_presence_doc_title(p, @dataset) %>
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
      <div class="presence-me-group" phx-click="show-profile">
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

  defp resolve_presence_doc_title(presence, dataset) do
    type = presence.type
    doc_id = presence.doc_id

    if type && doc_id do
      case Barkpark.Content.get_document(doc_id, type, dataset) do
        {:ok, doc} ->
          doc.title || doc_id

        _ ->
          case Barkpark.Content.get_document("drafts.#{doc_id}", type, dataset) do
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
  `<.pane_column>` API change tracked in
  `docs/superpowers/plans/2026-04-14-unified-pane-components.md`.

  Plugin LVs (BookView, BookEditor) do NOT consume this component —
  their action sets diverge enough (Bokbasen pills, ONIX export, custom
  tab nav) that wrapping forces endless slots. They call
  `<.document_header>` directly and stay decoupled.

  Events bubble to StudioLive: save, autosave, show-history, delete-doc,
  publish, unpublish, plus the studio_field_renderer phx-click events
  (open-image-picker, clear-image, open-ref-picker, clear-ref).

  Slots:
    * `:extra_actions` — (optional) appended after Publish/Unpublish.
                          Currently unused; documented for plugin LVs.
    * `:empty_state`   — (optional) overrides the default
                          `<.empty_editor message="Select a document …">`.
  """
  attr :editor_doc, :map, default: nil
  attr :editor_schema, :map, default: nil
  attr :editor_form, :map, required: true
  attr :editor_is_draft, :boolean, default: false
  attr :dataset, :string, required: true
  attr :validation_errors, :map, default: %{}
  attr :save_status, :string, default: ""
  attr :presences, :list, default: []
  attr :parent_assigns, :map, default: %{}

  slot :extra_actions
  slot :empty_state

  def studio_editor_shell(assigns) do
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
            <% doc_presences = presences_on_doc(@presences, Barkpark.Content.published_id(@editor_doc.doc_id)) %>
            <%= if doc_presences != [] do %>
              <div class="presence-dots">
                <%= for p <- doc_presences do %>
                  <div class="presence-dot" style={"background: #{p.color}"} title={"#{Map.get(p, :name, "User")} is editing"}></div>
                <% end %>
              </div>
            <% end %>
          </:presence>
          <:actions>
            <button class="btn btn-ghost btn-sm" phx-click="show-history">History</button>
            <button class="btn btn-ghost btn-sm" phx-click="delete-doc" style="color: var(--destructive);">Delete</button>
            <%= if @editor_is_draft do %>
              <button class="btn btn-primary btn-sm" phx-click="publish">Publish</button>
            <% else %>
              <button class="btn btn-sm" phx-click="unpublish">Unpublish</button>
            <% end %>
            <%= render_slot(@extra_actions) %>
          </:actions>
        </.document_header>

        <div class="editor-body">
          <%= if @editor_schema do %>
            <div class="editor-meta">
              <.icon name={@editor_schema.icon} size={14} /> <%= @editor_schema.title %> &middot; <%= length(@editor_schema.fields) %> fields
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
              <%= for field <- Enum.reject(@editor_schema.fields, & &1["name"] == "title") do %>
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

  defp presences_on_doc(presences, doc_id) do
    Enum.filter(presences, &(&1.doc_id == doc_id))
  end

  defp get_title_validation(nil), do: nil

  defp get_title_validation(schema) do
    case Enum.find(schema.fields, &(&1["name"] == "title")) do
      %{"validation" => v} -> v
      _ -> nil
    end
  end
end
