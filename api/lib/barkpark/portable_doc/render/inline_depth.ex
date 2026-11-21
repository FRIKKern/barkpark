defmodule Barkpark.PortableDoc.Render.InlineDepth do
  @moduledoc """
  Inline nesting past the depth limit keeps its words (task-11bbe4b4ae8c85f4).

  The rule every Barkpark reader shares (inline_depth.go in internal/pdrender,
  js/packages/react inline.tsx, apps/mobile inlines.tsx, and the editor's
  canvas/inline-depth.js):

    * A wrapper (a node holding `children`, or a bare list) is drawn while its
      inline depth is under `Validate.max_depth/0` (100). A text at depth `d`
      with `k` marks draws all of them when `d + k <= 100`.
    * A wrapper at depth 100 or deeper is not drawn. The words under it are,
      flat and in order, then one space and the notice. A text with more marks
      than fit draws the marks that fit, then the notice.
    * The words are read by a loop, never by recursion, down to inline depth
      `max_word_depth/0` (1000). Words deeper than that are not read; the
      notice still follows, so a document of any depth draws without a crash.
  """

  alias Barkpark.PortableDoc.Render.Chrome

  @max_word_depth 1000

  @doc "How deep the words under a cut wrapper are read, in inline levels."
  @spec max_word_depth() :: pos_integer()
  def max_word_depth, do: @max_word_depth

  @doc "The notice a cut wrapper, or a text with too many marks, ends with."
  @spec notice() :: String.t()
  def notice, do: Chrome.t("Nested too deep to show")

  @doc "Whether an inline node holds other inline nodes: a bare list, or `children`."
  @spec wrapper?(term()) :: boolean()
  def wrapper?(node) when is_list(node), do: true
  def wrapper?(%{"children" => _}), do: true
  def wrapper?(_), do: false

  @doc "A wrapper past the depth limit: the words under it, then the notice."
  @spec cut(term(), non_neg_integer()) :: String.t()
  def cut(node, depth) do
    case words(node, depth) do
      "" -> notice()
      words -> words <> " " <> notice()
    end
  end

  @doc """
  The words under an inline node, in order, read with a loop. `depth` is the
  node's own inline depth; nothing at or past `max_word_depth/0` is read.
  """
  @spec words(term(), non_neg_integer()) :: String.t()
  def words(node, depth), do: walk([{node, depth}], [])

  defp walk([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp walk([{_node, depth} | rest], acc) when depth >= @max_word_depth, do: walk(rest, acc)

  defp walk([{node, depth} | rest], acc) do
    case node do
      s when is_binary(s) ->
        walk(rest, [s | acc])

      n when is_number(n) ->
        walk(rest, [to_string(n) | acc])

      list when is_list(list) ->
        walk(children(list, depth) ++ rest, acc)

      %{"children" => kids} when is_list(kids) ->
        walk(children(kids, depth) ++ rest, acc)

      %{"children" => _} ->
        walk(rest, acc)

      %{} = map ->
        walk(rest, [leaf_text(map) | acc])

      _ ->
        walk(rest, acc)
    end
  end

  defp children(kids, depth), do: Enum.map(kids, &{&1, depth + 1})

  defp leaf_text(map) do
    case text(Map.get(map, "value")) do
      "" -> text(Map.get(map, "text"))
      value -> value
    end
  end

  defp text(s) when is_binary(s), do: s
  defp text(n) when is_number(n), do: to_string(n)
  defp text(_), do: ""
end
