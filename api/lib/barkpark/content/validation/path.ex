defmodule Barkpark.Content.Validation.Path do
  @moduledoc """
  JSON-Pointer-ish path resolver with a `*` wildcard for arrays.

  Path syntax:

    * `""` or `"/"` → the document root.
    * `"/foo"`      → object key `foo`.
    * `"/foo/0"`    → array index 0 inside `foo`.
    * `"/foo/*"`    → every element of array `foo` (one resolution per element).
    * `"/items/*/tags/*"` → every tag of every item.

  `~0` and `~1` are decoded to `~` and `/` per RFC 6901.

  ## Resolution semantics

    * Non-wildcard paths always emit exactly one `{concrete_path, value}`
      tuple. Missing keys yield `value: nil`.
    * Wildcard segments expand to one tuple per array element. If the
      parent isn't a list (or is missing), the wildcard contributes zero
      tuples — the rule simply doesn't fire on this expansion.
    * Concrete paths in returned tuples have integer indices substituted
      for `*` (e.g. `"/items/2/tags/0"`), matching the violation `path`
      field consumed by WI2's error envelope serializer.
  """

  @type segment :: String.t() | integer() | :wildcard
  @type resolution :: {String.t(), term()}

  @doc """
  Parse a path string into a list of segments.
  """
  @spec parse(String.t()) :: {:ok, [segment()]} | {:error, term()}
  def parse(""), do: {:ok, []}
  def parse("/"), do: {:ok, []}

  def parse("/" <> rest) do
    segments =
      rest
      |> String.split("/", trim: false)
      |> Enum.map(&decode_segment/1)

    {:ok, segments}
  end

  def parse(_), do: {:error, :must_start_with_slash}

  @doc """
  Resolve a path against a document, returning a list of
  `{concrete_path, value}` pairs. See module doc for semantics.
  """
  @spec resolve(String.t(), term()) :: [resolution()]
  def resolve(path, doc) when is_binary(path) do
    case parse(path) do
      {:ok, segs} -> walk(segs, doc, [])
      _ -> []
    end
  end

  def resolve(_, _), do: []

  # ── private ─────────────────────────────────────────────────────────────

  defp decode_segment("*"), do: :wildcard

  defp decode_segment(s) do
    decoded =
      s
      |> String.replace("~1", "/")
      |> String.replace("~0", "~")

    case Integer.parse(decoded) do
      {n, ""} -> n
      _ -> decoded
    end
  end

  defp walk([], value, prefix), do: [{render_path(prefix), value}]

  defp walk([:wildcard | rest], value, prefix) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, i} -> walk(rest, item, prefix ++ [i]) end)
  end

  defp walk([:wildcard | _], _value, _prefix), do: []

  defp walk([seg | rest], value, prefix) when is_list(value) and is_integer(seg) do
    item = Enum.at(value, seg)
    walk(rest, item, prefix ++ [seg])
  end

  defp walk([seg | rest], value, prefix) when is_map(value) and is_binary(seg) do
    child =
      case Map.fetch(value, seg) do
        {:ok, v} ->
          v

        :error ->
          case to_atom_safe(seg) do
            nil -> nil
            atom -> Map.get(value, atom)
          end
      end

    walk(rest, child, prefix ++ [seg])
  end

  # Path tries to descend through nil / scalar — surface a single nil-valued
  # resolution at the prefix reached so far. Callers (e.g. `nonempty`) can
  # then fail correctly on missing values.
  defp walk(_segs, _value, prefix), do: [{render_path(prefix), nil}]

  defp render_path([]), do: ""
  defp render_path(segs), do: "/" <> Enum.map_join(segs, "/", &to_string/1)

  defp to_atom_safe(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end
end
