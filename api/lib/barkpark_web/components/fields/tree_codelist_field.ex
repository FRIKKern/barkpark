defmodule BarkparkWeb.Components.Fields.TreeCodelistField do
  @moduledoc """
  Hierarchical-codelist picker LiveComponent (G4).

  Renders a tree browser for codelists whose entries form a parent/child
  hierarchy (e.g. Thema subject categories, ONIX codelist 93, ~3000 nodes).
  `CodelistField` dispatches to this component when the loaded codelist is
  tree-shaped (any value carries a non-nil `parent_id`) AND large enough
  (>100 entries) to justify the tree UI over a flat `<select>`.

  ## Single-select contract

  Unlike the legacy `ThemaTreePicker` (multi-select via MapSet), this
  component is **single-select** — its purpose is to slot into the same
  surface as `CodelistField`'s `<select>`. The picked value rides home via
  a hidden `<input type="hidden" name={@input_name} value={@selected}>`
  inside the editor form; clicks on tree rows update that hidden input
  and the autosave path picks it up like any other form change.

  Multi-value scenarios (a publisher wanting `themaSubjectCategory` as
  `arrayOf(codelist)`) belong upstream — `ArrayField` is responsible for
  the collection, and each row dispatches a single-select tree picker.

  ## Loading

  The tree is materialized in two queries (one for values, one for
  translations) via `Barkpark.Content.Codelists.tree/3`; safe for the
  ~3000-node Thema codelist per that function's docstring. We index the
  result into a flat `nodes_by_code` map for O(1) parent/children lookups
  during render and search.

  ## Empty-registry handling

  If `Codelists.tree/3` returns `[]` (no rows registered under
  `(plugin_name, list_id)`), the component renders its own
  `bp-codelist-empty` placeholder mirroring `CodelistField`'s disabled
  fallback. `CodelistField` will normally not dispatch in that case
  (the option count is zero, the predicate fails), so this branch is a
  belt-and-braces guard for direct callers.

  ## Required assigns

    * `:id` (LiveComponent identity, required by Phoenix)
    * `:field` — the `%Field{}` whose `name`, `title`, `version` we surface
    * `:value` — the current code (string) or `nil`
    * `:options` — the flattened option list (passed for API symmetry; the
      component does not require it but accepts it so callers can hand off
      the same options they would have passed to a flat select)
    * `:on_change` — `phx-change` event name on the surrounding form
    * `:plugin_name` — codelist plugin discriminator (e.g. `"onixedit"`)
    * `:list_id` — codelist id (e.g. `"onixedit:thema"`)
    * `:readonly` — disables clicks when truthy (default `false`)
    * `:input_name` — name attribute for the hidden input (default `""`)
    * `:languages` — preferred display languages (default `["nob", "eng"]`)
    * `:tree_loader` — `(plugin_name, list_id, languages) -> [tree_node]`
      test seam; defaults to `&Barkpark.Content.Codelists.tree/3`

  ## CSS hooks (G4 scope: markers only, no styling)

  Semantic class names land on every interactive element so the styling
  pass that follows can wire visuals without touching markup:

    * `bp-tree-codelist` — the root container
    * `bp-tree-search` — the search input
    * `bp-tree-list` — the `<ul role="tree">`
    * `bp-tree-row` — each `<li role="treeitem">`
    * `bp-tree-row-selected` — added when the row is the current `:value`
    * `bp-tree-row-matched` — added when search highlights this row
    * `bp-tree-toggle` — the expand/collapse chevron button
    * `bp-tree-code` — the codelist code span (e.g. `"FBA"`)
    * `bp-tree-label` — the human-readable label span
  """

  use BarkparkWeb, :live_component

  alias Barkpark.Content.Codelists

  @default_languages ["nob", "eng"]
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
       selected: nil,
       search_query: "",
       matched: nil,
       plugin_name: "core",
       list_id: "",
       languages: @default_languages,
       on_change: nil,
       input_name: "",
       readonly: false,
       field: nil,
       options: [],
       tree_loader: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    plugin_name = Map.get(assigns, :plugin_name, socket.assigns.plugin_name)
    list_id = Map.get(assigns, :list_id, socket.assigns.list_id)
    languages = Map.get(assigns, :languages, socket.assigns.languages || @default_languages)
    selected = Map.get(assigns, :value, socket.assigns.selected)

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:field, Map.get(assigns, :field, socket.assigns.field))
      |> assign(:options, Map.get(assigns, :options, socket.assigns.options))
      |> assign(:on_change, Map.get(assigns, :on_change, socket.assigns.on_change))
      |> assign(:input_name, Map.get(assigns, :input_name, socket.assigns.input_name) || "")
      |> assign(:readonly, Map.get(assigns, :readonly, socket.assigns.readonly) || false)
      |> assign(:plugin_name, plugin_name)
      |> assign(:list_id, list_id)
      |> assign(:languages, languages)
      |> assign(:selected, selected)
      |> assign(:tree_loader, Map.get(assigns, :tree_loader, socket.assigns.tree_loader))
      |> maybe_load_tree()
      |> auto_expand_to_selected()

    {:ok, socket}
  end

  # ── Event handlers ────────────────────────────────────────────────────────

  @impl true
  def handle_event("tree_node_toggle", %{"code" => code}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, code) do
        MapSet.delete(socket.assigns.expanded, code)
      else
        MapSet.put(socket.assigns.expanded, code)
      end

    {:noreply, assign(socket, expanded: expanded)}
  end

  def handle_event("tree_node_select", %{"code" => code}, socket) do
    if socket.assigns.readonly do
      {:noreply, socket}
    else
      {:noreply, assign(socket, selected: code)}
    end
  end

  def handle_event("tree_search_input", %{"value" => query}, socket) do
    apply_search(socket, query)
  end

  def handle_event("tree_search_clear", _params, socket) do
    {:noreply, assign(socket, search_query: "", matched: nil)}
  end

  # ── Loading ───────────────────────────────────────────────────────────────

  defp maybe_load_tree(%{assigns: %{loaded?: true}} = socket), do: socket

  defp maybe_load_tree(socket) do
    %{plugin_name: plugin, list_id: list_id, languages: langs} = socket.assigns
    loader = socket.assigns.tree_loader || (&Codelists.tree/3)

    tree =
      try do
        loader.(plugin, list_id, languages: langs)
      rescue
        _ -> []
      end

    {nodes_by_code, roots} = index_tree(tree)

    assign(socket,
      loaded?: true,
      nodes_by_code: nodes_by_code,
      roots: roots
    )
  end

  defp index_tree(tree) when is_list(tree) do
    {nodes, roots} = walk_tree(tree, nil, 0, %{}, [])
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

  defp auto_expand_to_selected(%{assigns: %{selected: nil}} = socket), do: socket

  defp auto_expand_to_selected(%{assigns: %{selected: code}} = socket) when is_binary(code) do
    expanded =
      socket.assigns.nodes_by_code
      |> ancestors_of(code)
      |> Enum.reduce(socket.assigns.expanded, &MapSet.put(&2, &1))

    assign(socket, expanded: expanded)
  end

  defp auto_expand_to_selected(socket), do: socket

  defp ancestors_of(nodes, code) do
    case Map.get(nodes, code) do
      nil -> []
      %{parent_code: nil} -> []
      %{parent_code: parent} -> [parent | ancestors_of(nodes, parent)]
    end
  end

  # ── Search ────────────────────────────────────────────────────────────────

  defp apply_search(socket, query) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, search_query: "", matched: nil)}
    else
      matched = compute_matched(socket.assigns, query)
      {:noreply, assign(socket, search_query: query, matched: matched)}
    end
  end

  defp compute_matched(assigns, query) do
    %{nodes_by_code: nodes} = assigns
    needle = String.downcase(query)

    hits =
      nodes
      |> Map.values()
      |> Enum.filter(fn %{code: code, label: label} ->
        String.contains?(String.downcase(code), needle) or
          String.contains?(String.downcase(label || ""), needle)
      end)
      |> Enum.take(@search_limit)

    Enum.reduce(hits, MapSet.new(), fn %{code: code}, acc ->
      acc
      |> MapSet.put(code)
      |> add_ancestors(code, nodes)
    end)
  end

  defp add_ancestors(set, code, nodes) do
    case Map.get(nodes, code) do
      %{parent_code: nil} -> set
      %{parent_code: parent} -> set |> MapSet.put(parent) |> add_ancestors(parent, nodes)
      _ -> set
    end
  end

  # ── Visibility ────────────────────────────────────────────────────────────

  # Search-mode: every matched code is visible regardless of expanded state.
  # Browse-mode: roots are always visible; children only when their parent is expanded.
  defp visible_codes(%{matched: matched, nodes_by_code: nodes, roots: roots})
       when not is_nil(matched) do
    walk_visible(
      roots,
      nodes,
      fn code -> MapSet.member?(matched, code) end,
      fn _code -> true end
    )
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

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:visible_rows, visible_rows(assigns))
      |> assign(:empty?, assigns.loaded? and map_size(assigns.nodes_by_code) == 0)

    ~H"""
    <div
      id={@id}
      class="bp-field bp-field-codelist bp-tree-codelist"
      data-field-type="codelist"
      data-field-name={@field && @field.name}
      data-codelist-id={"#{@plugin_name}:#{@list_id}"}
      data-codelist-version={@field && @field.version && to_string(@field.version)}
    >
      <%= if @empty? do %>
        <select
          class="bp-input bp-input-codelist bp-codelist-empty"
          name={@input_name}
          disabled
          data-codelist-empty="true"
        >
          <option value="">(no codelist registered: <%= @plugin_name %>:<%= @list_id %>)</option>
        </select>
      <% else %>
        <input
          type="hidden"
          name={@input_name}
          value={@selected || ""}
          data-tree-selected="true"
        />

        <div class="bp-tree-toolbar">
          <input
            type="text"
            class="bp-input bp-tree-search"
            placeholder="Search codes or labels…"
            value={@search_query}
            phx-keyup="tree_search_input"
            phx-debounce="200"
            phx-target={@myself}
            disabled={@readonly}
          />
          <%= if @search_query != "" do %>
            <button
              type="button"
              class="bp-btn bp-tree-search-clear"
              phx-click="tree_search_clear"
              phx-target={@myself}
            >Clear</button>
          <% end %>
        </div>

        <ul class="bp-tree-list" role="tree">
          <%= if @visible_rows == [] do %>
            <li class="bp-tree-empty">
              <%= if @search_query != "" do %>
                No matches for "<%= @search_query %>".
              <% else %>
                No entries.
              <% end %>
            </li>
          <% else %>
            <%= for row <- @visible_rows do %>
              <li
                class={row.class}
                role="treeitem"
                aria-selected={row.aria_selected}
                aria-expanded={row.aria_expanded}
                data-code={row.code}
                data-depth={row.depth}
                data-selected={row.data_selected}
                data-matched={row.data_matched}
                style={row.style}
              >
                <%= if row.has_children? do %>
                  <button
                    type="button"
                    class="bp-tree-toggle"
                    phx-click="tree_node_toggle"
                    phx-value-code={row.code}
                    phx-target={@myself}
                    aria-label={row.toggle_label}
                  ><%= row.toggle_glyph %></button>
                <% else %>
                  <span class="bp-tree-toggle bp-tree-toggle-leaf" aria-hidden="true"></span>
                <% end %>
                <button
                  type="button"
                  class={row.select_class}
                  phx-click="tree_node_select"
                  phx-value-code={row.code}
                  phx-target={@myself}
                  disabled={@readonly}
                >
                  <span class="bp-tree-code"><%= row.code %></span>
                  <span class="bp-tree-label" title={row.label}><%= row.label %></span>
                </button>
              </li>
            <% end %>
          <% end %>
        </ul>
      <% end %>
    </div>
    """
  end

  # Pre-compute row maps so HEEx change tracking stays cheap.
  defp visible_rows(assigns) do
    codes = visible_codes(assigns)

    Enum.map(codes, fn code ->
      node = Map.fetch!(assigns.nodes_by_code, code)
      has_children? = node.children != []
      expanded? = MapSet.member?(assigns.expanded, code)
      selected? = assigns.selected == code

      matched? =
        not is_nil(assigns.matched) and MapSet.member?(assigns.matched, code)

      indent = node.depth * 16

      %{
        code: code,
        label: node.label,
        depth: node.depth,
        has_children?: has_children?,
        class: row_class(selected?, matched?),
        select_class: select_class(selected?),
        aria_selected: if(selected?, do: "true", else: "false"),
        aria_expanded:
          cond do
            not has_children? -> nil
            expanded? -> "true"
            true -> "false"
          end,
        data_selected: if(selected?, do: "true", else: "false"),
        data_matched: if(matched?, do: "true", else: "false"),
        style: "padding-left: #{indent}px;",
        toggle_label: if(expanded?, do: "Collapse", else: "Expand"),
        toggle_glyph: if(expanded?, do: "▼", else: "▶")
      }
    end)
  end

  defp row_class(selected?, matched?) do
    [
      "bp-tree-row",
      selected? && "bp-tree-row-selected",
      matched? && "bp-tree-row-matched"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp select_class(true), do: "bp-tree-row-button bp-tree-row-button-selected"
  defp select_class(_), do: "bp-tree-row-button"
end
