defmodule Barkpark.Content.PreviewText do
  @moduledoc """
  A schema's `list_preview.subtitle`, formatted (task-f3203617ae4cf03e):
  Sanity's preview `select` + `prepare`, declared instead of coded.

  A spec is a PATH, or `%{"parts" => [path], "join" => sep, "empty" => text}`:

    * a path is a content field, or `ref.field` — one hop through a reference
      field (`"author.name"`);
    * a part may end in `|date`: a date or date-time shown as `dd.mm.yyyy`, the
      day it is in UTC, so every viewer reads the same day;
    * the parts that have a value are joined (default `" · "`), and `empty`
      stands in when none do.

  The same declaration barkpark-studio reads (`app/src/lib/preview.ts`), so the
  two Studios show the same subtitle. Pure: the caller resolves paths.
  """

  @type spec :: String.t() | %{optional(String.t()) => term()}

  @doc "The reference fields a spec reads through: `\"author\"` for `\"author.name\"`."
  @spec refs(spec() | nil) :: [String.t()]
  def refs(spec) do
    spec
    |> parts()
    |> Enum.map(&path_of/1)
    |> Enum.filter(&String.contains?(&1, "."))
    |> Enum.map(&(&1 |> String.split(".", parts: 2) |> hd()))
    |> Enum.uniq()
  end

  @doc """
  The subtitle for a document, or nil. `read` resolves a path (`"stage"`,
  `"author.name"`) to its value.
  """
  @spec format(spec() | nil, (String.t() -> term())) :: String.t() | nil
  def format(spec, read) when is_binary(spec), do: one(spec, read)

  def format(%{"parts" => parts} = spec, read) when is_list(parts) do
    case parts |> Enum.map(&one(&1, read)) |> Enum.reject(&is_nil/1) do
      [] -> blank_to_nil(Map.get(spec, "empty"))
      shown -> Enum.join(shown, Map.get(spec, "join") || " · ")
    end
  end

  def format(_spec, _read), do: nil

  defp parts(spec) when is_binary(spec), do: [spec]
  defp parts(%{"parts" => parts}) when is_list(parts), do: Enum.filter(parts, &is_binary/1)
  defp parts(_), do: []

  defp path_of(part), do: part |> String.split("|") |> hd() |> String.trim()

  defp one(part, read) when is_binary(part) do
    value = read.(path_of(part))

    text =
      if String.contains?(part, "|date"),
        do: day(value),
        else: scalar(value)

    blank_to_nil(text)
  end

  defp one(_part, _read), do: nil

  defp scalar(v) when is_binary(v), do: v
  defp scalar(v) when is_number(v), do: to_string(v)
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

  defp dmy(%Date{} = d), do: Calendar.strftime(d, "%d.%m.%Y")

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(_), do: nil
end
