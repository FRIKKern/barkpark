defmodule Barkpark.Plugins.ContentProbe do
  @moduledoc """
  Shape-safe reader for a value nested under a document's `content` map.

  Studio hands a plugin's `resolve_doc_actions/2` (and friends) a `ctx.doc`
  that may arrive in ANY of three shapes:

    * a real `%Barkpark.Content.Document{}` Ecto struct — `:content` is an atom
      field holding a plain string-keyed map (the live editor path);
    * a plain map with an ATOM `:content` key (a test/cached snapshot);
    * a plain map with a STRING `"content"` key (a JSON-decoded snapshot).

  The trap the plugins hit before this module existed: a bare
  `get_in(doc, ["content", "github", "state"])` rung run against a `%Document{}`
  raises `Document does not implement the Access behaviour`, because `get_in/2`
  demands the Access behaviour and structs do not implement it. The per-plugin
  `Registry` rescue masked the raise as log spam, so the "Adopt from GitHub"
  (and ONIX "hide publish") button silently vanished on every real task.

  `content_get/2` never raises on any doc shape. It first lifts the inner
  content map off the doc (struct → `:content` field; plain map → `"content"`
  then `:content`), then walks the string keys through that plain map trying the
  string form first and the existing-atom form second at each hop. A bare
  string-key `get_in` is NEVER run against a struct.
  """

  @doc """
  Read a value nested under a doc's `content` map by a list of STRING keys,
  tolerant of struct/plain-map and string/atom-key shapes. Returns `nil` (never
  raises) when the doc is not a map, the content map is absent, or any key on
  the path is missing.

      iex> content_get(%{"content" => %{"github" => %{"state" => "intake"}}}, ["github", "state"])
      "intake"

      iex> content_get(%{content: %{github: %{state: "intake"}}}, ["github", "state"])
      "intake"

      iex> content_get(%SomeStruct{content: %{"github" => %{"state" => "intake"}}}, ["github", "state"])
      "intake"

      iex> content_get(%{"content" => %{}}, ["github", "state"])
      nil
  """
  @spec content_get(term(), [String.t()]) :: term()
  def content_get(doc, keys) when is_map(doc) and is_list(keys) do
    doc
    |> content_map()
    |> dig(keys)
  end

  def content_get(_doc, _keys), do: nil

  # Lift the inner (plain, usually string-keyed) content map off any doc shape.
  # A struct carries `:content` as an atom field — read it directly; NEVER run a
  # bare string-key `get_in`/`Access` against a struct (that is the raise this
  # module exists to kill). A plain map may key content under `"content"` or
  # `:content`. Anything else (or a nil content) collapses to an empty map so
  # every downstream probe reads blank instead of crashing.
  defp content_map(%_struct{} = doc), do: as_map(Map.get(doc, :content))

  defp content_map(doc) when is_map(doc),
    do: as_map(Map.get(doc, "content") || Map.get(doc, :content))

  defp as_map(m) when is_map(m), do: m
  defp as_map(_), do: %{}

  # Walk the string key path through a plain map. At each hop, probe the string
  # key first, then its already-existing atom twin — so a fully atom-keyed inner
  # map (the test/cached snapshot) resolves without ever minting a new atom.
  defp dig(value, []), do: value

  defp dig(map, [key | rest]) when is_map(map) do
    case probe(map, key) do
      nil -> nil
      next -> dig(next, rest)
    end
  end

  defp dig(_non_map, _keys), do: nil

  defp probe(map, key) when is_binary(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, existing_atom(key))
      value -> value
    end
  end

  # `String.to_existing_atom/1` raises when the atom was never created; return
  # nil in that case so `Map.get(map, nil)` reads blank rather than crashing.
  # This keeps content_get non-atom-exhausting AND non-raising on unknown keys.
  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
