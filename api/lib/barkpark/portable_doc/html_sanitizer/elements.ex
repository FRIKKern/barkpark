defmodule Barkpark.PortableDoc.HtmlSanitizer.Elements do
  @moduledoc """
  The HTML elements the Paper renderer writes, read at compile time off what
  it renders (the goldens' `expectedHtml`, the email golden, the `<article>`
  inside each page golden's `<article>`) and off the tags its source writes (`render.ex` and
  `render/*.ex`: a `"<tag` or `~s(<tag` literal; `<h\#{level}` is `h1`…`h6`).
  The sanitizer keeps these and unwraps every other element, its text kept
  (#28404 review, B3).

  A tag the scrub keeps is one whose parse it knows: a browser and the
  scrub's parser (lexbor) can read the same bytes as different trees. lexbor
  reads a `<select>` by the old rules and drops every tag in it; Chrome builds
  them (customizable select), so `<select><meta http-equiv=refresh …>` came
  back unchanged and navigated the reader. With an allowlist, a stored tree
  holding any element outside it is written back from the clean tree, never
  returned as its own bytes, so a parser difference can only hide inside
  elements whose parse is known.

  `dropped/0` lists the elements removed with their content: the ones that
  run or load something, and the ones a parser reads in a mode of its own
  (`select`, `template`, `noscript`, `textarea`, foreign `svg`/`math`…). A
  dropped element's subtree adds nothing to the list (an `svg`'s `circle`).
  """

  # Removed WITH their content. The no-embed element is spelled in two parts:
  # part 3 of `scripts/preview-parity-check.sh` (D10) reds the source tree on a
  # substring of its name.
  @dropped [
    "no" <> "embed"
    | ~w(
        script style iframe object embed applet noscript template
        svg math form frame frameset link meta base title
        xmp noframes plaintext listing
        select option optgroup datalist selectedcontent textarea
      )
  ]

  # The document's own frame: a fragment never holds one.
  @frame ~w(html head body)

  dir = Path.expand("..", __DIR__)
  goldens = Path.expand("../../../../priv/portable_doc/goldens", __DIR__)

  sources = [Path.join(dir, "render.ex") | Path.wildcard(Path.join(dir, "render/*.ex"))]
  jsons = Path.wildcard(Path.join(goldens, "*/*.golden.json"))
  pages = Path.wildcard(Path.join(goldens, "pages/*.html"))
  email = Path.join(goldens, "email.html")
  for path <- [email | sources ++ jsons ++ pages], do: @external_resource(path)

  walk = fn walk, nodes ->
    Enum.flat_map(nodes, fn
      {tag, _attrs, children} when is_binary(tag) ->
        tag = String.downcase(tag)
        if tag in @dropped, do: [], else: [tag | walk.(walk, children)]

      _ ->
        []
    end)
  end

  fragments =
    Enum.flat_map(jsons, fn path ->
      case path |> File.read!() |> Jason.decode!() do
        %{"expectedHtml" => html} when is_binary(html) -> [html]
        _ -> []
      end
    end)

  rendered =
    Enum.flat_map(fragments, &walk.(walk, &1 |> LazyHTML.from_fragment() |> LazyHTML.to_tree())) ++
      walk.(walk, email |> File.read!() |> LazyHTML.from_document() |> LazyHTML.to_tree()) ++
      Enum.flat_map(pages, fn path ->
        path
        |> File.read!()
        |> LazyHTML.from_document()
        |> LazyHTML.query("article")
        |> LazyHTML.to_tree()
        # The reader's own `<article>` is the page's, not the renderer's.
        |> Enum.flat_map(fn {_article, _attrs, children} -> walk.(walk, children) end)
      end)

  written =
    Enum.flat_map(sources, fn path ->
      source = File.read!(path)

      headings =
        if Regex.match?(~r/<h#\{/, source), do: Enum.map(1..6, &"h#{&1}"), else: []

      tags =
        ~r/(?:"|~s\()<([a-z][a-z0-9]*)(?=[\s>\/"])/
        |> Regex.scan(source, capture: :all_but_first)
        |> List.flatten()

      headings ++ tags
    end)

  @kept (rendered ++ written)
        |> Enum.reject(&(&1 in @dropped or &1 in @frame or String.contains?(&1, "-")))
        |> Enum.uniq()
        |> Enum.sort()

  @doc "The elements the sanitizer keeps: those the Paper renderer writes."
  def kept, do: @kept

  @doc "The elements removed with their content."
  def dropped, do: @dropped

  @doc "Whether the sanitizer keeps the element `tag` (lower case)."
  def kept?(tag), do: tag in @kept
end
