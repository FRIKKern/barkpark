defmodule BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor.ThemaTreePicker do
  @moduledoc """
  Phase 5 WI2 — Thema subject category tree picker LiveComponent.

  Renders a hierarchical browser for ONIX codelist 93 (`onixedit:thema`,
  ~3000 nodes deep). Used by the BookEditor Subjects tab. Multi-select with
  checkboxes, expand/collapse, search-with-ancestor-highlight, and full
  keyboard navigation.

  ## Build-time vs runtime loading

  `Barkpark.Content.Codelists.tree/3` materializes the full codelist in two
  queries — one for values, one for translations — and assembles in memory.
  Its docstring explicitly states this is "safe to materialize for ~3000-entry
  trees like Thema (codelist 93)". We therefore load the whole tree once on
  `update/2`, then **lazy-RENDER** visible nodes (only roots + descendants of
  expanded codes). This avoids a query-per-expand round trip and keeps the
  component responsive even with deep navigation.

  We index the materialized tree into a flat `nodes_by_code` map for O(1)
  parent/children lookups during render and search.

  ## Selection emission contract

  The component owns its `selected` MapSet and emits changes to the parent
  LiveView via `send(self(), {on_change, MapSet.t()})`. The parent must
  `handle_info/2` the message. The default tag is `:thema_selection_changed`;
  parents pass a different atom via the `:on_change` assign if they need to
  disambiguate multiple pickers.

  Message shape:

      {on_change_tag, MapSet.t(String.t())}

  ## Modal vs inline

  Built as an **inline LiveComponent** — the parent decides whether to wrap
  it in a modal (PRD line) or embed it directly (this WI's brief). Picker
  has no modal chrome; it's just the tree, the pill bar, the search input,
  and the breadcrumb.

  ## Required assigns from parent

    * `:id` (LiveComponent identity, required)
    * `:selected` — MapSet of currently-selected Thema codes (defaults to `MapSet.new/0`)
    * `:plugin_name` — defaults to `"onixedit"`
    * `:list_id` — defaults to `"onixedit:thema"`
    * `:languages` — preferred display languages, defaults to `["nob", "eng"]`
    * `:on_change` — atom message tag, defaults to `:thema_selection_changed`

  ## Keyboard map

  | Key         | Action                                                  |
  |-------------|---------------------------------------------------------|
  | ArrowDown   | Move focus to next visible node                          |
  | ArrowUp     | Move focus to previous visible node                      |
  | ArrowRight  | Expand current node, or move to first child if expanded  |
  | ArrowLeft   | Collapse current node, or move to parent if collapsed    |
  | Enter/Space | Toggle selection of focused node                         |
  | Escape      | Clear search query                                       |
  """

  use BarkparkWeb, :live_component

  alias Barkpark.Content.Codelists

  @default_plugin "onixedit"
  @default_list_id "onixedit:thema"
  @default_languages ["nob", "eng"]
  @default_event :thema_selection_changed
  @search_limit 200

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       loaded?: false,
       nodes_by_code: %{},
       roots: [],
       expanded: MapSet.new(),
       focused_code: nil,
       search_query: "",
       matched: nil,
       plugin_name: @default_plugin,
       list_id: @default_list_id,
       languages: @default_languages,
       on_change: @default_event,
       selected: MapSet.new()
     )}
  end

  @impl true
  def update(assigns, socket) do
    plugin_name = Map.get(assigns, :plugin_name, socket.assigns.plugin_name || @default_plugin)
    list_id = Map.get(assigns, :list_id, socket.assigns.list_id || @default_list_id)
    languages = Map.get(assigns, :languages, socket.assigns.languages || @default_languages)
    on_change = Map.get(assigns, :on_change, socket.assigns.on_change || @default_event)
    selected = normalize_selected(Map.get(assigns, :selected))

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:plugin_name, plugin_name)
      |> assign(:list_id, list_id)
      |> assign(:languages, languages)
      |> assign(:on_change, on_change)
      |> assign(:selected, selected)
      |> maybe_load_tree()

    {:ok, socket}
  end

  # ── Event handlers ────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_expand", %{"code" => code}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, code) do
        MapSet.delete(socket.assigns.expanded, code)
      else
        MapSet.put(socket.assigns.expanded, code)
      end

    {:noreply, assign(socket, expanded: expanded, focused_code: code)}
  end

  def handle_event("toggle_select", %{"code" => code}, socket) do
    {:noreply, toggle_select(socket, code)}
  end

  def handle_event("focus_node", %{"code" => code}, socket) do
    {:noreply, assign(socket, focused_code: code)}
  end

  def handle_event("remove_selected", %{"code" => code}, socket) do
    selected = MapSet.delete(socket.assigns.selected, code)
    notify_parent(socket, selected)
    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("search", %{"value" => query}, socket) do
    apply_search(socket, query)
  end

  def handle_event("search", %{"q" => query}, socket) do
    apply_search(socket, query)
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, search_query: "", matched: nil)}
  end

  def handle_event("key", %{"key" => key}, socket) do
    handle_key(key, socket)
  end

  def handle_event("focus_breadcrumb", %{"code" => code}, socket) do
    expanded = expand_to(socket.assigns.expanded, socket.assigns.nodes_by_code, code)
    {:noreply, assign(socket, focused_code: code, expanded: expanded)}
  end

  # ── Loading ───────────────────────────────────────────────────────────────

  defp maybe_load_tree(%{assigns: %{loaded?: true}} = socket), do: socket

  defp maybe_load_tree(socket) do
    %{plugin_name: plugin, list_id: list_id, languages: langs} = socket.assigns

    tree = Codelists.tree(plugin, list_id, languages: langs)
    {nodes_by_code, roots} = index_tree(tree)

    assign(socket,
      loaded?: true,
      nodes_by_code: nodes_by_code,
      roots: roots,
      focused_code: socket.assigns.focused_code || List.first(roots)
    )
  end

  defp index_tree(tree) when is_list(tree) do
    nodes = %{}
    {nodes, roots} = walk_tree(tree, nil, 0, nodes, [])
    {nodes, Enum.reverse(roots)}
  end

  defp walk_tree([], _parent, _depth, nodes, acc), do: {nodes, acc}

  defp walk_tree([node | rest], parent_code, depth, nodes, acc) do
    code = Map.fetch!(node, :value)
    label = Map.get(node, :label, code)
    children = Map.get(node, :children, []) || []
    child_codes = Enum.map(children, & &1.value)

    nodes =
      Map.put(nodes, code, %{
        code: code,
        label: label,
        parent_code: parent_code,
        children: child_codes,
        depth: depth
      })

    {nodes, _children_acc} = walk_tree(children, code, depth + 1, nodes, [])

    walk_tree(rest, parent_code, depth, nodes, [code | acc])
  end

  # ── Search ────────────────────────────────────────────────────────────────

  defp apply_search(socket, query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" ->
        {:noreply, assign(socket, search_query: "", matched: nil)}

      true ->
        matched = compute_matched(socket.assigns, query)
        {:noreply, assign(socket, search_query: query, matched: matched)}
    end
  end

  defp compute_matched(assigns, query) do
    %{plugin_name: plugin, list_id: list_id, nodes_by_code: nodes} = assigns
    needle = String.downcase(query)

    hits =
      case Codelists.tree(plugin, list_id, languages: assigns.languages) do
        [] ->
          []

        tree ->
          tree
          |> flatten_for_search()
          |> Enum.filter(fn %{value: code, label: label} ->
            String.contains?(String.downcase(code), needle) or
              String.contains?(String.downcase(label || ""), needle)
          end)
          |> Enum.take(@search_limit)
      end

    Enum.reduce(hits, MapSet.new(), fn %{value: code}, acc ->
      acc
      |> MapSet.put(code)
      |> add_ancestors(code, nodes)
    end)
  end

  defp flatten_for_search(tree) do
    Enum.flat_map(tree, fn node ->
      [%{value: node.value, label: node.label} | flatten_for_search(node.children || [])]
    end)
  end

  defp add_ancestors(set, code, nodes) do
    case Map.get(nodes, code) do
      %{parent_code: nil} -> set
      %{parent_code: parent} -> set |> MapSet.put(parent) |> add_ancestors(parent, nodes)
      _ -> set
    end
  end

  defp expand_to(expanded, _nodes, nil), do: expanded

  defp expand_to(expanded, nodes, code) do
    case Map.get(nodes, code) do
      nil -> expanded
      %{parent_code: nil} -> expanded
      %{parent_code: parent} -> expanded |> MapSet.put(parent) |> expand_to(nodes, parent)
    end
  end

  # ── Selection ─────────────────────────────────────────────────────────────

  defp toggle_select(socket, code) do
    selected =
      if MapSet.member?(socket.assigns.selected, code) do
        MapSet.delete(socket.assigns.selected, code)
      else
        MapSet.put(socket.assigns.selected, code)
      end

    notify_parent(socket, selected)
    assign(socket, selected: selected, focused_code: code)
  end

  defp notify_parent(socket, selected) do
    send(self(), {socket.assigns.on_change, selected})
  end

  defp normalize_selected(nil), do: MapSet.new()
  defp normalize_selected(%MapSet{} = set), do: set
  defp normalize_selected(list) when is_list(list), do: MapSet.new(list)
  defp normalize_selected(_), do: MapSet.new()

  # ── Keyboard ──────────────────────────────────────────────────────────────

  defp handle_key("Escape", socket) do
    {:noreply, assign(socket, search_query: "", matched: nil)}
  end

  defp handle_key(key, socket) when key in ["Enter", " ", "Spacebar"] do
    case socket.assigns.focused_code do
      nil -> {:noreply, socket}
      code -> {:noreply, toggle_select(socket, code)}
    end
  end

  defp handle_key("ArrowDown", socket) do
    {:noreply, move_focus(socket, +1)}
  end

  defp handle_key("ArrowUp", socket) do
    {:noreply, move_focus(socket, -1)}
  end

  defp handle_key("ArrowRight", socket) do
    code = socket.assigns.focused_code

    case Map.get(socket.assigns.nodes_by_code, code) do
      %{children: [first_child | _]} ->
        if MapSet.member?(socket.assigns.expanded, code) do
          {:noreply, assign(socket, focused_code: first_child)}
        else
          {:noreply, assign(socket, expanded: MapSet.put(socket.assigns.expanded, code))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_key("ArrowLeft", socket) do
    code = socket.assigns.focused_code

    cond do
      is_nil(code) ->
        {:noreply, socket}

      MapSet.member?(socket.assigns.expanded, code) ->
        {:noreply, assign(socket, expanded: MapSet.delete(socket.assigns.expanded, code))}

      true ->
        case Map.get(socket.assigns.nodes_by_code, code) do
          %{parent_code: parent} when is_binary(parent) ->
            {:noreply, assign(socket, focused_code: parent)}

          _ ->
            {:noreply, socket}
        end
    end
  end

  defp handle_key(_other, socket), do: {:noreply, socket}

  defp move_focus(socket, delta) do
    visible = visible_codes(socket.assigns)
    current = socket.assigns.focused_code

    new_code =
      case Enum.find_index(visible, &(&1 == current)) do
        nil ->
          List.first(visible) || current

        idx ->
          target = idx + delta
          target = max(0, min(length(visible) - 1, target))
          Enum.at(visible, target, current)
      end

    assign(socket, focused_code: new_code)
  end

  # ── Visibility ────────────────────────────────────────────────────────────

  # Returns the ordered list of currently visible codes (in render order).
  # Used by keyboard nav and by render/1.
  defp visible_codes(%{matched: matched, nodes_by_code: nodes, roots: roots} = _assigns)
       when not is_nil(matched) do
    # Search mode: render every matched node, in tree order, by walking roots.
    walk_visible(roots, nodes, fn code -> MapSet.member?(matched, code) end, fn _code ->
      true
    end)
  end

  defp visible_codes(%{nodes_by_code: nodes, roots: roots, expanded: expanded}) do
    walk_visible(
      roots,
      nodes,
      fn _code -> true end,
      fn code -> MapSet.member?(expanded, code) end
    )
  end

  defp walk_visible(codes, nodes, visible_fn, recurse_fn) do
    Enum.flat_map(codes, fn code ->
      if visible_fn.(code) do
        case Map.get(nodes, code) do
          nil ->
            []

          %{children: children} ->
            if recurse_fn.(code) do
              [code | walk_visible(children, nodes, visible_fn, recurse_fn)]
            else
              [code]
            end
        end
      else
        []
      end
    end)
  end

  defp ancestor_chain(_nodes, nil), do: []

  defp ancestor_chain(nodes, code) do
    case Map.get(nodes, code) do
      nil -> []
      %{parent_code: nil} = node -> [node]
      %{parent_code: parent} = node -> ancestor_chain(nodes, parent) ++ [node]
    end
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:visible_rows, visible_rows(assigns))
      |> assign(:breadcrumb, ancestor_chain(assigns.nodes_by_code, assigns.focused_code))
      |> assign(
        :selected_list,
        assigns.selected |> MapSet.to_list() |> Enum.sort()
      )

    ~H"""
    <div
      id={@id}
      class="thema-tree-picker"
      data-test-id="thema-tree-picker"
      phx-window-keydown="key"
      phx-target={@myself}
    >
      <div class="thema-picker-toolbar" style="display: flex; gap: 8px; margin-bottom: 8px;">
        <input
          type="text"
          class="form-input"
          placeholder="Search Thema codes or labels…"
          value={@search_query}
          phx-keyup="search"
          phx-debounce="200"
          phx-target={@myself}
          data-test-id="thema-picker-search"
        />
        <%= if @search_query != "" do %>
          <button
            type="button"
            class="btn btn-sm"
            phx-click="clear_search"
            phx-target={@myself}
            data-test-id="thema-picker-clear-search"
          >Clear</button>
        <% end %>
      </div>

      <%= if @selected_list != [] do %>
        <div class="thema-picker-pills" data-test-id="thema-picker-pills"
             style="display: flex; flex-wrap: wrap; gap: 4px; margin-bottom: 8px;">
          <%= for code <- @selected_list do %>
            <span class="badge" data-test-id={"thema-pill-#{code}"}
                  style="display: inline-flex; align-items: center; gap: 4px;">
              <%= code %>
              <%= case Map.get(@nodes_by_code, code) do %>
                <% %{label: label} -> %><span style="opacity: 0.7;">— <%= label %></span>
                <% _ -> %>
              <% end %>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="remove_selected"
                phx-value-code={code}
                phx-target={@myself}
                aria-label={"Remove #{code}"}
                data-test-id={"thema-pill-remove-#{code}"}
                style="padding: 0 4px; line-height: 1;"
              >×</button>
            </span>
          <% end %>
        </div>
      <% end %>

      <%= if @breadcrumb != [] do %>
        <nav class="thema-picker-breadcrumb" data-test-id="thema-picker-breadcrumb"
             style="display: flex; gap: 4px; font-size: 12px; color: var(--text-muted); margin-bottom: 8px;">
          <%= for {node, idx} <- Enum.with_index(@breadcrumb) do %>
            <%= if idx > 0 do %><span>›</span><% end %>
            <button
              type="button"
              class="btn-link"
              phx-click="focus_breadcrumb"
              phx-value-code={node.code}
              phx-target={@myself}
              data-test-id={"thema-breadcrumb-#{node.code}"}
              style="background: none; border: none; padding: 0; color: inherit; cursor: pointer; text-decoration: underline;"
            ><%= node.code %></button>
          <% end %>
        </nav>
      <% end %>

      <ul
        class="thema-tree"
        role="tree"
        data-test-id="thema-tree"
        style="list-style: none; padding: 0; margin: 0; max-height: 480px; overflow-y: auto; border: 1px solid var(--border-muted); border-radius: 4px;"
      >
        <%= if not @loaded? or @visible_rows == [] do %>
          <li class="thema-tree-empty" data-test-id="thema-tree-empty"
              style="padding: 12px; color: var(--text-muted); font-size: 13px;">
            <%= cond do %>
              <% not @loaded? -> %>Loading…
              <% @search_query != "" -> %>No matches for "<%= @search_query %>".
              <% true -> %>No Thema codelist registered.
            <% end %>
          </li>
        <% else %>
          <%= for row <- @visible_rows do %>
            <li
              class={row.class}
              role="treeitem"
              aria-selected={row.aria_selected}
              aria-expanded={row.aria_expanded}
              data-test-id={"thema-node-#{row.code}"}
              data-code={row.code}
              data-focused={row.data_focused}
              data-selected={row.data_selected}
              data-matched={row.data_matched}
              style={row.style}
              phx-click="focus_node"
              phx-value-code={row.code}
              phx-target={@myself}
            >
              <%= if row.has_children? do %>
                <button
                  type="button"
                  class="thema-tree-chevron"
                  phx-click="toggle_expand"
                  phx-value-code={row.code}
                  phx-target={@myself}
                  aria-label={row.toggle_label}
                  data-test-id={"thema-toggle-#{row.code}"}
                  style="background: none; border: none; padding: 0 4px; cursor: pointer; width: 20px;"
                ><%= row.toggle_glyph %></button>
              <% else %>
                <span style="display: inline-block; width: 20px;"></span>
              <% end %>
              <input
                type="checkbox"
                checked={row.selected?}
                phx-click="toggle_select"
                phx-value-code={row.code}
                phx-target={@myself}
                data-test-id={"thema-checkbox-#{row.code}"}
                aria-label={"Select #{row.code}"}
              />
              <span class="thema-tree-code" style="font-family: var(--font-mono, monospace); font-weight: 600; min-width: 64px;"><%= row.code %></span>
              <span class="thema-tree-label" title={row.label} style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"><%= row.label %></span>
            </li>
          <% end %>
        <% end %>
      </ul>
    </div>
    """
  end

  # Build a list of fully-resolved row maps for the template. Pre-computing
  # everything keeps the ~H comprehension free of function calls (which trip up
  # HEEx change-tracking when they themselves return Rendered structs).
  defp visible_rows(assigns) do
    codes = visible_codes(assigns)

    Enum.map(codes, fn code ->
      node = Map.fetch!(assigns.nodes_by_code, code)
      has_children? = node.children != []
      expanded? = MapSet.member?(assigns.expanded, code)
      selected? = MapSet.member?(assigns.selected, code)
      focused? = assigns.focused_code == code

      matched_leaf? =
        not is_nil(assigns.matched) and
          MapSet.member?(assigns.matched, code) and
          not (has_children? and Enum.any?(node.children, &MapSet.member?(assigns.matched, &1)))

      indent = node.depth * 16

      %{
        code: code,
        label: node.label,
        has_children?: has_children?,
        selected?: selected?,
        class: node_class(selected?, focused?, matched_leaf?),
        aria_selected: if(selected?, do: "true", else: "false"),
        aria_expanded:
          cond do
            not has_children? -> nil
            expanded? -> "true"
            true -> "false"
          end,
        data_focused: if(focused?, do: "true", else: "false"),
        data_selected: if(selected?, do: "true", else: "false"),
        data_matched: if(matched_leaf?, do: "true", else: "false"),
        style:
          "display: flex; align-items: center; gap: 4px; padding: 2px 8px 2px #{8 + indent}px; cursor: pointer;" <>
            focus_style(focused?) <> match_style(matched_leaf?),
        toggle_label: if(expanded?, do: "Collapse", else: "Expand"),
        toggle_glyph: if(expanded?, do: "▼", else: "▶")
      }
    end)
  end

  defp node_class(selected?, focused?, matched?) do
    [
      "thema-tree-node",
      selected? && "thema-tree-node-selected",
      focused? && "thema-tree-node-focused",
      matched? && "thema-tree-node-matched"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp focus_style(true), do: " outline: 2px solid var(--accent, #4a9eff); outline-offset: -2px;"
  defp focus_style(_), do: ""

  defp match_style(true), do: " background: rgba(255, 215, 0, 0.18);"
  defp match_style(_), do: ""
end
