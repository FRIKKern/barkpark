defmodule Barkpark.PortableDoc.HtmlSanitizer.StyleGrammar do
  @moduledoc """
  The values the Paper renderer writes for each CSS property in a `style`
  attribute, read at compile time off what it renders (the goldens'
  `expectedHtml`, the page and email goldens) and off the literal styles in
  `render.ex` and `render/*.ex` (#28404 review, B2).

  A value is read as its shape: lower case, spaces around commas and
  parentheses dropped, every hex colour `#h`, every number `N` with its unit.
  `margin: 0 0 16px` is `N Npx`… `N N Npx`. A stored declaration is kept only
  when its property has that shape in what the renderer writes, and each of its
  numbers is in range:

    * no number below 0, unless the renderer writes one there itself (the
      divider mark's `top: -0.7rem`, a `letter-spacing`), and then no larger;
    * a `%` at most 100;
    * a length (`px`, `em`, `rem`, `pt`) at most the largest the renderer
      writes for that property in that unit;
    * a plain number at most the largest the renderer writes for that
      property, or 12 (a column count, a grid span), whichever is larger;
      `line-height` and `opacity` at most what the renderer writes.

  `opacity` keeps only the values the renderer writes. So nothing stored can
  size itself past the renderer's own boxes or pull itself over what came
  before it.
  """

  defmodule Shape do
    @moduledoc false
    # `{shape, numbers, normal}` of a value (the outer moduledoc).
    def read(value) do
      value =
        value
        |> String.downcase()
        |> String.replace(~r/\s+/, " ")
        |> String.replace(~r/\s*([,()])\s*/, "\\1")
        |> String.trim()
        |> String.replace(~r/#[0-9a-f]{3,8}(?![0-9a-z])/, "#h")

      numbers =
        ~r/(?<![a-z0-9_.-])(-?)(\d+(?:\.\d+)?|\.\d+)(px|em|rem|%|pt|fr)?(?![a-z0-9.])/
        |> Regex.scan(value, capture: :all_but_first)
        # A unit left out is a group the scan drops, not an empty one.
        |> Enum.map(&(&1 ++ List.duplicate("", 3 - length(&1))))
        |> Enum.map(fn [sign, n, unit] ->
          {x, _} = Float.parse(if String.starts_with?(n, "."), do: "0" <> n, else: n)
          {unit, if(sign == "-", do: -x, else: x)}
        end)

      shape =
        Regex.replace(
          ~r/(?<![a-z0-9_.-])-?(?:\d+(?:\.\d+)?|\.\d+)(px|em|rem|%|pt|fr)?(?![a-z0-9.])/,
          value,
          "N\\1"
        )

      {shape, numbers, value}
    end
  end

  dir = Path.expand("..", __DIR__)
  goldens = Path.expand("../../../../priv/portable_doc/goldens", __DIR__)

  sources = [Path.join(dir, "render.ex") | Path.wildcard(Path.join(dir, "render/*.ex"))]
  jsons = Path.wildcard(Path.join(goldens, "*/*.golden.json"))
  pages = [Path.join(goldens, "email.html") | Path.wildcard(Path.join(goldens, "pages/*.html"))]
  for path <- sources ++ jsons ++ pages, do: @external_resource(path)

  rendered =
    Enum.flat_map(jsons, fn path ->
      case path |> File.read!() |> Jason.decode!() do
        %{"expectedHtml" => html} when is_binary(html) -> [html]
        _ -> []
      end
    end) ++ Enum.map(pages, &File.read!/1)

  styles =
    Enum.flat_map(rendered, &Regex.scan(~r/style="([^"]*)"/, &1, capture: :all_but_first)) ++
      Enum.flat_map(sources, fn path ->
        Regex.scan(~r/style=\\?"([^"\\]*)/, File.read!(path), capture: :all_but_first)
      end)

  # %{property => %{shapes:, max: %{unit => largest}, low: %{unit => lowest}, values:}}
  table =
    styles
    |> List.flatten()
    |> Enum.map(&String.replace(&1, "&quot;", "\""))
    |> Enum.flat_map(&String.split(&1, ";"))
    # A declaration the source builds by interpolation is read off the goldens.
    |> Enum.reject(&String.contains?(&1, "\#{"))
    |> Enum.flat_map(fn decl ->
      case String.split(decl, ":", parts: 2) do
        [prop, val] ->
          prop = prop |> String.trim() |> String.downcase()

          if Regex.match?(~r/^-?-?[a-z][a-z0-9-]*$/, prop),
            do: [{prop, String.trim(val)}],
            else: []

        _ ->
          []
      end
    end)
    |> Enum.reject(fn {_prop, val} -> val == "" end)
    |> Enum.reduce(%{}, fn {prop, val}, acc ->
      {shape, numbers, normal} = __MODULE__.Shape.read(val)

      entry =
        Map.get(acc, prop, %{shapes: MapSet.new(), max: %{}, low: %{}, values: MapSet.new()})

      entry =
        Enum.reduce(numbers, entry, fn {unit, x}, e ->
          %{
            e
            | max: Map.update(e.max, unit, x, &max(&1, x)),
              low: Map.update(e.low, unit, x, &min(&1, x))
          }
        end)

      Map.put(acc, prop, %{
        entry
        | shapes: MapSet.put(entry.shapes, shape),
          values: MapSet.put(entry.values, normal)
      })
    end)

  @table table

  @exact ~w(opacity)
  @seen_cap ~w(line-height opacity)

  @doc "The table read off the renderer: each property's shapes and number ranges."
  def table, do: @table

  @doc "Whether `value` is a value the renderer writes for `prop` (see the moduledoc)."
  def allowed?(prop, value) do
    case @table do
      %{^prop => entry} ->
        {shape, numbers, normal} = __MODULE__.Shape.read(value)

        MapSet.member?(entry.shapes, shape) and
          (prop not in @exact or MapSet.member?(entry.values, normal)) and
          Enum.all?(numbers, &in_range?(prop, entry, &1))

      _ ->
        false
    end
  end

  defp in_range?(_prop, %{low: low}, {unit, x}) when x < 0,
    do: Map.get(low, unit, 0) < 0 and x >= Map.fetch!(low, unit)

  defp in_range?(_prop, _entry, {"%", x}), do: x <= 100

  defp in_range?(prop, %{max: max}, {"", x}),
    do: x <= if(prop in @seen_cap, do: Map.get(max, "", 0), else: max(Map.get(max, "", 0), 12))

  defp in_range?(_prop, %{max: max}, {unit, x}), do: x <= Map.get(max, unit, 0)
end
