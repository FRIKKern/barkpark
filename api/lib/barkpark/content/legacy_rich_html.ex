defmodule Barkpark.Content.LegacyRichHtml do
  @moduledoc """
  The HTML a Classic rich text editor draws for a stored HTML string, the
  legacy richText value that is not Portable Text (task-b11051e39ebe3a30).

  The editor puts its value in the page with `innerHTML`, so a string the API
  or an import wrote reached the Studio as it was stored: a `javascript:`
  anchor, or an `<img onerror>` that runs as the page is drawn. Portable Text
  is drawn through `Content.LinkHref` (task-e1584dc1f1516991); this draws the
  string the same way.

  It is for drawing only. The form posts the stored string, so the value keeps
  its bytes until someone edits the field.

    * Every `href` is judged by `LinkHref.allowed?/1`. A refused one is
      renamed `data-refused-href`, so the anchor draws as its words.
    * `PortableDoc.HtmlSanitizer` removes the elements that run script or
      change the page (`script`, `iframe`, `style`, `base`, …), comments,
      `on…=` handlers and script addresses in URL attributes.
    * An `on…` attribute it misses, after a `/` or a closing quote
      (`<img/onerror=…>`, `<img src="x"onerror=…>`), is renamed
      `data-refused-on…`.

  Both renames change only the letters of an attribute name, so they never
  move where a browser starts or ends a tag, a value or a text run. They look
  for the name after anything a browser reads as the start of an attribute
  (space, `/`, a quote), so they also match text such as ` one = 2`; that is
  changed in the drawn copy only.
  """

  alias Barkpark.Content.LinkHref
  alias Barkpark.PortableDoc.HtmlSanitizer

  @handler ~r/(?<=[\s\/"'])(on[a-z]+)(?=\s*=)/i
  @href ~r/(?<=[\s\/"'])href(\s*=\s*)("[^"]*"|'[^']*'|[^\s>]+)/i

  @doc "The HTML the editor draws for a stored string. Any other value is returned as it is."
  @spec for_editor(term()) :: term()
  def for_editor(html) when is_binary(html) do
    html
    # First, so a refused link draws as its words rather than as the
    # sanitiser's `href="#"`.
    |> refuse_hrefs()
    |> HtmlSanitizer.sanitize()
    |> then(
      &Regex.replace(@handler, &1, fn _, name -> "data-refused-" <> String.downcase(name) end)
    )
    # Again, for an address the sanitiser keeps (`data:image/…`) or one its
    # comment strip joined back together.
    |> refuse_hrefs()
  end

  def for_editor(other), do: other

  defp refuse_hrefs(html) do
    Regex.replace(@href, html, fn full, eq, value ->
      if drawable?(unquote_value(value)), do: full, else: "data-refused-href" <> eq <> value
    end)
  end

  # An empty address is drawn as before, as the Portable Text path draws it.
  defp drawable?(href), do: href == "" or LinkHref.allowed?(href)

  defp unquote_value(<<q, rest::binary>>) when q in [?", ?'] and byte_size(rest) > 0,
    do: binary_part(rest, 0, byte_size(rest) - 1)

  defp unquote_value(value), do: value
end
