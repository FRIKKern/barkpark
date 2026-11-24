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

  The string is scrubbed by `PortableDoc.HtmlSanitizer` with its editor
  policy, on the parsed tree, to a fixed point (#28402 review):

    * the reader's rules: only the elements and attributes the Paper
      renderer writes, no `on…` handler, no script address;
    * no form control (`input`, `button`, `label`, `fieldset`, `legend`;
      `select`, `textarea` and `form` are always dropped). The copy is drawn
      inside `#editor-form`, so a stored `<input name="doc[title]">` would
      post a value for another field;
    * no `style`, so a stored link cannot cover the Studio;
    * no `id` or `name`: inside the form a stored `<img name="getAttribute">`
      or `<span id="bp-rt-hidden-…">` would shadow the form's, the
      document's or a later field's own names;
    * `strike`, which the editor's strikethrough writes, is kept;
    * every `href` is judged by `LinkHref.allowed?/1`. A refused one is
      kept as `data-refused-href`, with its address: the anchor draws as its
      words, and an edit of the field posts the address back inert, never
      as a link.
  """

  alias Barkpark.Content.LinkHref
  alias Barkpark.PortableDoc.HtmlSanitizer

  @doc "The HTML the editor draws for a stored string. Any other value is returned as it is."
  @spec for_editor(term()) :: term()
  def for_editor(html) when is_binary(html),
    do: HtmlSanitizer.sanitize(html, editor: true, href_allowed?: &drawable?/1)

  def for_editor(other), do: other

  # An empty address is drawn as before, as the Portable Text path draws it.
  defp drawable?(href), do: href == "" or LinkHref.allowed?(href)
end
