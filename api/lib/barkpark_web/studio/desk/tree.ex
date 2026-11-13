defmodule BarkparkWeb.Studio.Desk.Tree do
  @moduledoc """
  The desk tree (`Barkpark.Structure.build/2`) read against a pane URL, for
  the desk slice. The Elixir twin of `parseDeskPanes` and `normalizeDesk` in
  the TanStack Studio's `app/src/lib/desk.ts`.

  Segment by segment: a desk list opens a menu, a type list a list, a
  singleton its document. Documents follow as in `Panes.parse/1`. A first
  segment that is no desk node (a type name from an old link) reads as a
  plain type list, so those links keep working.

  In a parent-child tree list (a node with `:tree`), an id opens that row's
  children: a list pane with the tree's node and `:tree_parent` set to the
  id. The same id again opens the row's document (Sanity's
  `buildCategoryTree`: the parent on top, its children below). The pane
  only says what to list; the page reads the children.

  A `groupBy` built with `defer_group_by: true` has no children until a
  pane opens it (`Barkpark.Structure.expand/3`). It stays on the desk as a
  menu, and a segment under it that names one of its groups (`<idx>-<key>`)
  opens a list of the grouped type with that group as its node.

  Left out, as the TanStack Studio leaves them out of its own desk: plugin
  links and plugin lists.
  """

  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.Desk.Panes

  @shown [:list, :divider, :document, :document_type_list]

  @doc """
  The tree as the slice shows it: only node types it can open, no empty
  lists. A deferred `groupBy` is not empty: its children come when opened.

  A list at the root that holds only singletons (Barkpark's "Settings",
  `Barkpark.Structure`) is drawn in place, as the TanStack Studio's root
  draws its singletons (B13): its title a divider that keeps the list's id,
  its documents rows.
  """
  @spec normalize(struct()) :: struct()
  def normalize(%Node{} = root), do: root |> trim() |> inline_singletons()

  defp trim(%Node{} = node) do
    items =
      (node.items || [])
      |> Enum.filter(&(&1.type in @shown))
      |> Enum.map(fn item -> if item.type == :list, do: trim(item), else: item end)
      |> Enum.reject(&(&1.type == :list and &1.items == [] and is_nil(&1.deferred)))

    %{node | items: items}
  end

  defp inline_singletons(%Node{items: items} = root) do
    items =
      Enum.flat_map(items, fn
        %Node{type: :list, items: [_ | _] = docs} = list ->
          if Enum.all?(docs, &singleton?/1),
            do: [%Node{id: list.id, type: :divider, title: list.title} | docs],
            else: [list]

        item ->
          [item]
      end)

    %{root | items: items}
  end

  # One document whose id is its type (`Barkpark.Structure`'s singletons).
  defp singleton?(%Node{type: :document, doc_id: nil, id: id, type_name: id}) when is_binary(id),
    do: true

  defp singleton?(_node), do: false

  # A list drawn in place keeps its id on its divider (`inline_singletons/1`).
  defp inlined?(%Node{items: items}, id),
    do: Enum.any?(items || [], &(&1.type == :divider and &1.id == id and is_binary(&1.title)))

  @doc """
  The rows a node's pane lists: hidden types go, and so do the dividers
  they leave leading, trailing or doubled.
  """
  @spec rows(struct()) :: [struct()]
  def rows(%Node{} = node) do
    node.items
    |> Enum.reject(& &1.desk_hidden)
    |> Enum.reduce([], fn
      # A titled divider heads what follows it, at the top too.
      %{type: :divider, title: t} = titled, [] when is_binary(t) ->
        [titled]

      %{type: :divider}, [] ->
        []

      # A titled divider takes the place of a plain one right before it.
      %{type: :divider, title: t} = titled, [%{type: :divider, title: nil} | acc]
      when is_binary(t) ->
        [titled | acc]

      %{type: :divider}, [%{type: :divider} | _] = acc ->
        acc

      item, acc ->
        [item | acc]
    end)
    |> Enum.drop_while(&(&1.type == :divider))
    |> Enum.reverse()
  end

  @doc "Every node by id."
  @spec index(struct()) :: %{optional(String.t()) => struct()}
  def index(%Node{} = root), do: walk(root, %{})

  defp walk(node, acc),
    do: Enum.reduce(node.items || [], Map.put(acc, node.id, node), &walk/2)

  @doc """
  The desk path (node ids, root left out) to the first list of `type`, or
  `[type]` when the desk lists it nowhere: the path the Studio's own desk
  gives a document of that type.
  """
  @spec path_to_type(struct(), String.t()) :: [String.t()]
  def path_to_type(%Node{} = root, type) do
    case find_type(root.items || [], type) do
      {path, _list} -> path
      nil -> [type]
    end
  end

  # `{path, list}`: the desk path to the first list of `type`, and that list.
  defp find_type(items, type) do
    Enum.find_value(items, fn
      %Node{type: :document_type_list, type_name: ^type, id: id} = list ->
        {[id], list}

      %Node{type: :list, id: id, items: items} ->
        case find_type(items || [], type) do
          {path, list} -> {[id | path], list}
          nil -> nil
        end

      _ ->
        nil
    end)
  end

  @doc """
  The desk path that opens document `id` of `type` from the desk's own list
  of it: the list, then the id. Under a tree list the id alone opens a
  level, so it comes twice, as `PaneBuilder.walk_tree` reads it.
  """
  @spec doc_path(struct(), String.t(), String.t()) :: [String.t()]
  def doc_path(%Node{} = root, type, id) do
    case find_type(root.items || [], type) do
      {path, %Node{tree: %{"parent" => _}}} -> path ++ [id, id]
      {path, _list} -> path ++ [id]
      nil -> [type, id]
    end
  end

  @doc """
  The Studio's own path (`PaneBuilder.build/3`) for `panes` up to pane
  `index`: each menu and list names its desk node, and a tree level the
  parent it lists, so a level two deep is `[…, node, id, child]`.
  """
  @spec studio_path([Panes.pane()], non_neg_integer()) :: [String.t()]
  def studio_path(panes, index) do
    panes
    |> Enum.slice(1..index//1)
    |> Enum.map(fn pane -> pane[:tree_parent] || pane[:node] || pane[:type] end)
  end

  @doc """
  The Studio path that opens the last document of `panes` in the editor. A
  document opened from the top of a tree level follows the chain
  (`[…, node, id, id]`); any other goes by its desk node or its type.
  """
  @spec edit_path([Panes.pane()], struct()) :: [String.t()]
  def edit_path(panes, %Node{} = root) do
    %{id: id, type: type} = doc = List.last(panes)
    head = group_head(panes, length(panes) - 1)

    case head > 0 && Enum.at(panes, head - 1) do
      %{kind: :list, tree_parent: ^id} -> studio_path(panes, head - 1) ++ [id]
      _ -> (doc[:node] && [doc.node]) || doc_path(root, type, id)
    end
  end

  # The first pane of the split group pane `index` is in.
  defp group_head(panes, index) do
    case Enum.at(panes, index) do
      %{kind: :doc, sibling: true} when index > 0 -> group_head(panes, index - 1)
      _ -> index
    end
  end

  @doc """
  What a row of list `pane` opens (`next`, its document). In a tree list
  (`node` has `:tree`) a row opens its children, a tree level; the level's
  own parent, the row on top, opens its document.
  """
  @spec row_opens(Panes.pane(), struct() | nil, Panes.pane() | nil) :: Panes.pane() | nil
  def row_opens(
        %{kind: :list, node: node_id} = pane,
        %Node{tree: %{"parent" => _}},
        %{kind: :doc, id: id} = next
      ) do
    if id == pane[:tree_parent],
      do: next,
      else: %{kind: :list, type: pane.type, node: node_id, tree_parent: id}
  end

  def row_opens(_pane, _node, next), do: next

  @doc "A list read's rows (`entries`) with `row_opens/3` applied to each."
  @spec tree_rows(map(), Panes.pane(), struct() | nil) :: map()
  def tree_rows(%{entries: [_ | _] = entries} = data, pane, %Node{tree: %{}} = node) do
    entries =
      Enum.map(entries, fn
        %{next: next} = entry -> %{entry | next: row_opens(pane, node, next)}
        entry -> entry
      end)

    %{data | entries: entries}
  end

  def tree_rows(data, _pane, _node), do: data

  @doc "The pane a row opens, or nil for a row that opens nothing."
  @spec opens(struct()) :: Panes.pane() | nil
  def opens(%Node{type: :list, id: id}), do: %{kind: :menu, node: id}

  def opens(%Node{type: :document_type_list, id: id, type_name: type}) when is_binary(type),
    do: %{kind: :list, type: type, node: id}

  # An orphaned type under …Rest (its schema is gone) has no document to open.
  def opens(%Node{type: :document, doc_id: nil, id: "rest-" <> _}), do: nil

  def opens(%Node{type: :document, id: id, type_name: type} = node) when is_binary(type),
    do: %{kind: :doc, id: node.doc_id || id, type: type, node: id}

  def opens(_node), do: nil

  @doc """
  The desk node a pane draws from (`nodes` is `index/1` of `root`), or nil.
  A document has none. Neither has a segment that was not under its list:
  its id may name a node elsewhere on the desk, which is not this pane's.
  """
  @spec node_of(Panes.pane(), struct(), map()) :: struct() | nil
  def node_of(%{kind: :types}, root, _nodes), do: root
  def node_of(%{kind: :doc}, _root, _nodes), do: nil
  def node_of(%{missing: true}, _root, _nodes), do: nil
  def node_of(pane, _root, nodes), do: pane[:node] && nodes[pane.node]

  @doc """
  The desk node of each pane of a chain `parse/2` read, found along the
  chain from `root`: each one under the pane before it, as `parse/2` found
  it. A desk may use one id in two menus, and `nodes` (the flat index)
  keeps only the last. `nodes` answers only for what the tree itself does
  not hold: the groups of a deferred groupBy, built when it is opened.
  """
  @spec nodes_of([Panes.pane()], struct(), map()) :: [struct() | nil]
  def nodes_of(panes, %Node{} = root, nodes) do
    {found, _parent} =
      Enum.map_reduce(panes, root, fn pane, parent ->
        node = chain_node(pane, parent, nodes)
        {node, node || parent}
      end)

    found
  end

  # The chain starts at the root, so the types pane's "parent" is the root.
  defp chain_node(%{kind: :types}, root, _nodes), do: root
  defp chain_node(%{kind: :doc}, _parent, _nodes), do: nil
  defp chain_node(%{missing: true}, _parent, _nodes), do: nil

  # A tree level names its own list again: the list is its node.
  defp chain_node(%{node: id}, %Node{id: id} = parent, _nodes), do: parent

  # A deferred groupBy has no items in the tree: opened, the page keeps it,
  # groups and all, in `nodes`.
  defp chain_node(%{node: id}, %Node{} = parent, nodes) when is_binary(id) do
    case find(parent, id) do
      nil -> nodes[id]
      %Node{deferred: nil} = node -> node
      %Node{} = deferred -> nodes[deferred.id] || deferred
    end
  end

  defp chain_node(_pane, _parent, _nodes), do: nil

  @doc "The panes a splat names, read against the desk `root`."
  @spec parse(String.t() | nil, struct()) :: [Panes.pane()]
  def parse(splat, %Node{} = root) do
    segs = String.split(splat || "", ";", trim: true)

    case segs do
      [] ->
        [%{kind: :types}]

      [first | rest] ->
        cond do
          find(root, segment_id(first)) -> [%{kind: :types} | descend(segs, root)]
          # An old link through a list now drawn in place: step over it.
          inlined?(root, segment_id(first)) -> [%{kind: :types} | descend(rest, root)]
          true -> Panes.parse(splat)
        end
    end
  end

  defp descend([], _menu), do: []

  defp descend([seg | rest] = segs, menu) do
    case find(menu, segment_id(seg)) do
      # Not under this list: a pane marked missing, which says so. What
      # follows it in the URL has nothing to hang on and is not drawn.
      nil ->
        [%{kind: :menu, node: segment_id(seg), missing: true}]

      %Node{type: :list, deferred: {:group_by, item, idx}} = child ->
        [%{kind: :menu, node: child.id} | group(rest, item, idx)]

      %Node{type: :list} = child ->
        [%{kind: :menu, node: child.id} | descend(rest, child)]

      %Node{type: :document} = child ->
        singleton(segs, child)

      %Node{type: :document_type_list, tree: %{"parent" => _}} = child ->
        list = %{kind: :list, type: child.type_name || "", node: child.id}
        [list | tree_levels(rest, list)]

      %Node{type: :document_type_list} = child ->
        type = child.type_name || ""
        [%{kind: :list, type: type, node: child.id} | Panes.parse_doc_segments(rest, type)]
    end
  end

  # A tree list: an id other than the open level's parent opens that row's
  # children; the parent's own id again opens its document, and documents
  # follow from there.
  defp tree_levels([], _list), do: []

  defp tree_levels([seg | rest] = segs, list) do
    id = segment_id(seg)

    if id == list[:tree_parent] do
      Panes.parse_doc_segments(segs, list.type)
    else
      level = Map.put(list, :tree_parent, id)
      [level | tree_levels(rest, level)]
    end
  end

  # A deferred groupBy's groups are type lists with ids `<idx>-<key>`
  # (`Barkpark.Structure`); any other id is not under it, a missing pane.
  defp group([], _item, _idx), do: []

  defp group([seg | rest], item, idx) do
    id = segment_id(seg)
    type = item["type"]

    if is_binary(type) and String.starts_with?(id, "#{idx}-") do
      [%{kind: :list, type: type, node: id} | Panes.parse_doc_segments(rest, type)]
    else
      [%{kind: :menu, node: id, missing: true}]
    end
  end

  # The segment names the desk node; the document (and any split sibling of
  # it) is the singleton.
  defp singleton([seg | _] = segs, child) do
    group = seg |> String.split("|") |> length()

    segs
    |> Panes.parse_doc_segments(child.type_name || "")
    |> Enum.with_index()
    |> Enum.map(fn
      {doc, k} when k < group ->
        doc = if doc.id == child.id, do: %{doc | id: child.doc_id || doc.id}, else: doc
        if k == 0, do: Map.put(doc, :node, child.id), else: doc

      {doc, _k} ->
        doc
    end)
  end

  defp find(%Node{items: items}, id),
    do: Enum.find(items || [], &(&1.id == id and &1.type != :divider))

  defp segment_id(seg) do
    seg |> String.split("|") |> hd() |> String.split(",") |> hd() |> URI.decode()
  end
end
