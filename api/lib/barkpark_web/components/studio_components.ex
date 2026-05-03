defmodule BarkparkWeb.StudioComponents do
  @moduledoc "Reusable components for the Barkpark Studio."
  use Phoenix.Component

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
end
