defmodule Barkpark.PortableDoc.FieldVocabulary do
  @moduledoc """
  The block vocabulary a schema `richText` field DECLARES — and the server-side
  check that a field's block array stays inside it.

  A field opts in with `"editor": "blocks"` and describes what an author may
  put in it, in the shape Sanity's block-content registry uses so an editor who
  learned one studio reads the other's schema without translation:

      %{
        "styles" => ["normal", "h2", "h3", "blockquote"],
        "lists" => ["bullet", "number"],
        "marks" => ["strong", "em"],
        "annotations" => [%{"name" => "link", "fields" => [%{"name" => "href", "type" => "string"}]}],
        "of" => ["image"]
      }

  The mapping onto portable-doc block types is fixed here, once:

    * `normal`      → `paragraph`
    * `h1`…`h6`     → `heading` with that `level`
    * `blockquote`  → `pullquote`
    * `bullet`      → `list` with `ordered: false`; `number` → `ordered: true`
    * `marks`       → the inline node types allowed inside prose
                      (`text` is always allowed)
    * `annotations` → inline `link` (the only annotation portable-doc carries)
    * `of`          → extra block types (`image`, `divider`, `code`, `diagram`),
                      or a custom object block `{"name": "callout", "fields": […]}`
                      whose fields every block of that type must satisfy
                      (task-152cacba913a4724; checked by
                      `Content.Validation.object_block_findings/3`)
    * `inline`      → inline object types allowed inside prose
                      (task-85fee859cf3bfef6): `{"name": "chip", "fields": […]}`,
                      or a bare name whose fields are not checked. Sanity
                      declares these as the `of` of its `block` type; here
                      `of` already holds the extra block types, so they get
                      their own key

  A custom object block's `name` colliding with one of the four built-ins
  above (or any other name already in `of`) is NOT refused at schema save —
  **the declared shape wins** for every block carrying that name, in BOTH
  enforcement paths (this module's `validate/2`, and the v2 schema walk's
  `Content.Validation.walk_field/4`): `object_block_types/1` only reads the
  OBJECT entries of `of`, so a same-named bare string is simply shadowed, not
  conflicting. A schema author who names a custom block `"image"` gets an
  `image` whose shape is THEIRS, not portable-doc's bare built-in, read
  consistently by every door — never a refused schema, never two doors
  disagreeing about what the name means (task-839f9bebf5628c03).

  An inline object is stored flat inside a block's prose, the same shape as
  a custom object block: `{"type" => "chip", "text" => "Reviewed", "tone" =>
  "positive"}`. A Sanity span-sibling `{"_type": "chip", "_key": …, …fields}`
  maps to it by renaming `_type` to `type`; `_key` may ride along and is not
  read. A declared inline name that is also a built-in inline type (the
  verdict `chip`) follows the same rule as a block: the declared fields are
  what this field checks.

  The client enforces the same vocabulary calmly (slash menu + a
  `filterTransaction` veto); THIS module is the truth the write path checks,
  so a hand-rolled op cannot smuggle an out-of-vocabulary block into a field.
  """

  alias Barkpark.Content.Validation

  @style_types %{"normal" => "paragraph", "blockquote" => "pullquote"}
  @heading_styles ~w(h1 h2 h3 h4 h5 h6)
  @inline_always ~w(text)
  @inline_marks ~w(strong em strikethrough underline code)
  # The list kinds this vocabulary can name (`bullet` → ordered:false,
  # `number` → ordered:true) and the extra block types `of` can admit — the
  # two halves of the moduledoc mapping that have no table of their own.
  @list_kinds ~w(bullet number)
  @of_types ~w(image divider code diagram)
  # `link` is the only annotation portable-doc carries (moduledoc).
  @annotation_types ~w(link)

  @type vocabulary :: map()

  @doc "True when the field map declares the block editor."
  @spec blocks_field?(map()) :: boolean()
  def blocks_field?(%{"editor" => "blocks"}), do: true
  def blocks_field?(_), do: false

  @doc """
  The DEFAULT declaration — what a field opting into the block editor gets
  when it does NOT narrow the vocabulary itself.

  There is no second, hand-typed list here: every entry is derived from THIS
  module's own mapping tables (`@style_types`, `@heading_styles`,
  `@inline_marks`, `@list_kinds`, `@of_types`, `@annotation_types`), so the
  default is exactly "every block and mark this vocabulary language can
  express" — the papers surface's own block set, which the paper editor's
  `<bp-paper-canvas>` run carries UNRESTRICTED (it stamps no
  `data-canvas-vocabulary` at all). A field that DOES declare `"blocks"`
  narrows this; it never widens it, because a declaration is read verbatim.

  Returned in the DECLARATION shape (the Sanity-shaped registry a schema
  author writes), not the normalised one, so the same value can ride to the
  client as `data-canvas-vocabulary` and back through `from_field/1`.
  """
  @spec default_declaration() :: map()
  def default_declaration do
    %{
      "styles" => Enum.sort(Map.keys(@style_types)) ++ @heading_styles,
      "lists" => @list_kinds,
      "marks" => @inline_marks,
      "annotations" => @annotation_types,
      "of" => @of_types
    }
  end

  @doc """
  The declared vocabulary, normalised. Absent keys mean "nothing of that kind"
  — EXCEPT for a field that opted into the block editor and declared no
  `"blocks"` registry at all: that field gets `default_declaration/0`, so
  `"editor": "blocks"` alone is a complete opt-in rather than an editor with
  an empty slash menu that refuses every op.
  """
  @spec from_field(map()) :: vocabulary()
  def from_field(%{"blocks" => v}) when is_map(v), do: normalise(v)
  def from_field(%{"editor" => "blocks"}), do: normalise(default_declaration())
  def from_field(_), do: normalise(%{})

  defp normalise(v) do
    %{
      styles: list_of_strings(v["styles"]),
      lists: list_of_strings(v["lists"]),
      marks: list_of_strings(v["marks"]),
      annotations:
        v["annotations"] |> List.wrap() |> Enum.map(&annotation_name/1) |> Enum.reject(&is_nil/1),
      of: list_of_strings(v["of"]) ++ Map.keys(Validation.object_block_types(%{"blocks" => v})),
      objects: Validation.object_block_types(%{"blocks" => v}),
      inline_objects: inline_object_types(v["inline"])
    }
  end

  # `blocks.inline` entries as `%{name => fields}`. A bare string declares the
  # type with no fields to check; an entry without a string `name` is skipped.
  defp inline_object_types(list) when is_list(list) do
    for entry <- list, name = inline_name(entry), is_binary(name), into: %{} do
      fields = if is_map(entry), do: Enum.filter(List.wrap(entry["fields"]), &is_map/1), else: []
      {name, fields}
    end
  end

  defp inline_object_types(_), do: %{}

  defp inline_name(%{"name" => n}) when is_binary(n), do: n
  defp inline_name(n) when is_binary(n), do: n
  defp inline_name(_), do: nil

  @doc """
  True when a richText field map declares at least one inline object type
  under `blocks.inline`. Such a field has a closed inline vocabulary that the
  schema walk checks (`Content.Validation`), not only the block-op write path.
  """
  @spec declares_inline?(map() | nil) :: boolean()
  def declares_inline?(%{"blocks" => %{"inline" => list}}),
    do: map_size(inline_object_types(list)) > 0

  def declares_inline?(_), do: false

  defp annotation_name(%{"name" => n}) when is_binary(n), do: n
  defp annotation_name(n) when is_binary(n), do: n
  defp annotation_name(_), do: nil

  defp list_of_strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp list_of_strings(_), do: []

  @doc "Block types (portable-doc names) the vocabulary admits."
  @spec allowed_block_types(vocabulary()) :: MapSet.t()
  def allowed_block_types(%{styles: styles, lists: lists, of: of}) do
    from_styles =
      styles
      |> Enum.flat_map(fn
        s when s in @heading_styles -> ["heading"]
        s -> List.wrap(Map.get(@style_types, s))
      end)

    from_lists = if lists == [], do: [], else: ["list"]

    MapSet.new(from_styles ++ from_lists ++ of)
  end

  @doc "Heading levels the vocabulary admits (empty when headings are not allowed)."
  @spec allowed_heading_levels(vocabulary()) :: MapSet.t()
  def allowed_heading_levels(%{styles: styles}) do
    styles
    |> Enum.filter(&(&1 in @heading_styles))
    |> Enum.map(&String.to_integer(String.slice(&1, 1..1)))
    |> MapSet.new()
  end

  @doc "Inline node types the vocabulary admits inside prose."
  @spec allowed_inline_types(vocabulary()) :: MapSet.t()
  def allowed_inline_types(%{marks: marks, annotations: annotations} = vocab) do
    MapSet.new(
      @inline_always ++
        Enum.filter(marks, &(&1 in @inline_marks)) ++
        annotations ++ Map.keys(Map.get(vocab, :inline_objects, %{}))
    )
  end

  @doc """
  Check every block (and every inline leaf) against the vocabulary.

  Returns `:ok`, or `{:error, {:out_of_vocabulary, reason}}` naming the first
  offending block/inline so the refusal can be shown, not guessed.
  """
  @spec validate(vocabulary(), [map()]) :: :ok | {:error, {:out_of_vocabulary, String.t()}}
  def validate(vocab, blocks) when is_list(blocks) do
    types = allowed_block_types(vocab)
    levels = allowed_heading_levels(vocab)

    Enum.reduce_while(blocks, :ok, fn block, :ok ->
      case check_block(block, types, levels, vocab) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_block(%{"type" => type} = block, types, levels, vocab) do
    cond do
      not MapSet.member?(types, type) ->
        {:error, {:out_of_vocabulary, "block type #{type} is not in this field's vocabulary"}}

      type == "heading" and not MapSet.member?(levels, heading_level(block)) ->
        {:error,
         {:out_of_vocabulary,
          "heading level #{heading_level(block)} is not in this field's vocabulary"}}

      type == "list" and not list_kind_allowed?(block, vocab) ->
        {:error,
         {:out_of_vocabulary,
          "#{if block["ordered"], do: "numbered", else: "bulleted"} lists are not in this field's vocabulary"}}

      true ->
        with :ok <- check_object(block, vocab), do: check_inlines(block, vocab)
    end
  end

  defp check_block(_block, _types, _levels, _vocab),
    do: {:error, {:out_of_vocabulary, "a block without a type"}}

  # A custom object block's declared fields (task-152cacba913a4724).
  defp check_object(%{"type" => type} = block, %{objects: objects})
       when is_map_key(objects, type) do
    case Validation.object_block_findings(Map.fetch!(objects, type), block, type) do
      [] -> :ok
      [{path, msg, _code, _params} | _] -> {:error, {:out_of_vocabulary, "#{path}: #{msg}"}}
    end
  end

  defp check_object(_block, _vocab), do: :ok

  defp heading_level(%{"level" => l}) when is_integer(l), do: l
  defp heading_level(_), do: 1

  defp list_kind_allowed?(%{"ordered" => true}, %{lists: lists}), do: "number" in lists
  defp list_kind_allowed?(_block, %{lists: lists}), do: "bullet" in lists

  defp check_inlines(block, vocab) do
    case inline_findings(vocab, block, Map.get(block, "type", ""), :error) do
      [] -> :ok
      [{_path, msg, :inline_type_undeclared, _} | _] -> {:error, {:out_of_vocabulary, msg}}
      [{path, msg, _code, _} | _] -> {:error, {:out_of_vocabulary, "#{path}: #{msg}"}}
    end
  end

  @doc """
  Findings for the inline nodes in ONE block's prose, as
  `[{path, message, code, params}]` (the `Content.Validation` finding shape).

  An inline node whose type the vocabulary does not admit is
  `:inline_type_undeclared` (reported only at `level` `:error`, like every
  other structural finding). A declared inline object has its declared fields
  walked like a custom object block's, at `level`. Wrapper nodes (`strong`,
  `link`, …) are descended into through `children`.

  Prose lives in `content` (paragraph/pullquote), `items` (a list of inline
  lists), or is a flat string (`text` on a heading). Anything else is opaque
  to the vocabulary (an image's src/alt are attributes, not prose).
  """
  @spec inline_findings(vocabulary(), map(), String.t(), :error | :warning) :: [
          {String.t(), String.t(), atom(), map()}
        ]
  def inline_findings(vocab, block, path, level)

  def inline_findings(vocab, %{"content" => content}, path, level) when is_list(content),
    do: inline_list_findings(content, "#{path}/content", vocab, level)

  def inline_findings(vocab, %{"items" => items}, path, level) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {item, i} when is_list(item) ->
        inline_list_findings(item, "#{path}/items/#{i}", vocab, level)

      _ ->
        []
    end)
  end

  def inline_findings(_vocab, _block, _path, _level), do: []

  defp inline_list_findings(nodes, path, vocab, level) do
    allowed = allowed_inline_types(vocab)
    objects = Map.get(vocab, :inline_objects, %{})

    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"type" => t} = node, j} when is_binary(t) ->
        node_path = "#{path}/#{j}"

        cond do
          not MapSet.member?(allowed, t) ->
            if level == :error,
              do: [
                {node_path, "inline #{t} is not in this field's vocabulary",
                 :inline_type_undeclared, %{type_name: t}}
              ],
              else: []

          is_map_key(objects, t) ->
            Validation.object_block_findings(Map.fetch!(objects, t), node, node_path, level)

          is_list(node["children"]) ->
            inline_list_findings(node["children"], "#{node_path}/children", vocab, level)

          true ->
            []
        end

      _ ->
        []
    end)
  end
end
