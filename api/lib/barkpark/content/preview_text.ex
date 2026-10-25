defmodule Barkpark.Content.PreviewText do
  @moduledoc """
  A schema's `list_preview` text and media, formatted: Sanity's preview
  `select` + `prepare`, declared instead of coded (task-f3203617ae4cf03e,
  task-75cb2cac1e875214).

  ## Paths

  A path is a dotted walk from the document: `isbn`, `onix.productFormatTitle`,
  `onix.formats.0.code` (a number picks a list item). When the walk meets a
  reference (`{"_ref": id}` or a bare id string with path left to walk), it
  follows it: `author.name`, `onix.contributors.0.contributor.title`. A path
  follows up to five references, so `parent.parent.title` reads a grandparent;
  a reference past the fifth reads as nothing, which also ends a cycle.

  ## Text specs (`subtitle`, `description`)

  A spec is one PART, or `%{"parts" => [part], "join" => sep, "empty" => text}`:
  the parts that have a value are joined (default `" · "`), and `empty` stands
  in when none do. A part is one of:

    * a path, optionally ending in modifiers: `|date` shows a date or
      date-time as `dd.mm.yyyy`, the day it is in UTC; `|lower` and `|upper`
      change the case; `|count` shows the number of items in a list, and `0`
      when the path holds nothing (`"{questions|count} questions"`);
    * a template, text with `{path}` slots (`"{name} ({role.title|lower})"`),
      shown only when every slot has a value;
    * a list of parts, the first that has a value;
    * `%{"text" => text}`, literal text (a fallback at the end of a list);
    * `%{"when" => predicate, "show" => part}`: `show` only while the
      `visibleWhen`-shaped predicate holds on the document;
    * `%{"path" => path, "map" => %{value => label}}`: a stored value shown by
      its label, or as stored when the map does not name it;
    * a nested `%{"parts" => …}` spec, joined by its own `join`;
    * `%{"each" => path, "show" => part, "max" => n, "join" => sep, "more" => text}`:
      `show` read from each item of the list at `path`, the first `max` items
      that have a value, joined (default `", "`), with `more` appended when the
      list holds more than `max` items. Inside `show`, paths start at the item,
      and an item that is a reference reads its target. The `each` path itself
      does not follow a reference.

  ## Media

  `media` is a path or a list of paths, the first that holds an image: a URL
  string (`onix.thumbnail`), or an image value with a `url`.

  Pure: the caller loads the referenced documents. `targets/2` loads every
  document a page of rows reads through, one read per reference depth, and
  `deref` hands each one back as a map.
  """

  alias Barkpark.Content.FieldVisibility

  @type spec :: String.t() | list() | %{optional(String.t()) => term()}
  @type deref :: (String.t() -> map() | nil)

  # The most references one path follows (a five-level category breadcrumb).
  @max_hops 5

  @doc """
  The reference ids `specs` follow on `root` (a document's content, `title`
  included) that `deref` does not yet hand back. A walk that meets a target
  `deref` knows goes on inside it, so asking again after loading the ids
  names the next depth's references.
  """
  @spec ref_ids(spec() | [spec()] | nil, map(), deref()) :: [String.t()]
  def ref_ids(specs, root, deref \\ fn _ -> nil end)

  def ref_ids(specs, root, deref) when is_map(root) do
    specs
    |> List.wrap()
    |> Enum.flat_map(&spec_ids(&1, root, deref))
    |> Enum.uniq()
  end

  def ref_ids(_specs, _root, _deref), do: []

  @doc """
  Every document a page of rows reads through, as `%{id => map}`. `rows` is a
  list of `{specs, root}`. `load` takes a list of ids and returns the found
  ones as `%{id => map}`. It runs once per reference depth with all the ids of
  that depth, so a page costs at most #{@max_hops} reads, however many rows it
  holds.
  """
  @spec targets([{spec() | [spec()] | nil, map()}], ([String.t()] -> map())) :: map()
  def targets(rows, load) when is_list(rows) do
    Enum.reduce_while(1..@max_hops, {%{}, MapSet.new()}, fn _depth, {found, asked} ->
      deref = &Map.get(found, &1)

      ids =
        rows
        |> Enum.flat_map(fn {specs, root} -> ref_ids(specs, root, deref) end)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(asked, &1))

      case ids do
        [] -> {:halt, {found, asked}}
        ids -> {:cont, {Map.merge(found, load.(ids)), MapSet.union(asked, MapSet.new(ids))}}
      end
    end)
    |> elem(0)
  end

  @doc "The text for a document, or nil. `deref` returns a referenced document's fields."
  @spec format(spec() | nil, map(), deref()) :: String.t() | nil
  def format(%{"parts" => parts} = spec, root, deref) when is_list(parts) do
    case parts |> Enum.map(&part(&1, root, deref, @max_hops)) |> Enum.reject(&is_nil/1) do
      [] -> blank_to_nil(Map.get(spec, "empty"))
      shown -> Enum.join(shown, Map.get(spec, "join") || " · ")
    end
  end

  def format(spec, root, deref) when is_map(root), do: part(spec, root, deref, @max_hops)
  def format(_spec, _root, _deref), do: nil

  @doc "The image URL `spec` finds on a document, or nil."
  @spec media(spec() | nil, map(), deref()) :: String.t() | nil
  def media(spec, root, deref) when is_map(root) do
    spec
    |> media_paths()
    |> Enum.find_value(fn path -> path |> value(root, deref) |> url() end)
  end

  def media(_spec, _root, _deref), do: nil

  @doc "The paths a media spec reads, in order."
  @spec media_paths(spec() | nil) :: [String.t()]
  def media_paths(path) when is_binary(path) and path != "", do: [path]
  def media_paths(%{"field" => field}), do: media_paths(field)
  def media_paths(list) when is_list(list), do: Enum.flat_map(list, &media_paths/1)
  def media_paths(_), do: []

  @doc "The value at `path` on `root`, following references through `deref`."
  @spec value(String.t(), map(), deref()) :: term()
  def value(path, root, deref), do: path |> segments() |> walk(root, deref, @max_hops) |> elem(0)

  @doc """
  The value at `path` inside `content`, without following any reference
  (task-86b6aa7ee423ecaf). A key that matches `path` as written wins, so a
  field whose name holds a dot still reads; otherwise the dotted walk goes
  into objects and list items: `slug.current`, `onix.productFormatTitle`.
  For the `list_preview` keys that name one field (`title`, `badge`, `meta`).
  """
  @spec field_value(map() | nil, String.t()) :: term()
  def field_value(%{} = content, path) when is_binary(path) do
    case Map.fetch(content, path) do
      {:ok, value} -> value
      :error -> value(path, content, fn _ -> nil end)
    end
  end

  def field_value(_content, _path), do: nil

  @doc """
  An image URL from a stored value: a URL string, or a map with `url` (the
  image object and the twin's denormalised image both carry one). A string
  that is not an http(s) or root-relative URL (Sanity exports write `"null"`)
  is not one.
  """
  @spec url(term()) :: String.t() | nil
  def url(%{"url" => u}), do: url(u)
  def url(%{"asset" => %{} = asset}), do: url(asset)

  def url(u) when is_binary(u) do
    u = String.trim(u)

    if String.starts_with?(u, ["https://", "http://", "/"]) and not String.starts_with?(u, "//"),
      do: u,
      else: nil
  end

  def url(_), do: nil

  # ── parts ──────────────────────────────────────────────────────────────

  defp part(alternatives, root, deref, hops) when is_list(alternatives),
    do: Enum.find_value(alternatives, &part(&1, root, deref, hops))

  defp part(%{"each" => path} = spec, root, deref, hops) when is_binary(path) do
    items =
      case path |> segments() |> walk(root, deref, 0) do
        {list, _} when is_list(list) -> list
        _ -> []
      end

    max = positive(Map.get(spec, "max"))
    show = Map.get(spec, "show") || "title"

    shown =
      items
      |> Enum.map(&item_text(show, &1, deref, hops))
      |> Enum.reject(&is_nil/1)
      |> then(fn texts -> if max, do: Enum.take(texts, max), else: texts end)

    case shown do
      [] ->
        nil

      _ ->
        more = if max && length(items) > max, do: Map.get(spec, "more") || "", else: ""
        blank_to_nil(Enum.join(shown, Map.get(spec, "join") || ", ") <> more)
    end
  end

  # A nested text spec: its parts joined by its own `join`.
  defp part(%{"parts" => parts} = spec, root, deref, _hops) when is_list(parts),
    do: format(spec, root, deref)

  defp part(%{"text" => text}, _root, _deref, _hops), do: blank_to_nil(text)

  # `when` is a `visibleWhen` predicate on the document (no reference is
  # followed); `show` stands only while it holds.
  defp part(%{"when" => %{} = pred} = spec, root, deref, hops) do
    if FieldVisibility.visible?(%{"visibleWhen" => pred}, root),
      do: part(Map.get(spec, "show"), root, deref, hops),
      else: nil
  end

  # A stored value shown by its label: `{"path": "pageType", "map": {"landingPage":
  # "Landingsside"}}`. A value the map does not name shows as stored.
  defp part(%{"path" => path, "map" => %{} = labels}, root, deref, hops) when is_binary(path) do
    case slot(path, root, deref, hops) do
      nil -> nil
      value -> blank_to_nil(Map.get(labels, value, value))
    end
  end

  defp part(text, root, deref, hops) when is_binary(text) do
    if String.contains?(text, "{"),
      do: template(text, root, deref, hops),
      else: slot(text, root, deref, hops)
  end

  defp part(_spec, _root, _deref, _hops), do: nil

  # An item that is itself a reference reads its target, which costs a hop.
  defp item_text(show, item, deref, hops) do
    case ref_id(item) do
      id when is_binary(id) and hops > 0 ->
        case deref.(id) do
          %{} = target -> part(show, target, deref, hops - 1)
          _ -> nil
        end

      id when is_binary(id) ->
        nil

      nil ->
        if is_map(item), do: part(show, item, deref, hops), else: nil
    end
  end

  @template ~r/\{([^{}]+)\}/

  defp template(text, root, deref, hops) do
    slots = Regex.scan(@template, text, capture: :all_but_first) |> List.flatten()
    values = Map.new(slots, &{&1, slot(&1, root, deref, hops)})

    if Enum.any?(values, fn {_, v} -> is_nil(v) end),
      do: nil,
      else: blank_to_nil(Regex.replace(@template, text, fn _, s -> values[s] end))
  end

  defp slot(text, root, deref, hops) do
    [path | mods] = text |> String.split("|") |> Enum.map(&String.trim/1)
    {value, _} = path |> segments() |> walk(root, deref, hops)

    text =
      cond do
        "count" in mods -> count(value)
        "date" in mods -> day(value)
        true -> scalar(value)
      end

    text
    |> blank_to_nil()
    |> case_mods(mods)
  end

  defp case_mods(nil, _), do: nil

  defp case_mods(text, mods) do
    cond do
      "lower" in mods -> String.downcase(text)
      "upper" in mods -> String.upcase(text)
      true -> text
    end
  end

  # ── the walk ───────────────────────────────────────────────────────────

  defp segments(path) when is_binary(path),
    do: path |> String.split(".") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp segments(_), do: []

  # Returns {value, hops left}.
  defp walk([], value, _deref, hops), do: {value, hops}

  defp walk([key | rest] = segs, value, deref, hops) do
    case {ref_id(value), value} do
      {id, _} when is_binary(id) and hops > 0 ->
        case deref.(id) do
          %{} = target -> walk(segs, target, deref, hops - 1)
          _ -> {nil, 0}
        end

      {id, _} when is_binary(id) ->
        {nil, 0}

      {nil, %{} = map} ->
        walk(rest, Map.get(map, key), deref, hops)

      {nil, list} when is_list(list) ->
        case Integer.parse(key) do
          {i, ""} when i >= 0 -> walk(rest, Enum.at(list, i), deref, hops)
          _ -> {nil, hops}
        end

      _ ->
        {nil, hops}
    end
  end

  # A reference: `{"_ref": id}`, or a bare id string (Barkpark stores a
  # reference either way). Only asked while path is left to walk, so a plain
  # string field at the end of a path is never taken for an id.
  defp ref_id(%{"_ref" => id}) when is_binary(id) and id != "", do: published(id)
  defp ref_id(id) when is_binary(id) and id != "", do: published(id)
  defp ref_id(_), do: nil

  defp published("drafts." <> id), do: id
  defp published(id), do: id

  # ── which ids a spec follows ───────────────────────────────────────────
  #
  # The same walk as `walk/4`, but it collects the first reference `deref`
  # cannot answer on each path instead of reading a value.

  defp spec_ids(%{"parts" => parts}, root, deref) when is_list(parts),
    do: Enum.flat_map(parts, &part_ids(&1, root, deref, @max_hops))

  defp spec_ids(spec, root, deref), do: part_ids(spec, root, deref, @max_hops)

  defp part_ids(list, root, deref, hops) when is_list(list),
    do: Enum.flat_map(list, &part_ids(&1, root, deref, hops))

  defp part_ids(%{"each" => path} = spec, root, deref, hops) when is_binary(path) do
    items =
      case path |> segments() |> walk(root, fn _ -> nil end, 0) do
        {list, _} when is_list(list) -> list
        _ -> []
      end

    show = Map.get(spec, "show") || "title"

    Enum.flat_map(items, fn item ->
      case ref_id(item) do
        id when is_binary(id) and hops > 0 ->
          case deref.(id) do
            %{} = target -> part_ids_at(show, target, deref, hops - 1)
            _ -> [id]
          end

        id when is_binary(id) ->
          []

        nil when is_map(item) ->
          part_ids_at(show, item, deref, hops)

        nil ->
          []
      end
    end)
  end

  defp part_ids(%{"parts" => parts}, root, deref, hops) when is_list(parts),
    do: part_ids(parts, root, deref, hops)

  defp part_ids(%{"when" => _, "show" => show}, root, deref, hops),
    do: part_ids(show, root, deref, hops)

  defp part_ids(%{"path" => path}, root, deref, hops) when is_binary(path),
    do: part_ids_at(path, root, deref, hops)

  defp part_ids(%{"field" => field}, root, deref, hops), do: part_ids(field, root, deref, hops)

  defp part_ids(text, root, deref, hops) when is_binary(text),
    do: part_ids_at(text, root, deref, hops)

  defp part_ids(_, _root, _deref, _hops), do: []

  defp part_ids_at(show, root, deref, hops) when is_list(show),
    do: Enum.flat_map(show, &part_ids_at(&1, root, deref, hops))

  defp part_ids_at(text, root, deref, hops) when is_binary(text) do
    text
    |> slot_paths()
    |> Enum.flat_map(&(&1 |> segments() |> collect(root, deref, hops)))
  end

  defp part_ids_at(_, _root, _deref, _hops), do: []

  defp slot_paths(text) do
    raw =
      if String.contains?(text, "{"),
        do: Regex.scan(@template, text, capture: :all_but_first) |> List.flatten(),
        else: [text]

    Enum.map(raw, &(&1 |> String.split("|") |> hd() |> String.trim()))
  end

  defp collect([], _value, _deref, _hops), do: []

  defp collect([key | rest] = segs, value, deref, hops) do
    case {ref_id(value), value} do
      {id, _} when is_binary(id) and hops > 0 ->
        case deref.(id) do
          %{} = target -> collect(segs, target, deref, hops - 1)
          _ -> [id]
        end

      {id, _} when is_binary(id) ->
        []

      {nil, %{} = map} ->
        collect(rest, Map.get(map, key), deref, hops)

      {nil, list} when is_list(list) ->
        case Integer.parse(key) do
          {i, ""} when i >= 0 -> collect(rest, Enum.at(list, i), deref, hops)
          _ -> []
        end

      _ ->
        []
    end
  end

  # ── values ─────────────────────────────────────────────────────────────

  defp scalar(v) when is_binary(v), do: v
  defp scalar(v) when is_number(v), do: to_string(v)
  defp scalar(%{"current" => v}) when is_binary(v), do: v
  defp scalar(_), do: nil

  # A date ("2026-10-08") or date-time ("2026-10-08T23:30:00Z") as dd.mm.yyyy,
  # the day it is in UTC.
  defp day(v) when is_binary(v) do
    case Date.from_iso8601(v) do
      {:ok, d} ->
        dmy(d)

      _ ->
        case DateTime.from_iso8601(v) do
          {:ok, dt, _} -> dt |> DateTime.to_date() |> dmy()
          _ -> nil
        end
    end
  end

  defp day(_), do: nil

  # The number of items in a list; a missing list has none.
  defp count(list) when is_list(list), do: list |> length() |> to_string()
  defp count(nil), do: "0"
  defp count(_), do: nil

  defp dmy(%Date{} = d), do: Calendar.strftime(d, "%d.%m.%Y")

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(_), do: nil
end
