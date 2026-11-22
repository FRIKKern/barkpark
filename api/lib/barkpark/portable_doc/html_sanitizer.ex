defmodule Barkpark.PortableDoc.HtmlSanitizer do
  @moduledoc """
  Strict HTML scrubber for the ONE untrusted sink in the Papers pipeline:
  legacy `body_html` supplied verbatim by an external producer.

  ## Why this exists (named failure mode)

  A paper written with an HTML-only `body_html` (no `blocks` list) had its
  markup persisted VERBATIM (`Content.Papers.BlockOps.write_encrypted_paper/6`
  and the raw `Content.Writer` mutate path) and emitted through `raw/1` to the
  anonymous public reader (`BulldocsLive` `/papers/:slug`, the scoped
  `/w/:ws/p/:project/papers/:slug` reader, and the `/s/:token` share reader).
  With no Content-Security-Policy on those browser pipelines, a `<script>` tag
  or an `onerror=` handler in `body_html` executed in every reader's browser
  (session/token theft, defacement). Both the `:ingest` shared-secret API and —
  as this audit confirmed — any ordinary write-token via `/v1/data/mutate`
  could plant it.

  ## Trust model

  `body_html` is a DERIVED cache of the paper's `blocks`. When blocks are
  present it is re-rendered server-side by `PortableDoc.Render` (trusted,
  auto-escaping) and never needs scrubbing. This module hardens only the
  LEGACY leg where an opaque `body_html` is the sole source: it is scrubbed at
  STORE time so poisoned markup never reaches the database, complementing the
  reader's Content-Security-Policy backstop.

  ## Strategy: parse it as a browser does, keep what is allowed

  The markup is parsed with `LazyHTML` (lexbor, an HTML5 parser), so the
  scrub sees the elements and attributes a browser builds: a handler after a
  `/` or a closing quote (`<img/onerror=…>`, `<img src="x"onerror=…>`), a
  comment closed by `--!>`, an attribute value holding `>` are read as a
  browser reads them (task-65430475d0552e36; the regex scrub before it read
  them as text).

    * script-bearing / sandbox-escaping ELEMENTS are removed with their
      content (`script`, `style`, `iframe`, `object`, `embed`, `applet`,
      `noscript`, `template`, `svg`, `math`, `form`, `frame`, `frameset`,
      `link`, `meta`, `base`, `title`, and the raw-text `xmp`, `noembed`,
      `noframes`, whose content a parser and a browser can read differently);
    * comments are removed (IE conditional-comment script vector);
    * only allowed ATTRIBUTES are kept: `@attributes`, and any `data-…` or
      `aria-…`. So no `on…` handler, `srcdoc`, `formaction` or a name with a
      character reference in it survives;
    * a script address in a URL attribute (`javascript:`, `vbscript:`,
      `blob:`, a `data:` that is not `data:image/…`) becomes `#`. The parser
      has decoded the value's character references, as a browser does.

  ## Clean markup keeps its bytes

  When the parse finds nothing to remove, the input is returned unchanged:
  the parser's tree is what a browser builds from those same bytes, so they
  are safe as they are. Only markup that loses something is written back
  from the tree, so a stored paper's clean `body_html` (and every render the
  reader serves) is byte-identical to before.

  This is the first layer; the reader's `script-src 'self' 'nonce-…'` CSP is
  the backstop. Defense in depth — neither layer is trusted alone.
  """

  # Elements removed WITH their inner content.
  @dangerous_elements ~w(
    script style iframe object embed applet noscript template
    svg math form frame frameset link meta base title
    xmp noembed noframes
  )

  # The attributes producer HTML carries (Markdown/pdrender and the Paper
  # renderer's own output), plus any `data-…` and `aria-…`.
  @attributes ~w(
    href src alt title class id style role name lang dir translate hidden
    width height align valign colspan rowspan scope headers span start
    reversed type value target rel download hreflang cellspacing cellpadding
    border summary abbr cite datetime srcset sizes loading decoding srclang
    kind label open tabindex charset media poster controls muted loop
    autoplay playsinline preload frameborder nowrap bgcolor color face size
    for checked disabled readonly placeholder rows cols maxlength minlength
    min max step required multiple selected
  )

  # The URL-bearing attributes among them.
  @url_attrs ~w(href src poster cite)

  @doc """
  Scrub untrusted HTML. Non-binary input is returned unchanged (a nil/absent
  `body_html` is a no-op).
  """
  @spec sanitize(term()) :: term()
  def sanitize(html) when is_binary(html) do
    tree = html |> LazyHTML.from_fragment() |> LazyHTML.to_tree()

    case scrub(tree) do
      ^tree -> html
      clean -> clean |> LazyHTML.from_tree() |> LazyHTML.to_html()
    end
  end

  def sanitize(other), do: other

  defp scrub(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &scrub_node/1)

  defp scrub_node({:comment, _text}), do: []

  defp scrub_node({tag, attrs, children}) when is_binary(tag) do
    cond do
      String.downcase(tag) in @dangerous_elements -> []
      # A name no element has, such as `scr<script` from `<scr<script>ipt>`:
      # its content stays, the tag goes.
      not Regex.match?(~r/^[a-z][a-z0-9-]*$/i, tag) -> scrub(children)
      true -> [{tag, Enum.flat_map(attrs, &scrub_attr/1), scrub(children)}]
    end
  end

  defp scrub_node(text), do: [text]

  defp scrub_attr({name, value}) do
    key = String.downcase(name)

    cond do
      not allowed_attr?(key) -> []
      key in @url_attrs and dangerous_url?(value) -> [{name, "#"}]
      true -> [{name, value}]
    end
  end

  defp allowed_attr?(key),
    do:
      key in @attributes or
        Regex.match?(~r/^(data|aria)-[a-z0-9_.:-]+$/, key)

  defp dangerous_url?(value) do
    # A browser removes ASCII whitespace/control (incl. tab/newline/CR) while
    # parsing the URL scheme; strip them so `jav\tascript:` reads as
    # `javascript:`. The parser has already decoded character references.
    normalized = String.replace(value, ~r/[\x00-\x20]/, "")

    case Regex.run(~r/^([a-z][a-z0-9\-.+]*):(.*)$/is, normalized) do
      [_, scheme, rest] -> dangerous_scheme?(scheme, rest)
      _ -> false
    end
  end

  # `data:image/…` is the one preserved `data:` form (inline images from real
  # producers); every other data:/blob:/javascript:/vbscript: is neutralised.
  defp dangerous_scheme?(scheme, rest) do
    case String.downcase(scheme) do
      "data" -> not String.starts_with?(String.downcase(rest), "image/")
      s -> s in ~w(javascript vbscript blob)
    end
  end
end
