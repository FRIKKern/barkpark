defmodule Mix.Tasks.Barkpark.PortableDoc.GenPdParity.Limits do
  @moduledoc """
  The render limits every PortableDoc reader shares, from
  `test/support/fixtures/portable-doc-limits.json`:

      limit-docs.json              the fixture verbatim: worst-case `docs` and `edges`
      limits/<name>.golden.json    each edge rendered by the Elixir reader (`goldens/0`)

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
