defmodule Barkpark.PortableDoc.HtmlSanitizer.Anchors do
  @moduledoc """
  The ids, names and id references a scrubbed legacy body may carry in the
  reader (task-52d612bdb8ff6cb3, task-9c0ae5a9351d89cf).

  A legacy body is drawn inside pages that find their own elements by id:
  the reader's `#paper-body`, the Studio's `#editor-form` and `#desk-panes`,
  LiveView roots, the editor canvas's footnotes (`fn-<note id>`). An id, or
  an `img`'s `name`, also becomes a property of `window` or `document`, and
  `for`, `headers` and `aria-*` references bind to whatever element holds
  the id they name. So a stored `<div id="paper-body">` could take the
  page's place, and a stored `<label for="editor-form">` could point at it.

  The rule is a predicate, not a list of page ids:

    * every stored id moves into the body's own namespace: `id="intro"`
      becomes `id="bp-anchor-intro"`, `id="fn-fn1"` becomes
      `id="bp-anchor-fn-fn1"`. An id already in it is kept. No page or editor
      element's id starts with `bp-anchor-` (a test scans the templates, the
      static scripts and the editor's source), so a stored id can never be
      one. The renderer's footnote ids (`fn-<note id>`, free text) move too:
      the editor canvas writes the same shape (`island-node.js`), and nothing
      looks a note up by its id;
    * an id reference moves the same way, token by token: `for`, `headers`,
      `aria-labelledby`, `aria-describedby`, `aria-controls`, `aria-owns`,
      `aria-activedescendant`, `aria-details`, `aria-errormessage`,
      `aria-flowto`. A body's own references still find their ids, and none
      can name a page element;
    * a same-page link to a moved id moves with it. Same-page is `#frag`,
      `?query#frag`, and the Paper's own path (`/papers/<id>`, the shape a
      blockref writes) with an optional query, after the ASCII whitespace a
      browser strips from either end. The fragment matches as written or
      percent-decoded, case-exact, as a browser finds it. An old Paper's own
      links keep working; an outside deep link lands through
      `bp-paper-anchor.js`;
    * `name` is the old anchor on an `a`, and is moved like an id. On
      `input` and `button` it is the renderer's questionnaire field
      (`Render.Forms`), which is not a `window` or `document` property, and
      is kept. Anywhere else it is dropped.

  A second pass changes nothing: every id and reference is then in the
  namespace, and no link points at an id that still moves.
  """

  @prefix "bp-anchor-"

  # The attributes whose value is one id, or a space-separated list of ids.
  @ref_attrs ~w(for headers aria-labelledby aria-describedby aria-controls aria-owns
                aria-activedescendant aria-details aria-errormessage aria-flowto)

  @ascii_space ~c"\t\n\f\r "

  @doc "The namespace a stored id is moved into."
  def prefix, do: @prefix

  @doc "The attributes that name ids."
  def ref_attrs, do: @ref_attrs

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

  @doc "An id reference (`for`, `headers`, `aria-*`): each id moved as `id/2` moves it."
  def refs(name, value) do
    case value |> String.split(Enum.map(@ascii_space, &<<&1>>), trim: true) do
      [] -> []
      ids -> [{name, Enum.map_join(ids, " ", &place/1)}]
    end
  end

  @doc """
  A same-page `href` follows an id the body holds and moves. `self` is the
  Paper's own path (`/papers/<id>`), or nil.
  """
  def href(value, anchors, self \\ nil) do
    trimmed = String.replace(value, ~r/\A[\t\n\f\r ]+|[\t\n\f\r ]+\z/, "")

    with [page, fragment] <- String.split(trimmed, "#", parts: 2),
         true <- same_page?(page, self),
         true <- moved?(fragment, anchors) do
      page <> "#" <> @prefix <> fragment
    else
      _ -> value
    end
  end

  @doc "The Paper's own path for a sanitizer id (`drafts.` dropped), or nil."
  def self_path(id) when is_binary(id) and id != "",
    do: "/papers/" <> String.replace_prefix(id, "drafts.", "")

  def self_path(_id), do: nil

  defp same_page?("", _self), do: true
  defp same_page?("?" <> _query, _self), do: true
  defp same_page?(_page, nil), do: false

  # A browser drops a tab or newline anywhere in a URL and reads `/\` as
  # `//`: what then starts `//` names another host.
  defp same_page?("/" <> _ = page, self) do
    path = page |> String.replace(~r/[\t\n\r]/, "") |> String.split("?", parts: 2) |> hd()
    not other_host?(path) and (path == self or String.ends_with?(path, self))
  end

  defp same_page?(_page, _self), do: false

  defp other_host?(<<?/, c, _::binary>>) when c in [?/, ?\\], do: true
  defp other_host?(_path), do: false

  defp moved?("", _anchors), do: false

  defp moved?(fragment, anchors) do
    MapSet.member?(anchors, fragment) or
      case decode(fragment) do
        ^fragment -> false
        decoded -> MapSet.member?(anchors, decoded)
      end
  end

  defp decode(fragment) do
    URI.decode(fragment)
  rescue
    ArgumentError -> fragment
  end

  defp place(value), do: if(moves?(value), do: @prefix <> value, else: value)

  defp moves?(value), do: value != "" and not String.starts_with?(value, @prefix)

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
