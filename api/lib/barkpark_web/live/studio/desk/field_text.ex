defmodule BarkparkWeb.Studio.Desk.FieldText do
  @moduledoc """
  A field's value as a read-only document pane prints it.

  Rich text reads as its text, a paragraph per block: a PortableDoc value
  (`%{"blocks" => [...]}`, text nodes `%{"type" => "text", "value" => ...}`)
  and Sanity-style portable text (a list of `_type: "block"` with span
  `children`).

  The rest reads as the TanStack Studio's read-only form shows it, not as
  JSON: a slug as its text, a yes/no as Yes or No, a date as the workspace's
  day (a date-time as a `PreviewText` marker, which `PreviewDay` turns into
  the day in the workspace's time zone), a list of plain values as a comma
  list, an object as one "Label: value" line per field. What is left (an
  odd shape) prints as JSON. All of it is cut at 600 characters.
  """

  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content.PreviewText

  @max 600

  @doc """
  The text a read-only pane prints for `value`, a value of the schema field
  `field` (its `type` and, for an object, its `fields`).
  """
  @spec show(term(), map()) :: String.t()
  def show(value, field \\ %{}), do: value |> value(field) |> blank()

  @doc """
  The same text, but an empty value stays empty: the read-only pane draws it
  as an empty box, as TanStack's disabled input.
  """
  @spec value(term(), map()) :: String.t()
  def value(value, field \\ %{}), do: value |> text(field || %{}) |> cut()

  defp blank(""), do: "—"
  defp blank(text), do: text

  defp text(nil, _field), do: ""
  defp text(value, _field) when is_binary(value) and value == "", do: ""
  defp text(true, _field), do: pgettext("boolean", "Yes")
  defp text(false, _field), do: pgettext("boolean", "No")
  defp text(value, _field) when is_number(value), do: to_string(value)

  defp text(value, %{"type" => type}) when is_binary(value) and type in ["date", "datetime"],
    do: day(value)

  defp text(value, _field) when is_binary(value), do: value

  # A slug, a reference that names no title of its own.
  defp text(%{"current" => current}, _field) when is_binary(current), do: current
  defp text(%{"_ref" => ref}, _field) when is_binary(ref), do: ref

  defp text(value, field) do
    case rich_text(value) do
      nil -> plain(value, field)
      text -> text
    end
  end

  # A list of plain values: a comma list. A list of objects: a line each.
  defp plain(list, field) when is_list(list) do
    of = item_field(field)

    if Enum.all?(list, &(not is_map(&1) and not is_list(&1))) do
      list |> Enum.map(&text(&1, of)) |> Enum.reject(&(&1 == "")) |> Enum.join(", ")
    else
      list
      |> Enum.map(fn item -> item |> text(of) |> String.replace("\n", ", ") end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  # An object: "Label: value" per field that has a value, in the schema's
  # order, then any key the schema does not name; `_type`, `_key` left out.
  defp plain(map, field) when is_map(map) do
    named = for %{"name" => name} = f <- List.wrap(field["fields"]), do: {name, f}
    known = MapSet.new(named, &elem(&1, 0))

    rest =
      for {key, _} <- Enum.sort(map),
          not String.starts_with?(key, "_"),
          not MapSet.member?(known, key),
          do: {key, %{}}

    (named ++ rest)
    |> Enum.map(fn {name, f} -> {f["title"] || label(name), text(map[name], f)} end)
    |> Enum.reject(fn {_label, value} -> value == "" end)
    |> Enum.map_join("\n", fn {label, value} -> "#{label}: #{value}" end)
  end

  defp plain(value, _field), do: Jason.encode!(value, pretty: true)

  defp item_field(%{"of" => [%{} = of | _]}), do: of
  defp item_field(%{"of" => %{} = of}), do: of
  defp item_field(_field), do: %{}

  # "metaTitle" or "meta_title" as "Meta title".
  defp label(name) do
    name
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.replace("_", " ")
    |> String.downcase()
    |> String.capitalize()
  end

  # A day as the workspace prints it (dd.mm.yyyy); a date-time as a marker
  # `PreviewDay` shows as its day in the workspace's time zone.
  defp day(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} ->
        PreviewText.date_time_marker(at)

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} -> Calendar.strftime(date, "%d.%m.%Y")
          _ -> value
        end
    end
  end

  defp cut(text) do
    if String.length(text) > @max, do: String.slice(text, 0, @max) <> " …", else: text
  end

  defp rich_text(%{"blocks" => blocks}) when is_list(blocks), do: paragraphs(blocks)

  defp rich_text([%{"_type" => "block"} | _] = blocks), do: paragraphs(blocks)

  defp rich_text(_value), do: nil

  defp paragraphs(blocks) do
    blocks
    |> Enum.map(&(&1 |> inline() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # The text of one block, its leaves in order.
  defp inline(%{"type" => "text", "value" => value}) when is_binary(value), do: value
  defp inline(%{"_type" => "span", "text" => text}) when is_binary(text), do: text

  # A run of spans is one line of text (a bold word sits flush with the next);
  # nested blocks (list items, a card's body) are separate words.
  defp inline(%{} = node) do
    runs = join(Enum.flat_map(["content", "children"], &List.wrap(node[&1])), "")
    nested = join(Enum.flat_map(["items", "blocks"], &List.wrap(node[&1])), " ")
    join_text([runs, nested], " ")
  end

  defp inline(_other), do: ""

  defp join(nodes, sep), do: nodes |> Enum.map(&inline/1) |> join_text(sep)

  defp join_text(parts, sep), do: parts |> Enum.reject(&(&1 == "")) |> Enum.join(sep)
end
