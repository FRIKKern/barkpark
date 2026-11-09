defmodule BarkparkWeb.Studio.Desk.Tree do
  @moduledoc """
  The desk tree (`Barkpark.Structure.build/2`) read against a pane URL, for
  the desk slice. The Elixir twin of `parseDeskPanes` and `normalizeDesk` in
  the TanStack Studio's `app/src/lib/desk.ts`.

  Segment by segment: a desk list opens a menu, a type list a list, a
  singleton its document. Documents follow as in `Panes.parse/1`. A first
  segment that is no desk node (a type name from an old link) reads as a
  plain type list, so those links keep working.

  Left out of the slice, as the TanStack Studio leaves them out of its own
  desk: plugin links and plugin lists. Also left out for now: drilling a
  parent-child tree list (it opens as a flat list) and `groupBy` nodes
  whose children are built on demand (they have none here, so they go with
  the other empty lists).
  """

  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.Desk.Panes

  @shown [:list, :divider, :document, :document_type_list]

  @doc "The tree as the slice shows it: only node types it can open, no empty lists."
  @spec normalize(struct()) :: struct()
  def normalize(%Node{} = node) do
    items =
      (node.items || [])
      |> Enum.filter(&(&1.type in @shown))
      |> Enum.map(fn item -> if item.type == :list, do: normalize(item), else: item end)
      |> Enum.reject(&(&1.type == :list and &1.items == []))

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
      nil ->
        []

      %Node{type: :list} = child ->
        [%{kind: :menu, node: child.id} | descend(rest, child)]

      %Node{type: :document} = child ->
        singleton(segs, child)

      %Node{type: :document_type_list} = child ->
        type = child.type_name || ""
        [%{kind: :list, type: type, node: child.id} | Panes.parse_doc_segments(rest, type)]
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
