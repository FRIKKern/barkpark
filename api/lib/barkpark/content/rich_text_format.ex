defmodule Barkpark.Content.RichTextFormat do
  @moduledoc """
  The stored format of a `richText` field, and the schema-save aliases that
  name it (owner decision D1 on task-ab40acaf75927e0e).

  A `richText` field declares what its stored value is:

    * `"format": "portableText"` stores a Portable Text array, the shape
      Sanity stores (`_type: "block"` nodes with `children` spans, plus keyed
      custom blocks). The Classic rich-text editor edits it.
    * `"format": "portableDoc"` stores PortableDoc blocks, edited by the block
      canvas (`"editor": "blocks"`).

  A field with no `format` keeps the rule it had before the declaration
  existed. `"editor": "blocks"` means PortableDoc. A field named `body` or
  `blocks` is the legacy case: its format is read from the stored value
  (`:legacy`). Any other `richText` is Portable Text.

  Two aliases normalise at schema save (`normalise_fields/1`), so a stored
  schema only ever says `richText`:

    * `{"type": "portableText"}` becomes `{"type": "richText", "format":
      "portableText"}`.
    * Sanity's `{"type": "array", "of": [{"type": "block", …}, …]}` becomes
      the same, with the block member's `styles`, `lists`, `marks.decorators`,
      `marks.annotations` and inline `of`, and the array's other members,
      carried into the field's `blocks` vocabulary.

  `"format": "portableDoc"` without an editor gets `"editor": "blocks"`, the
  only editor that writes PortableDoc.
  """

  @formats ~w(portableText portableDoc)
  @legacy_names ~w(body blocks)

  @type format :: :portable_text | :portable_doc | :legacy

  @doc "The format names a schema may declare."
  @spec formats() :: [String.t()]
  def formats, do: @formats

  @doc """
  The stored format of a richText field map (string keys). `:legacy` is a
  field named `body` or `blocks` with no declared format and no block editor:
  its stored value decides.
  """
  @spec format(map() | nil) :: format()
  def format(%{"format" => "portableText"}), do: :portable_text
  def format(%{"format" => "portableDoc"}), do: :portable_doc
  def format(%{"editor" => "blocks"}), do: :portable_doc
  def format(%{"name" => name}) when name in @legacy_names, do: :legacy
  def format(_), do: :portable_text

  @doc "True when the field's stored value is a Portable Text array by declaration or default."
  @spec portable_text?(map() | nil) :: boolean()
  def portable_text?(field), do: format(field) == :portable_text

  @doc """
  True when `value` should be read as Portable Text for this field: a
  Portable Text field, or a legacy `body` that holds a Portable Text array
  (the gyldendal.no twin, decision 0007).
  """
  @spec stores_portable_text?(map() | nil, term()) :: boolean()
  def stores_portable_text?(field, value) do
    case format(field) do
      :portable_text -> true
      :legacy -> Barkpark.Content.PortableText.value?(value)
      :portable_doc -> false
    end
  end

  @doc """
  The type key a node of this field carries: `_type` in Portable Text,
  `type` in PortableDoc. A legacy field reads `_type` when the node has one.
  """
  @spec node_type(map() | nil, map()) :: String.t() | nil
  def node_type(field, node) when is_map(node) do
    case format(field) do
      :portable_text -> string_or_nil(node["_type"])
      :portable_doc -> string_or_nil(node["type"])
      :legacy -> string_or_nil(node["_type"]) || string_or_nil(node["type"])
    end
  end

  def node_type(_field, _node), do: nil

  defp string_or_nil(s) when is_binary(s) and s != "", do: s
  defp string_or_nil(_), do: nil

  # ── Schema-save normalisation ─────────────────────────────────────────────

  @doc """
  Normalise every richText alias in a schema's `fields` list, at any depth a
  field can sit (composite `fields`, `arrayOf`/`array` `of`, image and file
  `fields`, and the `fields` of a richText vocabulary's `of`, `inline` and
  `annotations` entries). Anything that is not a list of maps is returned
  as is.
  """
  @spec normalise_fields(term()) :: term()
  def normalise_fields(fields) when is_list(fields), do: Enum.map(fields, &normalise_field/1)
  def normalise_fields(other), do: other

  @doc "Normalise one field map. See `normalise_fields/1`."
  @spec normalise_field(term()) :: term()
  def normalise_field(%{} = field) do
    field = stringify(field)

    field =
      cond do
        field["type"] == "portableText" ->
          field |> Map.put("type", "richText") |> Map.put("format", "portableText")

        sanity_block_array?(field) ->
          from_sanity_array(field)

        true ->
          field
      end

    field
    |> put_portable_doc_editor()
    |> normalise_children()
  end

  def normalise_field(other), do: other

  @doc """
  The problems with a field list's declared richText formats, as
  `{path, message}`. An unknown format, or `portableText` on a field that uses
  the block editor (which writes PortableDoc), is refused at schema save.
  """
  @spec format_problems(term(), [String.t()]) :: [{String.t(), String.t()}]
  def format_problems(fields, prefix \\ [])

  def format_problems(fields, prefix) when is_list(fields) do
    Enum.flat_map(fields, fn
      %{} = f ->
        f = stringify(f)
        path = prefix ++ [to_string(f["name"] || "?")]
        own_format_problems(f, Enum.join(path, ".")) ++ format_problems(children(f), path)

      _ ->
        []
    end)
  end

  def format_problems(_fields, _prefix), do: []

  # `format` means something else on other types (a localizedText's
  # `format`), so only a richText field's is checked here.
  defp own_format_problems(%{"type" => "richText", "format" => fmt} = f, path)
       when not is_nil(fmt) do
    cond do
      fmt not in @formats ->
        [{path, "`format` must be one of #{Enum.join(@formats, ", ")}"}]

      fmt == "portableText" and f["editor"] == "blocks" ->
        [
          {path,
           "`format: portableText` cannot use `editor: blocks`; the block editor stores PortableDoc"}
        ]

      true ->
        []
    end
  end

  defp own_format_problems(_f, _path), do: []

  defp children(f) do
    of =
      case f["of"] do
        %{} = one -> [one]
        list when is_list(list) -> list
        _ -> []
      end

    vocab =
      case f["blocks"] do
        %{} = b ->
          Enum.flat_map(
            List.wrap(b["of"]) ++ List.wrap(b["inline"]) ++ List.wrap(b["annotations"]),
            fn
              %{} = entry -> List.wrap(entry["fields"])
              _ -> []
            end
          )

        _ ->
          []
      end

    List.wrap(f["fields"]) ++ of ++ vocab
  end

  defp put_portable_doc_editor(%{"type" => "richText", "format" => "portableDoc"} = f),
    do: Map.put_new(f, "editor", "blocks")

  defp put_portable_doc_editor(f), do: f

  defp normalise_children(f) do
    f
    |> update_if(&is_list(&1["fields"]), "fields", &normalise_fields/1)
    |> update_if(&is_list(&1["of"]), "of", &normalise_fields/1)
    |> update_if(&is_map(&1["of"]), "of", &normalise_field/1)
    |> update_if(&is_map(&1["blocks"]), "blocks", &normalise_vocabulary_fields/1)
  end

  defp normalise_vocabulary_fields(blocks) do
    Enum.reduce(~w(of inline annotations), blocks, fn key, acc ->
      case acc[key] do
        list when is_list(list) ->
          Map.put(
            acc,
            key,
            Enum.map(list, fn
              %{"fields" => fields} = entry when is_list(fields) ->
                Map.put(entry, "fields", normalise_fields(fields))

              entry ->
                entry
            end)
          )

        _ ->
          acc
      end
    end)
  end

  defp update_if(map, pred, key, fun),
    do: if(pred.(map), do: Map.update!(map, key, fun), else: map)

  defp sanity_block_array?(%{"type" => "array", "of" => of}) when is_list(of),
    do: Enum.any?(of, &block_member?/1)

  defp sanity_block_array?(_), do: false

  defp block_member?(%{"type" => "block"}), do: true
  defp block_member?(%{type: "block"}), do: true
  defp block_member?(_), do: false

  # Sanity's array of blocks as a richText field. The block member's lists
  # become the vocabulary; a key Sanity leaves out stays out, so the Sanity
  # default for it applies (`PortableTextValidation.vocabulary/1`).
  defp from_sanity_array(%{"of" => of} = field) do
    members = Enum.map(of, &stringify_any/1)
    block = Enum.find(members, &block_member?/1) || %{}
    others = Enum.reject(members, &block_member?/1)

    marks = if is_map(block["marks"]), do: stringify(block["marks"]), else: %{}

    vocab =
      %{}
      |> put_values("styles", block["styles"])
      |> put_values("lists", block["lists"])
      |> put_values("marks", marks["decorators"])
      |> put_entries("annotations", marks["annotations"])
      |> put_entries("inline", block["of"])
      |> put_entries("of", others)

    field
    |> Map.delete("of")
    |> Map.put("type", "richText")
    |> Map.put("format", "portableText")
    |> Map.update("blocks", vocab, fn
      %{} = declared -> Map.merge(vocab, stringify(declared))
      _ -> vocab
    end)
  end

  # Sanity lists styles, lists and decorators as strings or `{title, value}`.
  defp put_values(vocab, _key, nil), do: vocab

  defp put_values(vocab, key, list) when is_list(list) do
    values =
      Enum.flat_map(list, fn
        v when is_binary(v) ->
          [v]

        %{} = m ->
          case m["value"] || m[:value] do
            v when is_binary(v) -> [v]
            _ -> []
          end

        _ ->
          []
      end)

    Map.put(vocab, key, values)
  end

  defp put_values(vocab, _key, _other), do: vocab

  # An annotation, inline object or custom block member as a vocabulary
  # entry: its name (Sanity's `name`, else its `type`), title and fields.
  defp put_entries(vocab, _key, nil), do: vocab

  defp put_entries(vocab, key, list) when is_list(list) do
    entries =
      Enum.flat_map(list, fn
        %{} = m ->
          m = stringify(m)

          case m["name"] || m["type"] do
            name when is_binary(name) and name != "" ->
              entry =
                %{"name" => name}
                |> put_present("title", m["title"])
                |> put_present("fields", m["fields"])

              [entry]

            _ ->
              []
          end

        name when is_binary(name) ->
          [%{"name" => name}]

        _ ->
          []
      end)

    Map.put(vocab, key, entries)
  end

  defp put_entries(vocab, _key, _other), do: vocab

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp stringify_any(%{} = m), do: stringify(m)
  defp stringify_any(other), do: other

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
