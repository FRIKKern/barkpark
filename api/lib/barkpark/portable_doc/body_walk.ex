defmodule Barkpark.PortableDoc.BodyWalk do
  @moduledoc """
  The ONE deep walker over PortableDoc block trees (wire §7.3).

  Before this module the repo carried THREE parallel private walkers with the
  same descend shape and different match arms:

    * `Papers.collect_link_targets/2` — inline `wikilink`/`blockref` targets
      (the wikilink pre-resolve pass),
    * `Papers.collect_embed_targets/2` — `embed` block targets (the
      transclusion pre-resolve pass),
    * `Bulldocs.collect_refs/2` — `"ref"`/`"href"` internal-reference harvest
      (edge extraction).

  All three now route through `collect/2` — one descend, per-caller match. The
  body-walk edge extractor (valueref / task-wikilink → content_edges) is the
  fourth caller and the reason the walker was unified instead of forked again.

  ## Descend shape

  PURE over plain maps + lists (no DB, struct-guarded). Recurses into EVERY
  map value and list element — marks carry `children`, list items are nested
  lists, sections carry `blocks` — so arbitrarily-nested inline structure is
  reached. A matched node is STILL descended into (its children may carry
  further matches), preserving the semantics of all three prior walkers.
  Collection order is document order (depth-first, pre-order).
  """

  @doc """
  Deep-walk `tree`, handing every map node to `collector` and flattening what
  it returns. `collector` receives each map node (never lists/scalars) and
  returns a LIST of collected items for that node (`[]` = no match) — a node
  can contribute several items (e.g. a `"ref"` and an `"href"` on one map).
  """
  @spec collect(term(), (map() -> list())) :: list()
  def collect(tree, collector) when is_function(collector, 1) do
    tree |> do_collect(collector, []) |> Enum.reverse()
  end

  @doc """
  Deep-collect every node whose `"type"` is in `types` and that carries a
  non-empty binary `"target"` — the shared match arm of the wikilink/blockref,
  embed, valueref, and edge-extraction callers. Returns the FULL node maps in
  document order (callers pick `"target"`, `"docId"`, `"field"`, … off them).
  """
  @spec collect_nodes(term(), [String.t()]) :: [map()]
  def collect_nodes(tree, types) when is_list(types) do
    collect(tree, fn
      %{"type" => type, "target" => target} = node
      when is_binary(target) and target != "" ->
        if type in types, do: [node], else: []

      _ ->
        []
    end)
  end

  defp do_collect(node, collector, acc) when is_map(node) and not is_struct(node) do
    acc =
      case collector.(node) do
        [] -> acc
        collected when is_list(collected) -> Enum.reverse(collected, acc)
      end

    Enum.reduce(node, acc, fn {_k, v}, a -> do_collect(v, collector, a) end)
  end

  defp do_collect(list, collector, acc) when is_list(list),
    do: Enum.reduce(list, acc, &do_collect(&1, collector, &2))

  defp do_collect(_other, _collector, acc), do: acc
end
