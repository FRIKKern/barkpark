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
  """
  @spec normalize(struct()) :: struct()
  def normalize(%Node{} = node) do
    items =
      (node.items || [])
      |> Enum.filter(&(&1.type in @shown))
      |> Enum.map(fn item -> if item.type == :list, do: normalize(item), else: item end)
      |> Enum.reject(&(&1.type == :list and &1.items == [] and is_nil(&1.deferred)))

    %{node | items: items}
  end

  @doc """
  The rows a node's pane lists: hidden types go, and so do the dividers
  they leave leading, trailing or doubled.
  """
  @spec rows(struct()) :: [struct()]
  def rows(%Node{} = node) do
    node.items
    |> Enum.reject(& &1.desk_hidden)
    |> Enum.reduce([], fn
      %{type: :divider}, [] -> []
      %{type: :divider}, [%{type: :divider} | _] = acc -> acc
      item, acc -> [item | acc]
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
  def path_to_type(%Node{} = root, type), do: find_type(root.items || [], type) || [type]

  defp find_type(items, type) do
    Enum.find_value(items, fn
      %Node{type: :document_type_list, type_name: ^type, id: id} ->
        [id]

      %Node{type: :list, id: id, items: items} ->
        (sub = find_type(items || [], type)) && [id | sub]

      _ ->
        nil
    end)
  end

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

  @doc "The panes a splat names, read against the desk `root`."
  @spec parse(String.t() | nil, struct()) :: [Panes.pane()]
  def parse(splat, %Node{} = root) do
    segs = String.split(splat || "", ";", trim: true)

    case segs do
      [] ->
        [%{kind: :types}]

      [first | _] ->
        if find(root, segment_id(first)),
          do: [%{kind: :types} | descend(segs, root)],
          else: Panes.parse(splat)
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
  # (`Barkpark.Structure`); any other id opens nothing, as an unknown row.
  defp group([], _item, _idx), do: []

  defp group([seg | rest], item, idx) do
    id = segment_id(seg)
    type = item["type"]

    if is_binary(type) and String.starts_with?(id, "#{idx}-") do
      [%{kind: :list, type: type, node: id} | Panes.parse_doc_segments(rest, type)]
    else
      []
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
