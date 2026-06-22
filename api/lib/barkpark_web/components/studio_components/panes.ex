defmodule BarkparkWeb.StudioComponents.Panes do
  @moduledoc """
  Pane-layout building blocks for the Barkpark Studio — the structural
  columns, rows, dividers, section headers, and doc-list items that every
  Studio LiveView pane composes from. Extracted from the former monolithic
  `BarkparkWeb.StudioComponents`; re-exported there as a thin facade so
  every `<.pane_column>` / `import BarkparkWeb.StudioComponents` call site
  keeps working unchanged.

  See `api/lib/barkpark_web/layouts/root.html.heex` for the CSS.
  """
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
end
