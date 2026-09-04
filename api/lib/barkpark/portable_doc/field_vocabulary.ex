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
    * `of`          → extra block types (`image`, `divider`, `code`, `diagram`)

  The client enforces the same vocabulary calmly (slash menu + a
  `filterTransaction` veto); THIS module is the truth the write path checks,
  so a hand-rolled op cannot smuggle an out-of-vocabulary block into a field.
  """

  @style_types %{"normal" => "paragraph", "blockquote" => "pullquote"}
  @heading_styles ~w(h1 h2 h3 h4 h5 h6)
  @inline_always ~w(text)
  @inline_marks ~w(strong em strikethrough underline code)

  @type vocabulary :: map()

  @doc "True when the field map declares the block editor."
  @spec blocks_field?(map()) :: boolean()
  def blocks_field?(%{"editor" => "blocks"}), do: true
  def blocks_field?(_), do: false

  @doc """
  The declared vocabulary, normalised. Absent keys mean "nothing of that kind".
  """
  @spec from_field(map()) :: vocabulary()
  def from_field(%{"blocks" => v}) when is_map(v), do: normalise(v)
  def from_field(_), do: normalise(%{})

  defp normalise(v) do
    %{
      styles: list_of_strings(v["styles"]),
      lists: list_of_strings(v["lists"]),
      marks: list_of_strings(v["marks"]),
      annotations:
        v["annotations"] |> List.wrap() |> Enum.map(&annotation_name/1) |> Enum.reject(&is_nil/1),
      of: list_of_strings(v["of"])
    }
  end

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
  def allowed_inline_types(%{marks: marks, annotations: annotations}) do
    MapSet.new(@inline_always ++ Enum.filter(marks, &(&1 in @inline_marks)) ++ annotations)
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
    inlines = allowed_inline_types(vocab)

    Enum.reduce_while(blocks, :ok, fn block, :ok ->
      case check_block(block, types, levels, inlines, vocab) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_block(%{"type" => type} = block, types, levels, inlines, vocab) do
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
        check_inlines(block, inlines)
    end
  end

  defp check_block(_block, _types, _levels, _inlines, _vocab),
    do: {:error, {:out_of_vocabulary, "a block without a type"}}

  defp heading_level(%{"level" => l}) when is_integer(l), do: l
  defp heading_level(_), do: 1

  defp list_kind_allowed?(%{"ordered" => true}, %{lists: lists}), do: "number" in lists
  defp list_kind_allowed?(_block, %{lists: lists}), do: "bullet" in lists

  # Prose lives in `content` (paragraph/pullquote), `items` (list — a list of
  # inline lists), or is a flat string (`text` on a heading). Anything else is
  # opaque to the vocabulary (an image's src/alt are attributes, not prose).
  defp check_inlines(%{"content" => content}, inlines) when is_list(content),
    do: check_inline_list(content, inlines)

  defp check_inlines(%{"items" => items}, inlines) when is_list(items) do
    Enum.reduce_while(items, :ok, fn
      item, :ok when is_list(item) ->
        case check_inline_list(item, inlines) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end

      _item, :ok ->
        {:cont, :ok}
    end)
  end

  defp check_inlines(_block, _inlines), do: :ok

  defp check_inline_list(nodes, inlines) do
    Enum.reduce_while(nodes, :ok, fn
      %{"type" => t} = node, :ok ->
        if MapSet.member?(inlines, t) do
          case node do
            %{"children" => children} when is_list(children) ->
              case check_inline_list(children, inlines) do
                :ok -> {:cont, :ok}
                err -> {:halt, err}
              end

            _ ->
              {:cont, :ok}
          end
        else
          {:halt, {:error, {:out_of_vocabulary, "inline #{t} is not in this field's vocabulary"}}}
        end

      _node, :ok ->
        {:cont, :ok}
    end)
  end
end
