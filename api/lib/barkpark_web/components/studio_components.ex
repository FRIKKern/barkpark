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
            <div class="pane-header-actions"><%= Phoenix.HTML.raw(render_slot(@header_actions)) %></div>
          <% end %>
        </div>
        <%= render_slot(@inner_block) %>
      </div>
    <% end %>
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
