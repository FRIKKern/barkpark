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
      when the path holds nothing (`"{questions|count} questions"`); `|type`
      shows a type name (`linkedDocument._type|type`) by its schema title,
      through `opts[:type_title]`, or as stored; `|text` shows the text of a
      Portable Text value, its blocks that hold text joined by a space (a
      string is its own text), `|text:line` its first block or line that holds
      text, and `|text:heading` its first heading block (style `h1` to `h6`)
      that holds text, both trimmed; `|max:N` cuts a text longer than N
      characters to its first N and adds `...` (`|max:N:…` adds `…` instead,
      and `|max:N:` nothing), after any other modifier and before the case;
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

  `media` is a path or a list of alternatives, the first that holds an image:
  a URL string (`onix.thumbnail`), or an image value with a `url`. An
  alternative can instead pick an icon by a stored value, as a Sanity
  `prepare` that returns an icon component does:

      %{"icon" => %{"path" => "pageType", "map" => %{"information" => "info-outline"},
                    "else" => "document", "empty" => "document"}}

  `path` is a path or a list of paths, the first with a value. The value
  (a string or a number) names its icon in `map`; `else` is the icon for a
  value the map does not name, and `empty` the icon when no path has a
  value. A `nil` icon, or a missing `else` or `empty`, picks nothing, and
  the next alternative is tried. `media_item/3` returns the pick. The caller
  decides whether it can draw the name.

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
  #
  # `opts`: `date_time: fun` formats a date-time a `|date` part shows, given
  # its `DateTime` in UTC. The default shows the UTC day as `dd.mm.yyyy`. The
  # LiveView Studio passes `date_time_marker/1`, and the browser shows the day
  # in the workspace time zone (`BarkparkWeb.PreviewDay`). `type_title: fun`
  # gives a type name's schema title (or nil) for a `|type` part.
  @spec format(spec() | nil, map(), deref(), keyword()) :: String.t() | nil
  def format(spec, root, deref, opts \\ [])

  def format(%{"parts" => parts} = spec, root, deref, o) when is_list(parts) do
    case parts |> Enum.map(&part(&1, root, deref, @max_hops, o)) |> Enum.reject(&is_nil/1) do
      [] -> blank_to_nil(Map.get(spec, "empty"))
      shown -> Enum.join(shown, Map.get(spec, "join") || " · ")
    end
  end

  def format(spec, root, deref, o) when is_map(root), do: part(spec, root, deref, @max_hops, o)
  def format(_spec, _root, _deref, _o), do: nil

  @doc """
  A date-time as a marker the LiveView Studio turns into a `<time>` element:
  the UTC instant between two private-use characters. `split_date_times/1`
  reads it back.
  """
  @spec date_time_marker(DateTime.t()) :: String.t()
  def date_time_marker(%DateTime{} = dt), do: "\u{E000}" <> DateTime.to_iso8601(dt) <> "\u{E001}"

  @doc """
  A text with date-time markers as a list of plain strings and
  `{:date_time, utc_iso, utc_day}` tuples, in order.
  """
  @spec split_date_times(String.t() | nil) :: [String.t() | {:date_time, String.t(), String.t()}]
  def split_date_times(nil), do: []

  def split_date_times(text) when is_binary(text) do
    ~r/\x{E000}([^\x{E001}]*)\x{E001}/u
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn piece ->
      case Regex.run(~r/^\x{E000}([^\x{E001}]*)\x{E001}$/u, piece) do
        [_, iso] ->
          case DateTime.from_iso8601(String.upcase(iso)) do
            {:ok, dt, _} ->
              {:date_time, DateTime.to_iso8601(dt), dt |> DateTime.to_date() |> dmy()}

            _ ->
              iso
          end

        nil ->
          piece
      end
    end)
  end

  @doc "A text with each date-time marker replaced by its UTC day."
  @spec plain(String.t() | nil) :: String.t() | nil
  def plain(nil), do: nil

  def plain(text) when is_binary(text) do
    text
    |> split_date_times()
    |> Enum.map_join(fn
      {:date_time, _iso, day} -> day
      piece -> piece
    end)
  end

  @doc "The image URL `spec` finds on a document, or nil (an icon pick is not one)."
  @spec media(spec() | nil, map(), deref()) :: String.t() | nil
  def media(spec, root, deref) do
    case media_item(spec, root, deref) do
      {:url, url} -> url
      _ -> nil
    end
  end

  @doc """
  The first media alternative that picks something: `{:url, url}` for an
  image, `{:icon, name}` for an icon chosen by a stored value, or nil.
  """
  @spec media_item(spec() | nil, map(), deref()) :: {:url, String.t()} | {:icon, String.t()} | nil
  def media_item(spec, root, deref) when is_map(root) do
    spec
    |> media_alternatives()
    |> Enum.find_value(fn
      {:path, path} ->
        with u when is_binary(u) <- path |> value(root, deref) |> url(), do: {:url, u}

      {:icon, icon} ->
        with n when is_binary(n) <- icon_pick(icon, root, deref), do: {:icon, n}
    end)
  end

  def media_item(_spec, _root, _deref), do: nil

  @doc "True when a media spec has an alternative: an image path or an icon pick."
  @spec media?(spec() | nil) :: boolean()
  def media?(spec), do: media_alternatives(spec) != []

  @doc "The image paths a media spec reads, in order (an icon pick's paths are not)."
  @spec media_paths(spec() | nil) :: [String.t()]
  def media_paths(spec), do: for({:path, path} <- media_alternatives(spec), do: path)

  defp media_alternatives(path) when is_binary(path) and path != "", do: [{:path, path}]
  defp media_alternatives(%{"field" => field}), do: media_alternatives(field)
  defp media_alternatives(%{"icon" => %{"path" => _} = icon}), do: [{:icon, icon}]
  defp media_alternatives(list) when is_list(list), do: Enum.flat_map(list, &media_alternatives/1)
  defp media_alternatives(_), do: []

  # The icon a stored value picks: its `map` entry, `else` for a value the map
  # does not name, `empty` when no path has a value. A nil or blank name picks
  # nothing.
  defp icon_pick(%{"path" => paths} = icon, root, deref) do
    value =
      paths
      |> List.wrap()
      |> Enum.find_value(fn
        path when is_binary(path) -> path |> value(root, deref) |> icon_key()
        _ -> nil
      end)

    name =
      case value do
        nil -> Map.get(icon, "empty")
        key -> icon |> Map.get("map") |> map_icon(key, icon)
      end

    blank_to_nil(name)
  end

  defp map_icon(%{} = map, key, icon) do
    case Map.fetch(map, key) do
      {:ok, name} -> name
      :error -> Map.get(icon, "else")
    end
  end

  defp map_icon(_map, _key, icon), do: Map.get(icon, "else")

  defp icon_key(v) when is_binary(v), do: blank_to_nil(v)
  defp icon_key(v) when is_integer(v), do: Integer.to_string(v)

  defp icon_key(v) when is_float(v),
    do: if(v == trunc(v), do: v |> trunc() |> Integer.to_string(), else: to_string(v))

  defp icon_key(%{"current" => v}), do: icon_key(v)
  defp icon_key(_), do: nil

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

  defp part(alternatives, root, deref, hops, o) when is_list(alternatives),
    do: Enum.find_value(alternatives, &part(&1, root, deref, hops, o))

  defp part(%{"each" => path} = spec, root, deref, hops, o) when is_binary(path) do
    items =
      case path |> segments() |> walk(root, deref, 0) do
        {list, _} when is_list(list) -> list
        _ -> []
      end

    max = positive(Map.get(spec, "max"))
    show = Map.get(spec, "show") || "title"

    shown =
      items
      |> Enum.map(&item_text(show, &1, deref, hops, o))
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
  defp part(%{"parts" => parts} = spec, root, deref, _hops, o) when is_list(parts),
    do: format(spec, root, deref, o)

  defp part(%{"text" => text}, _root, _deref, _hops, _o), do: blank_to_nil(text)

  # `when` is a `visibleWhen` predicate on the document (no reference is
  # followed); `show` stands only while it holds.
  defp part(%{"when" => %{} = pred} = spec, root, deref, hops, o) do
    if FieldVisibility.visible?(%{"visibleWhen" => pred}, root),
      do: part(Map.get(spec, "show"), root, deref, hops, o),
      else: nil
  end

  # A stored value shown by its label: `{"path": "pageType", "map": {"landingPage":
  # "Landingsside"}}`. A value the map does not name shows as stored.
  defp part(%{"path" => path, "map" => %{} = labels}, root, deref, hops, o)
       when is_binary(path) do
    case slot(path, root, deref, hops, o) do
      nil -> nil
      value -> blank_to_nil(Map.get(labels, value, value))
    end
  end

  defp part(text, root, deref, hops, o) when is_binary(text) do
    if String.contains?(text, "{"),
      do: template(text, root, deref, hops, o),
      else: slot(text, root, deref, hops, o)
  end

  defp part(_spec, _root, _deref, _hops, _o), do: nil

  # An item that is itself a reference reads its target, which costs a hop.
  defp item_text(show, item, deref, hops, o) do
    case ref_id(item) do
      id when is_binary(id) and hops > 0 ->
        case deref.(id) do
          %{} = target -> part(show, target, deref, hops - 1, o)
          _ -> nil
        end

      id when is_binary(id) ->
        nil

      nil ->
        if is_map(item), do: part(show, item, deref, hops, o), else: nil
    end
  end

  @template ~r/\{([^{}]+)\}/

  defp template(text, root, deref, hops, o) do
    slots = Regex.scan(@template, text, capture: :all_but_first) |> List.flatten()
    values = Map.new(slots, &{&1, slot(&1, root, deref, hops, o)})

    if Enum.any?(values, fn {_, v} -> is_nil(v) end),
      do: nil,
      else: blank_to_nil(Regex.replace(@template, text, fn _, s -> values[s] end))
  end

  defp slot(text, root, deref, hops, o) do
    [path | mods] = text |> String.split("|") |> Enum.map(&String.trim/1)
    {value, _} = path |> segments() |> walk(root, deref, hops)

    text =
      cond do
        "count" in mods -> count(value)
        "date" in mods -> day(value, o)
        "type" in mods -> type_title(value, o)
        mode = text_mode(mods) -> portable_text(value, mode)
        true -> scalar(value)
      end

    text
    |> blank_to_nil()
    |> max_cut(mods)
    |> case_mods(mods)
  end

  defp type_title(v, o) when is_binary(v) do
    case Keyword.get(o, :type_title) do
      fun when is_function(fun, 1) -> blank_to_nil(fun.(v)) || v
      _ -> v
    end
  end

  defp type_title(_, _o), do: nil

  defp text_mode(mods) do
    Enum.find_value(mods, fn
      "text" -> :all
      "text:line" -> :line
      "text:heading" -> :heading
      "text:" <> _ -> :unknown
      _ -> nil
    end)
  end

  # `|text`: a Portable Text value (a list of blocks, or one block) as text.
  # A block is a map with `children`, its `_type` "block" or none; its text
  # is its children's `text` joined.
  defp portable_text(v, :all) when is_binary(v), do: v

  defp portable_text(v, :line) when is_binary(v),
    do: v |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find(&(&1 != ""))

  defp portable_text(v, mode) when is_map(v), do: portable_text([v], mode)

  defp portable_text(blocks, :all) when is_list(blocks) do
    blocks
    |> Enum.map(&spans/1)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(" ")
  end

  defp portable_text(blocks, mode) when is_list(blocks) and mode in [:line, :heading] do
    blocks
    |> Enum.filter(&(mode == :line or heading?(&1)))
    |> Enum.find_value(fn block ->
      case spans(block) do
        t when is_binary(t) -> blank_to_nil(String.trim(t))
        _ -> nil
      end
    end)
  end

  defp portable_text(_, _mode), do: nil

  defp spans(%{"children" => children} = block) when is_list(children) do
    if Map.get(block, "_type", "block") == "block",
      do:
        Enum.map_join(children, fn
          %{"text" => t} when is_binary(t) -> t
          _ -> ""
        end),
      else: nil
  end

  defp spans(_), do: nil

  defp heading?(%{"style" => style}) when is_binary(style), do: style =~ ~r/^h[1-6]$/
  defp heading?(_), do: false

  # `|max:N`: a text longer than N characters (code points) cut to its first
  # N, and `...` after it, or the end the modifier names (`|max:80:…`).
  defp max_cut(nil, _mods), do: nil

  defp max_cut(text, mods) do
    case Enum.find_value(mods, &max_mod/1) do
      {n, ending} ->
        chars = String.codepoints(text)
        if length(chars) > n, do: Enum.join(Enum.take(chars, n)) <> ending, else: text

      nil ->
        text
    end
  end

  defp max_mod("max:" <> rest) do
    {n, ending} =
      case String.split(rest, ":", parts: 2) do
        [n] -> {n, "..."}
        [n, ending] -> {n, ending}
      end

    case Integer.parse(n) do
      {n, ""} when n > 0 -> {n, ending}
      _ -> nil
    end
  end

  defp max_mod(_), do: nil

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

  # A media icon pick reads its paths like a text part.
  defp part_ids(%{"icon" => %{"path" => paths}}, root, deref, hops),
    do: part_ids(paths, root, deref, hops)

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

  # A date ("2026-10-08") as dd.mm.yyyy; a date-time ("2026-10-08T23:30:00Z")
  # through `opts[:date_time]`, by default the day it is in UTC.
  defp day(v, o) when is_binary(v) do
    case Date.from_iso8601(v) do
      {:ok, d} ->
        dmy(d)

      _ ->
        case DateTime.from_iso8601(v) do
          {:ok, dt, _} -> date_time_day(dt, Keyword.get(o, :date_time))
          _ -> nil
        end
    end
  end

  defp day(_, _o), do: nil

  defp date_time_day(dt, fun) when is_function(fun, 1), do: fun.(dt)
  defp date_time_day(dt, _), do: dt |> DateTime.to_date() |> dmy()

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
