defmodule Barkpark.PortableDoc.HtmlSanitizer.Anchors do
  @moduledoc """
  The ids and names a scrubbed legacy body may carry in the reader
  (task-52d612bdb8ff6cb3).

  A legacy body is drawn inside pages that find their own elements by id:
  the reader's `#paper-body`, the Studio's `#editor-form` and `#desk-panes`,
  LiveView roots. `getElementById` returns the first match, and an `id` or an
  `img`'s `name` also becomes a property of `window` or `document`. So a
  stored `<div id="paper-body">` or `<img name="querySelector">` could take
  the page's place.

  The rule is a predicate, not a list of page ids:

    * an id the renderer writes is kept as it is. That is `fn-<note id>`,
      a footnote's anchor (`Render.Compose`, `footnote_row_html/1`);
    * an id already in the body's own namespace (`bp-anchor-…`) is kept;
    * any other id is moved into that namespace: `id="intro"` becomes
      `id="bp-anchor-intro"`. No page element's id starts with `fn-` or
      `bp-anchor-` (a test checks the templates and scripts), so a stored id
      can never be a page's;
    * an in-page link to a moved id moves with it: `href="#intro"` becomes
      `href="#bp-anchor-intro"` when the body holds `id="intro"`. An old
      Paper's own `#anchor` links keep working;
    * `name` is the old anchor on an `a`, and is moved the same way. On
      `input` and `button` it is the renderer's questionnaire field
      (`Render.Forms`), which is not a `window` or `document` property, and
      is kept. Anywhere else it is dropped.

  A second pass changes nothing: every id is then `fn-…` or `bp-anchor-…`,
  and no link points at an id that still moves.
  """

  @prefix "bp-anchor-"
  @renderer_prefix "fn-"

  @doc "The namespace a stored id is moved into."
  def prefix, do: @prefix

  @doc "The prefix of the ids the renderer writes (footnotes)."
  def renderer_prefix, do: @renderer_prefix

  @doc "The ids and `a` names in a parsed tree that move into the namespace."
  @spec collect([term()]) :: MapSet.t()
  def collect(nodes), do: nodes |> walk([]) |> MapSet.new()

  @doc "The `id` attribute, kept, moved or dropped."
  def id(_name, ""), do: []
  def id(name, value), do: [{name, place(value)}]

  @doc "The `name` attribute on an element `tag`."
  def name(name, value, tag) when tag in ["input", "button"], do: [{name, value}]
  def name(name, value, "a"), do: id(name, value)
  def name(_name, _value, _tag), do: []

  @doc "An in-page `href`: it follows an id the body holds and moves."
  def href("#" <> fragment = value, anchors) do
    if MapSet.member?(anchors, fragment), do: "#" <> @prefix <> fragment, else: value
  end

  def href(value, _anchors), do: value

  defp place(value), do: if(moves?(value), do: @prefix <> value, else: value)

  defp moves?(value),
    do:
      value != "" and not String.starts_with?(value, @renderer_prefix) and
        not String.starts_with?(value, @prefix)

  defp walk(nodes, acc) when is_list(nodes), do: Enum.reduce(nodes, acc, &walk/2)

  defp walk({tag, attrs, children}, acc) when is_binary(tag) do
    a? = String.downcase(tag) == "a"

    acc =
      Enum.reduce(attrs, acc, fn {k, v}, acc ->
        key = String.downcase(k)
        if (key == "id" or (a? and key == "name")) and moves?(v), do: [v | acc], else: acc
      end)

    walk(children, acc)
  end

  defp walk(_node, acc), do: acc
end
