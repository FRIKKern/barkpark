defmodule Barkpark.Content.PortableTextValidation do
  @moduledoc """
  Structural checks for a stored Portable Text array (stage S1 of the
  Portable Text plan, task-9296af21cac3f813).

  A richText field whose format is Portable Text (`Content.RichTextFormat`)
  stores Sanity's shape: a list of `_type: "block"` nodes with `children`
  spans and `markDefs`, and keyed custom blocks. This module checks that
  shape against the field's declared `blocks` vocabulary:

    * every block, span, mark definition and inline object has a non-empty
      `_key`, unique among its siblings;
    * a span's `text` is a string;
    * a span's mark is a declared decorator or the `_key` of a mark
      definition in the same block;
    * `style` and `listItem` are in the vocabulary, and `level` is a
      positive integer;
    * a custom block's `_type` is in the vocabulary's `of`, an inline object's
      in its `inline`, a mark definition's in its `annotations`, and each is
      checked against the fields its entry declares.

  ## The vocabulary

  A field with no `blocks` declaration has an open vocabulary: only the
  structural checks run (keys, span text, `level`). A field that declares
  `blocks` checks each kind it names. A field that also declares
  `"format": "portableText"` gives a kind it leaves out Sanity's default for
  an array of blocks; without a declared format, a kind left out stays open,
  so a schema stored before `format` existed gains no new finding for it:

    * `styles`: normal, h1 to h6, blockquote
    * `lists`: bullet, number
    * `marks` (decorators): strong, em, code, underline, strike-through
    * `annotations`: link
    * `of` (custom blocks) and `inline` (inline objects): none

  `strike-through` and `strikethrough` name the same decorator. An
  annotation entry may carry `fields`; a missing field is never required
  unless its own `validation` says so (a Sanity `linkAnnotation` stored
  without `linkType` is fine).

  ## Levels

  `findings/5` returns the structural findings only on the pass whose level
  is `structural_level`, so the caller decides whether they block. The
  fields of a custom block, an inline object or a mark definition are walked
  like a composite's subfields, at the pass's own level.
  """

  alias Barkpark.Content.Validation
  alias Barkpark.PortableDoc.FieldVocabulary

  @default_styles ~w(normal h1 h2 h3 h4 h5 h6 blockquote)
  @default_lists ~w(bullet number)
  @default_decorators ~w(strong em code underline strike-through)
  @default_annotations ~w(link)

  @codes ~w(pt_shape pt_type_missing pt_key_missing pt_key_duplicate pt_span_text
            pt_mark_undeclared pt_style_undeclared pt_list_undeclared pt_level_shape
            pt_block_type_undeclared pt_inline_type_undeclared pt_annotation_undeclared)a

  @type finding :: {String.t(), String.t(), atom(), map()}

  @typedoc """
  `:open`, or the vocabulary: string lists for styles, lists and
  decorators, and `%{name => fields}` for annotations, custom blocks (`of`)
  and inline objects. `:any` is a kind left open.
  """
  @type kind(t) :: t | :any
  @type vocabulary ::
          :open
          | %{
              styles: kind([String.t()]),
              lists: kind([String.t()]),
              decorators: kind([String.t()]),
              annotations: kind(%{String.t() => [map()]}),
              of: kind(%{String.t() => [map()]}),
              inline: kind(%{String.t() => [map()]})
            }

  @doc "Every code this module can emit."
  @spec codes() :: [atom()]
  def codes, do: @codes

  @doc """
  The field's vocabulary (string-keyed field map). See the moduledoc for the
  defaults.
  """
  @spec vocabulary(map()) :: vocabulary()
  def vocabulary(%{"blocks" => %{} = blocks} = field) do
    # A declared format takes Sanity's default for a kind it leaves out. A
    # field with no `format` (stored before the declaration existed) checks
    # only the kinds it names; the rest stay open.
    declared? = field["format"] == "portableText"
    default = fn list -> if declared?, do: list, else: :any end

    %{
      styles: values(blocks["styles"], default.(@default_styles)),
      lists: values(blocks["lists"], default.(@default_lists)),
      decorators:
        case values(blocks["marks"], default.(@default_decorators)) do
          :any -> :any
          list -> Enum.map(list, &FieldVocabulary.mark_alias/1)
        end,
      annotations: entries(blocks["annotations"], default.(@default_annotations)),
      of: entries(blocks["of"], default.([])),
      inline: entries(blocks["inline"], default.([]))
    }
  end

  def vocabulary(_field), do: :open

  defp values(nil, default), do: default

  defp values(list, _default) when is_list(list) do
    Enum.flat_map(list, fn
      v when is_binary(v) -> [v]
      %{"value" => v} when is_binary(v) -> [v]
      _ -> []
    end)
  end

  defp values(_other, default), do: default

  defp entries(nil, :any), do: :any
  defp entries(nil, default), do: Map.new(default, &{&1, []})

  defp entries(list, _default) when is_list(list) do
    for entry <- list, name = entry_name(entry), is_binary(name), into: %{} do
      fields = if is_map(entry), do: Enum.filter(List.wrap(entry["fields"]), &is_map/1), else: []
      {name, fields}
    end
  end

  defp entries(_other, default), do: entries(nil, default)

  # `:any` is a kind the field leaves open: every name passes and no fields
  # are checked.
  defp allows?(:any, _name), do: true
  defp allows?(list, name) when is_list(list), do: name in list
  defp allows?(map, name) when is_map(map), do: is_map_key(map, name)

  defp declared_fields(:any, _name), do: []
  defp declared_fields(map, name), do: Map.get(map, name, [])

  defp entry_name(%{"name" => n}) when is_binary(n) and n != "", do: n
  defp entry_name(n) when is_binary(n) and n != "", do: n
  defp entry_name(_), do: nil

  @doc """
  Findings for `value` (a Portable Text array) of `field` (string-keyed field
  map) at `path`, for the validation pass at `level`. Structural findings
  ride only the pass whose level is `structural_level`. A value that is not
  a list (absent, or HTML stored before owner ruling #44) has no finding.
  """
  @spec findings(map(), term(), String.t(), :error | :warning, :error | :warning) :: [finding()]
  def findings(field, value, path, level, structural_level \\ :error)

  def findings(field, value, path, level, structural_level) when is_list(value) do
    vocab = vocabulary(field)
    structural? = level == structural_level

    {found, _} =
      value
      |> Enum.with_index()
      |> Enum.flat_map_reduce(MapSet.new(), fn {node, idx}, seen ->
        node_path = "#{path}/#{idx}"
        {key_findings, seen} = key_check(node, node_path, seen)

        {gate(structural?, key_findings) ++
           node_findings(node, node_path, vocab, level, structural?), seen}
      end)

    found
  end

  def findings(_field, _value, _path, _level, _structural_level), do: []

  defp gate(true, findings), do: findings
  defp gate(false, _findings), do: []

  # `_key`: present, a non-empty string, unique among siblings.
  defp key_check(%{"_key" => key}, path, seen) when is_binary(key) and key != "" do
    if MapSet.member?(seen, key),
      do: {[{path, "duplicate _key #{inspect(key)}", :pt_key_duplicate, %{key: key}}], seen},
      else: {[], MapSet.put(seen, key)}
  end

  defp key_check(%{}, path, seen),
    do: {[{path, "missing _key", :pt_key_missing, %{}}], seen}

  defp key_check(_other, _path, seen), do: {[], seen}

  defp node_findings(%{"_type" => "block"} = block, path, vocab, level, structural?) do
    mark_defs = list_or_empty(block["markDefs"])
    def_keys = for %{"_key" => k} <- mark_defs, is_binary(k), into: MapSet.new(), do: k

    gate(structural?, block_shape(block, path) ++ style_list(block, path, vocab)) ++
      children_findings(block["children"], path, vocab, def_keys, level, structural?) ++
      mark_def_findings(mark_defs, path, vocab, level, structural?)
  end

  defp node_findings(%{"_type" => type} = node, path, vocab, level, structural?)
       when is_binary(type) and type != "" do
    case vocab do
      :open ->
        []

      %{of: of} ->
        if allows?(of, type),
          do: object_findings(declared_fields(of, type), node, path, level),
          else: undeclared_block(type, path, structural?)
    end
  end

  defp node_findings(%{}, path, _vocab, _level, structural?),
    do: gate(structural?, [{path, "a block without a _type", :pt_type_missing, %{}}])

  defp node_findings(_other, path, _vocab, _level, structural?),
    do: gate(structural?, [{path, "expected a block object", :pt_shape, %{}}])

  defp undeclared_block(type, path, structural?) do
    gate(structural?, [
      {path, "block type #{type} is not in this field's vocabulary", :pt_block_type_undeclared,
       %{type_name: type}}
    ])
  end

  defp block_shape(block, path) do
    children =
      case Map.get(block, "children") do
        list when is_list(list) -> []
        _ -> [{path <> "/children", "a block needs a children list", :pt_shape, %{}}]
      end

    mark_defs =
      case Map.get(block, "markDefs") do
        nil -> []
        list when is_list(list) -> []
        _ -> [{path <> "/markDefs", "markDefs must be a list", :pt_shape, %{}}]
      end

    level =
      case Map.get(block, "level") do
        nil -> []
        l when is_integer(l) and l > 0 -> []
        _ -> [{path <> "/level", "level must be a positive whole number", :pt_level_shape, %{}}]
      end

    children ++ mark_defs ++ level
  end

  defp style_list(_block, _path, :open), do: []

  defp style_list(block, path, %{styles: styles, lists: lists}) do
    style =
      case block["style"] do
        nil ->
          []

        s when is_binary(s) ->
          if allows?(styles, s),
            do: [],
            else: [
              {path <> "/style", "style #{s} is not in this field's vocabulary",
               :pt_style_undeclared, %{style: s}}
            ]

        _ ->
          [{path <> "/style", "style must be a string", :pt_style_undeclared, %{}}]
      end

    list =
      case block["listItem"] do
        nil ->
          []

        l when is_binary(l) ->
          if allows?(lists, l),
            do: [],
            else: [
              {path <> "/listItem", "list #{l} is not in this field's vocabulary",
               :pt_list_undeclared, %{list: l}}
            ]

        _ ->
          [{path <> "/listItem", "listItem must be a string", :pt_list_undeclared, %{}}]
      end

    style ++ list
  end

  defp children_findings(children, path, vocab, def_keys, level, structural?)
       when is_list(children) do
    {found, _} =
      children
      |> Enum.with_index()
      |> Enum.flat_map_reduce(MapSet.new(), fn {child, j}, seen ->
        child_path = "#{path}/children/#{j}"
        {keys, seen} = key_check(child, child_path, seen)

        {gate(structural?, keys) ++
           child_findings(child, child_path, vocab, def_keys, level, structural?), seen}
      end)

    found
  end

  defp children_findings(_children, _path, _vocab, _def_keys, _level, _structural?), do: []

  defp child_findings(%{"_type" => "span"} = span, path, vocab, def_keys, _level, structural?) do
    text =
      case Map.get(span, "text") do
        t when is_binary(t) -> []
        _ -> [{path <> "/text", "a span's text must be a string", :pt_span_text, %{}}]
      end

    gate(structural?, text ++ mark_findings(span["marks"], path, vocab, def_keys))
  end

  defp child_findings(%{"_type" => type} = node, path, vocab, _def_keys, level, structural?)
       when is_binary(type) and type != "" do
    case vocab do
      :open ->
        []

      %{inline: inline} ->
        if allows?(inline, type),
          do: object_findings(declared_fields(inline, type), node, path, level),
          else:
            gate(structural?, [
              {path, "inline #{type} is not in this field's vocabulary",
               :pt_inline_type_undeclared, %{type_name: type}}
            ])
    end
  end

  defp child_findings(%{}, path, _vocab, _def_keys, _level, structural?),
    do: gate(structural?, [{path, "a child without a _type", :pt_type_missing, %{}}])

  defp child_findings(_other, path, _vocab, _def_keys, _level, structural?),
    do: gate(structural?, [{path, "expected a span object", :pt_shape, %{}}])

  defp mark_findings(nil, _path, _vocab, _def_keys), do: []

  defp mark_findings(marks, path, vocab, def_keys) when is_list(marks) do
    marks
    |> Enum.with_index()
    |> Enum.flat_map(fn {mark, k} ->
      cond do
        not is_binary(mark) ->
          [{"#{path}/marks/#{k}", "a mark must be a string", :pt_mark_undeclared, %{}}]

        MapSet.member?(def_keys, mark) ->
          []

        decorator?(mark, vocab) ->
          []

        true ->
          [
            {"#{path}/marks/#{k}",
             "mark #{mark} is neither a declared decorator nor a markDefs key in this block",
             :pt_mark_undeclared, %{mark: mark}}
          ]
      end
    end)
  end

  defp mark_findings(_marks, path, _vocab, _def_keys),
    do: [{path <> "/marks", "marks must be a list", :pt_mark_undeclared, %{}}]

  # An open vocabulary accepts any decorator name.
  defp decorator?(_mark, :open), do: true

  defp decorator?(_mark, %{decorators: :any}), do: true

  defp decorator?(mark, %{decorators: decorators}),
    do: FieldVocabulary.mark_alias(mark) in decorators

  defp mark_def_findings(mark_defs, path, vocab, level, structural?) do
    {found, _} =
      mark_defs
      |> Enum.with_index()
      |> Enum.flat_map_reduce(MapSet.new(), fn {def, k}, seen ->
        def_path = "#{path}/markDefs/#{k}"
        {keys, seen} = key_check(def, def_path, seen)
        {gate(structural?, keys) ++ mark_def(def, def_path, vocab, level, structural?), seen}
      end)

    found
  end

  defp mark_def(%{"_type" => type} = def, path, vocab, level, structural?)
       when is_binary(type) and type != "" do
    case vocab do
      :open ->
        []

      %{annotations: annotations} ->
        if allows?(annotations, type),
          do: object_findings(declared_fields(annotations, type), def, path, level),
          else:
            gate(structural?, [
              {path, "annotation #{type} is not in this field's vocabulary",
               :pt_annotation_undeclared, %{type_name: type}}
            ])
    end
  end

  defp mark_def(%{}, path, _vocab, _level, structural?),
    do: gate(structural?, [{path, "a mark definition without a _type", :pt_type_missing, %{}}])

  defp mark_def(_other, path, _vocab, _level, structural?),
    do: gate(structural?, [{path, "expected a mark definition object", :pt_shape, %{}}])

  defp object_findings([], _node, _path, _level), do: []

  defp object_findings(fields, node, path, level),
    do: Validation.object_block_findings(fields, node, path, level)

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_), do: []
end
