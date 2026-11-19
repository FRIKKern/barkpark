defmodule Mix.Tasks.Barkpark.PortableDoc.GenPdParity.Limits do
  @moduledoc """
  The render limits every PortableDoc reader shares, from
  `test/support/fixtures/portable-doc-limits.json`:

      limit-docs.json              the fixture verbatim: worst-case `docs` and `edges`
      limits/<name>.golden.json    each edge rendered by the Elixir reader (`goldens/0`)
      limits/value-too-deep.json   the value-depth limit of validate (`value_depth/0`)
      limits/markdown-input.json   the Markdown import's input size (`markdown_input/0`)

  The fixture writes long docs with four macros (see its `_comment`); `expand/1`
  is the reference expansion.
  """

  alias Barkpark.PortableDoc.Render
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity

  @fixture Path.expand("../../../test/support/fixtures/portable-doc-limits.json", __DIR__)

  def fixture, do: @fixture

  def docs, do: entries("docs")

  def edges, do: entries("edges")

  def goldens do
    Enum.map(edges(), fn {name, input} ->
      html = Render.render_block(input, %{style: :article})

      {"limits/#{slug(name)}.golden.json",
       %{
         "name" => name,
         "input" => input,
         "expectedHtml" => html,
         "shape" => GenPdParity.shape(html)
       }}
    end)
  end

  def slug(name), do: String.replace(name, " ", "-")

  @doc """
  `limits/value-too-deep.json`: a chart whose series item nests an open field
  so the whole doc is exactly `Validate.max_value_depth/0` JSON levels deep
  (valid), and one level more (`too_deep` at the first path past it). The doc is
  level 1, `blocks` 2, the chart 3, `series` 4, the item 5, `x` 6. Each case is
  `{"name", "doc", "expect"}`, `expect` the `{code, path}` errors as in
  portable-doc's `fixtures/broken`.
  """
  def value_depth do
    max = Barkpark.PortableDoc.Validate.max_value_depth()

    {"limits/value-too-deep.json",
     %{
       "maxValueDepth" => max,
       "cases" => [
         %{"name" => "series at the value-depth limit", "doc" => chart_at(max), "expect" => []},
         %{
           "name" => "series one level past the value-depth limit",
           "doc" => chart_at(max + 1),
           "expect" => [
             %{
               "code" => "too_deep",
               "path" => "/blocks/0/series/0/x" <> String.duplicate("/0", max + 1 - 6)
             }
           ]
         }
       ]
     }}
  end

  @doc """
  `limits/markdown-input.json`: the largest Markdown input every importer takes,
  in bytes (`FromMarkdown.Budget.max_bytes/0`), and the error code for input
  over it, refused before parsing. Each case is `{"name", "markdown", "expect"}`;
  `markdown` uses the `$text` macro of `limit-docs.json`, and `expect` is
  `"imports"` or `{"error": code}`.
  """
  def markdown_input do
    max = Barkpark.PortableDoc.FromMarkdown.Budget.max_bytes()
    code = "markdown_too_large"

    {"limits/markdown-input.json",
     %{
       "maxMarkdownBytes" => max,
       "errorCode" => code,
       "cases" => [
         %{
           "name" => "markdown at the input size",
           "markdown" => %{"$text" => "a", "times" => max},
           "expect" => "imports"
         },
         %{
           "name" => "markdown one byte over the input size",
           "markdown" => %{"$text" => "a", "times" => max + 1},
           "expect" => %{"error" => code}
         }
       ]
     }}
  end

  defp chart_at(total) do
    x = Enum.reduce(6..(total - 1)//1, [], fn _, inner -> [inner] end)

    %{
      "blocks" => [
        %{
          "type" => "chart",
          "kind" => "line",
          "series" => [%{"label" => "s", "points" => [1], "x" => x}]
        }
      ]
    }
  end

  def expand(%{"$repeat" => n, "of" => x}), do: List.duplicate(expand(x), n)
  def expand(%{"$text" => s, "times" => n}), do: String.duplicate(s, n)

  def expand(%{"$concat" => parts}) do
    case Enum.map(parts, &expand/1) do
      [first | _] = all when is_binary(first) -> Enum.join(all)
      all -> Enum.concat(all)
    end
  end

  def expand(%{"$nest" => n, "wrap" => wrap, "leaf" => leaf}),
    do: Enum.reduce(1..n//1, expand(leaf), fn _, inner -> fill(wrap, inner) end)

  def expand(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, expand(v)} end)
  def expand(list) when is_list(list), do: Enum.map(list, &expand/1)
  def expand(value), do: value

  defp fill("$hole", inner), do: inner
  defp fill(map, inner) when is_map(map), do: Map.new(map, fn {k, v} -> {k, fill(v, inner)} end)
  defp fill(list, inner) when is_list(list), do: Enum.map(list, &fill(&1, inner))
  defp fill(value, _inner), do: value

  defp entries(key) do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!(key)
    |> Enum.map(&{&1["name"], expand(&1["doc"])})
  end
end
