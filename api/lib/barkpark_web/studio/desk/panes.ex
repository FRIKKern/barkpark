defmodule BarkparkWeb.Studio.Desk.Panes do
  @moduledoc """
  The desk's pane chain as one URL segment, in Sanity's format. This is the
  Elixir twin of `app/src/lib/panes.ts` in the TanStack Studio
  (`barkpark-studio`), so one deep link opens the same panes in both:

      post;post-01;author-alan,type=author,parentRefPath=author

  Segment 0 names the list, then one document per segment. A document's
  params follow its id after commas. Split siblings share a segment, joined
  by `|`; an empty sibling id means the same document as the first.

  A pane is a plain map. Keys with no value are left out:

    * `%{kind: :types}` — the root pane
    * `%{kind: :menu, node: id}` — a nested desk list
    * `%{kind: :list, type: t}` plus optional `:node`, `:tree_parent`
    * `%{kind: :doc, id: id, type: t}` plus optional `:parent_ref_path`,
      `:view`, `:inspect`, `:rev`, `:path`, `:template`, `:template_params`,
      `:sibling`, `:node`, `:untyped`

  Pure: no socket, no database. `parse/1` reads the segment as the router
  hands it over (decoded or not); `to_splat/1` prints it encoded.

  Two known differences from the TypeScript: an empty param value
  (`view=`) reads as absent, and template params with several keys print
  in sorted key order.
  """

  @type pane :: %{required(:kind) => :types | :menu | :list | :doc, optional(atom()) => term()}

  # Sanity's inspector names, so a link copied from either studio opens the
  # same inspector in the other. History is one inspector in Sanity with its
  # tab in `changesInspectorTab`; ours names the tab (history | review).
  @sanity_inspect %{
    "validation" => "sanity/structure/validation",
    "comments" => "sanity/comments"
  }
  @history "sanity/structure/history"
  @template_payload ~r/^[A-Za-z0-9+\/_-]+=*$/

  @doc "The panes a splat names. `nil` or `\"\"` is the root pane alone."
  @spec parse(String.t() | nil) :: [pane()]
  def parse(splat) do
    case segments(splat) do
      [] ->
        [%{kind: :types}]

      [list_type | docs] ->
        [%{kind: :types}, %{kind: :list, type: list_type} | parse_doc_segments(docs, list_type)]
    end
  end

  @doc """
  Document segments (one document, or split siblings joined by `|`) that
  follow a list of `list_type`.
  """
  @spec parse_doc_segments([String.t()], String.t()) :: [pane()]
  def parse_doc_segments(segs, list_type) do
    segs
    |> Enum.with_index()
    |> Enum.flat_map(fn {seg, k} ->
      {panes, _first} =
        seg
        |> String.split("|")
        |> Enum.reduce({[], nil}, fn part, {acc, first} ->
          pane = doc_pane(part, first, list_type, k)
          {[pane | acc], first || pane}
        end)

      Enum.reverse(panes)
    end)
  end

  @doc """
  With no declared desk, a singleton type's segment opens its one document
  (id = the type) instead of a list. The document carries the segment as its
  `:node`, so it prints back as just the type.
  """
  @spec parse_singleton(String.t() | nil, MapSet.t(String.t())) :: [pane()]
  def parse_singleton(splat, singletons) do
    segs = segments(splat)
    type = segment_id(Enum.at(segs, 0))

    if MapSet.member?(singletons, type) do
      # A list-style link to it (`type;id`: search, an old link) is the same doc.
      docs = if segment_id(Enum.at(segs, 1)) == type, do: tl(segs), else: segs

      case parse_doc_segments(docs, type) do
        [first | rest] -> [%{kind: :types}, Map.put(first, :node, type) | rest]
        [] -> [%{kind: :types}]
      end
    else
      parse(splat)
    end
  end

  @doc "The splat for a pane chain: what follows the desk's base path."
  @spec to_splat([pane()]) :: String.t()
  def to_splat(panes) do
    panes
    |> Enum.with_index()
    |> Enum.reduce([], fn {pane, i}, segs -> put_segment(pane, i, panes, segs) end)
    |> Enum.reverse()
    |> Enum.join(";")
  end

  @doc "The path for a pane chain under `base` (the TanStack Studio's is `/structure`)."
  @spec to_path([pane()], String.t()) :: String.t()
  def to_path(panes, base \\ "/structure") do
    case to_splat(panes) do
      "" -> base
      splat -> base <> "/" <> splat
    end
  end

  @doc "The last pane of the split group `index` is in (itself when not split)."
  @spec group_end([pane()], non_neg_integer()) :: non_neg_integer()
  def group_end(panes, index) do
    case Enum.at(panes, index + 1) do
      %{kind: :doc, sibling: true} -> group_end(panes, index + 1)
      _ -> index
    end
  end

  @doc "Whether pane `index` shares its segment with another (a split)."
  @spec split?([pane()], non_neg_integer()) :: boolean()
  def split?(panes, index) do
    case Enum.at(panes, index) do
      %{kind: :doc} = pane -> pane[:sibling] == true or group_end(panes, index) > index
      _ -> false
    end
  end

  @doc """
  Path for opening `next` to the right of pane `index`'s group. Everything
  right of it is replaced.
  """
  @spec open_after([pane()], non_neg_integer(), pane(), String.t()) :: String.t()
  def open_after(panes, index, next, base \\ "/structure"),
    do: to_path(Enum.take(panes, group_end(panes, index) + 1) ++ [next], base)

  @doc "Path for closing pane `index` and everything to its right."
  @spec close_from([pane()], non_neg_integer(), String.t()) :: String.t()
  def close_from(panes, index, base \\ "/structure"), do: to_path(Enum.take(panes, index), base)

  @doc "Path for \"Split pane right\": the same document again, beside it in its group."
  @spec split_right([pane()], non_neg_integer(), String.t()) :: String.t()
  def split_right(panes, index, base \\ "/structure") do
    pane = Enum.at(panes, index)
    to_path(List.insert_at(panes, index + 1, Map.put(pane, :sibling, true)), base)
  end

  @doc "Path for \"Close split pane\": drop just this one; the next sibling takes its place."
  @spec close_split([pane()], non_neg_integer(), String.t()) :: String.t()
  def close_split(panes, index, base \\ "/structure") do
    closed = Enum.at(panes, index)
    rest = List.delete_at(panes, index)

    rest =
      case {closed[:sibling], Enum.at(rest, index)} do
        {nil, %{kind: :doc} = heir} -> List.replace_at(rest, index, Map.delete(heir, :sibling))
        _ -> rest
      end

    to_path(rest, base)
  end

  @doc "Path for showing pane `index` in another view (`\"\"` or `nil` = the editor)."
  @spec with_view([pane()], non_neg_integer(), String.t() | nil, String.t()) :: String.t()
  def with_view(panes, index, view, base \\ "/structure"),
    do: to_path(update_doc(panes, index, &put_opt(Map.delete(&1, :view), :view, view)), base)

  @doc """
  Path for pane `index` with some of `:inspect`, `:rev`, `:path` changed. A
  `nil` value removes that param.
  """
  @spec with_params([pane()], non_neg_integer(), map(), String.t()) :: String.t()
  def with_params(panes, index, params, base \\ "/structure") do
    change = fn pane ->
      params
      |> Map.take([:inspect, :rev, :path])
      |> Enum.reduce(pane, fn {key, value}, acc -> put_opt(Map.delete(acc, key), key, value) end)
    end

    to_path(update_doc(panes, index, change), base)
  end

  @doc "A stable key for a pane, for keyed rendering."
  @spec pane_key(pane()) :: String.t()
  def pane_key(%{kind: :types}), do: "types"
  # Not the list of that id elsewhere on the desk: it keeps none of its state.
  def pane_key(%{kind: :menu, node: node, missing: true}), do: "missing:" <> node
  def pane_key(%{kind: :menu, node: node}), do: "menu:" <> node

  def pane_key(%{kind: :list} = pane),
    do:
      "list:" <>
        ([pane.type, pane[:node], pane[:tree_parent]] |> Enum.filter(& &1) |> Enum.join(":"))

  def pane_key(%{kind: :doc, id: id}), do: "doc:" <> id

  # ── reading ────────────────────────────────────────────────────────────────

  defp segments(nil), do: []
  defp segments(splat), do: String.split(splat, ";", trim: true)

  # The id a segment names: its first sibling, without params.
  defp segment_id(nil), do: ""

  defp segment_id(seg) do
    seg |> String.split("|") |> hd() |> String.split(",") |> hd() |> URI.decode()
  end

  defp doc_pane(part, first, list_type, k) do
    [id | raw] = String.split(part, ",")
    raw = Enum.reject(raw, &(&1 == ""))
    params = Map.new(raw, &split_param/1)
    param = fn key -> blank_to_nil(params[key]) end

    %{
      kind: :doc,
      id: if(id == "", do: (first && first.id) || "", else: URI.decode(id)),
      type: param.("type") || (first && first.type) || list_type
    }
    |> put_opt(:parent_ref_path, param.("parentRefPath") || (first && first[:parent_ref_path]))
    |> put_opt(:view, param.("view"))
    # An inspector open beside the doc, and an old revision shown in its place.
    |> put_opt(:inspect, inspect_in(param.("inspect"), param.("changesInspectorTab")))
    |> put_opt(:rev, param.("rev"))
    # The focused field: a reload or a copied link opens on it.
    |> put_opt(:path, param.("path"))
    |> put_opt(:template, param.("template"))
    |> put_opt(:template_params, template_params(param.("template"), raw))
    |> put_opt(:sibling, first != nil || nil)
    # A followed doc with no `type=` (a hand-trimmed link): its type is looked up.
    |> put_opt(:untyped, (k > 0 and is_nil(param.("type")) and is_nil(first)) || nil)
  end

  # Split at the first "=" only: a field path inside an array item has its own
  # (`path=links[_key=="l1"].title`).
  defp split_param(kv) do
    case String.split(kv, "=", parts: 2) do
      [key, value] -> {URI.decode(key), URI.decode(value)}
      [key] -> {URI.decode(key), ""}
    end
  end

  defp inspect_in(nil, _tab), do: nil
  defp inspect_in(@history, "review"), do: "review"
  defp inspect_in(@history, _tab), do: "history"

  defp inspect_in(inspect, _tab) do
    Enum.find_value(@sanity_inspect, inspect, fn {ours, sanity} -> sanity == inspect && ours end)
  end

  # The param after `template=` with no "=" of its own (base64 padding aside)
  # is the template's parameters: base64 of their JSON, either alphabet.
  defp template_params(nil, _raw), do: nil

  defp template_params(_template, raw) do
    raw
    |> Enum.drop_while(&(not String.starts_with?(&1, "template=")))
    |> Enum.drop(1)
    |> Enum.find(&Regex.match?(@template_payload, &1))
    |> case do
      nil -> nil
      payload -> payload |> URI.decode() |> params_in()
    end
  end

  defp params_in(raw) do
    b64 =
      raw
      |> String.replace("+", "-")
      |> String.replace("/", "_")
      |> String.trim_trailing("=")

    with {:ok, json} <- Base.url_decode64(b64, padding: false),
         {:ok, %{} = params} <- Jason.decode(json) do
      params
    else
      _ -> nil
    end
  end

  # ── printing ───────────────────────────────────────────────────────────────

  # `segs` is the printed segments so far, last one first.
  defp put_segment(%{kind: :types}, _i, _panes, segs), do: segs
  defp put_segment(%{kind: :menu, node: node}, _i, _panes, segs), do: [enc(node) | segs]

  defp put_segment(%{kind: :list} = pane, _i, _panes, segs),
    do: [enc(pane[:tree_parent] || pane[:node] || pane.type) | segs]

  # A sibling of the same doc carries only its own view and inspector, like
  # Sanity's "|,". In split view the editor is the sibling, and the desk's
  # Inspect is in its URL (`inspect=on`). TanStack prints the view only: its
  # Inspect is not in its URL.
  defp put_segment(%{kind: :doc, sibling: true} = pane, _i, _panes, [last | rest]) do
    own = opt("view", pane[:view]) <> inspect_out(pane[:inspect])
    [last <> "|," <> String.trim_leading(own, ",") | rest]
  end

  defp put_segment(%{kind: :doc} = pane, i, panes, segs),
    do: [enc(pane[:node] || pane.id) <> doc_params(pane, i, panes) | segs]

  defp doc_params(pane, i, panes) do
    # The list this doc was opened from: the nearest one to its left.
    list = panes |> Enum.take(i) |> Enum.reverse() |> Enum.find(&(&1.kind == :list))

    type =
      cond do
        pane[:parent_ref_path] ->
          ",type=#{enc(pane.type)},parentRefPath=#{enc(pane.parent_ref_path)}"

        pane[:node] || (list && list.type == pane.type) ->
          ""

        true ->
          ",type=#{enc(pane.type)}"
      end

    type <>
      opt("view", pane[:view]) <>
      inspect_out(pane[:inspect]) <>
      opt("rev", pane[:rev]) <>
      opt("path", pane[:path]) <>
      template_out(pane)
  end

  defp opt(_name, nil), do: ""
  defp opt(name, value), do: ",#{name}=#{enc(value)}"

  defp inspect_out(nil), do: ""

  defp inspect_out("review"),
    do: ",since=@lastPublished,changesInspectorTab=review,inspect=#{enc(@history)}"

  defp inspect_out("history"), do: ",changesInspectorTab=history,inspect=#{enc(@history)}"
  defp inspect_out(inspect), do: ",inspect=#{enc(Map.get(@sanity_inspect, inspect, inspect))}"

  defp template_out(%{template: template} = pane) do
    case pane[:template_params] do
      %{} = params when map_size(params) > 0 ->
        ",template=#{enc(template)},#{Base.url_encode64(Jason.encode!(params), padding: false)}"

      _ ->
        ",template=#{enc(template)}"
    end
  end

  defp template_out(_pane), do: ""

  # ── small helpers ──────────────────────────────────────────────────────────

  defp update_doc(panes, index, fun) do
    case Enum.at(panes, index) do
      %{kind: :doc} = pane -> List.replace_at(panes, index, fun.(pane))
      _ -> panes
    end
  end

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, _key, ""), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # JavaScript's encodeURIComponent.
  defp enc(value),
    do: URI.encode(to_string(value), &(URI.char_unreserved?(&1) or &1 in ~c"!*'()"))
end
