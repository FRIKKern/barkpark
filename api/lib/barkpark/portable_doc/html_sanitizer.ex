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
      `link`, `meta`, `base`, `title`, and the raw-text `xmp`, `noframes`
      and the no-embed element, whose content a parser and a browser can
      read differently, and `plaintext` and `listing`);
    * a custom element (a tag name with a hyphen) the renderer does not emit
      is unwrapped, its text kept: a Studio component draws its `value` into
      the page;
    * comments are removed (IE conditional-comment script vector);
    * only allowed ATTRIBUTES are kept: `@attributes`, the `data-…` names
      the renderer writes, and any `aria-…`. So no `on…` handler, `srcdoc`,
      `formaction` or a name with a character reference in it survives;
    * `class` keeps only the names the renderer emits, less those the reader
      CSS takes out of the flow; `style` keeps only the properties the
      renderer writes, `position`/`top`/`left` by value, and no value that
      loads, escapes or is sized to the viewport. Nothing stored can cover
      the page (#28404 review, F4);
    * a script address in a URL attribute (`javascript:`, `vbscript:`,
      `blob:`, a `data:` that is not `data:image/…`) becomes `#`. The parser
      has decoded the value's character references, as a browser does.

  ## Clean markup keeps its bytes

  When the parse finds nothing to remove AND the tree reads back as the input
  byte for byte, the input is returned unchanged: the parser's tree is what a
  browser builds from those same bytes, so they are safe as they are. Markup
  that loses something, or does not read back (a tag left open at the end,
  which the reader's own `</article>` would close; #28404 review, F1), is
  written back from the clean tree. A stored paper's clean `body_html` is
  byte-identical to before.

  This is the first layer; the reader's `script-src 'self' 'nonce-…'` CSP is
  the backstop. Defense in depth — neither layer is trusted alone.
  """

  alias Barkpark.PortableDoc.HtmlSanitizer.StyleGrammar

  # Elements removed WITH their inner content. The no-embed element is
  # spelled in two parts: part 3 of `scripts/preview-parity-check.sh` (D10)
  # reds the source tree on a substring of its name.
  @dangerous_elements [
    "no" <> "embed"
    | ~w(
        script style iframe object embed applet noscript template
        svg math form frame frameset link meta base title
        xmp noframes plaintext listing
      )
  ]

  # Custom elements (a tag name with a hyphen) the Paper renderer emits: none
  # today. Any other custom element is unwrapped, its text kept: a Studio
  # component such as `bp-rich-text-editor` draws its `value`/`data-value`
  # into the page, so a stored one would draw unsanitised HTML. A test
  # derives the renderer's names from its goldens and reds when one is
  # missing here.
  @custom_elements []

  # The CSS properties the producer and the Paper renderer write in `style`
  # (read off the renderer goldens' `expectedHtml`, the email golden and
  # `render/*.ex`). A declaration of any other property is dropped, and so is
  # one whose value could load, escape or size to the viewport (`url(`,
  # `expression(`, `image-set(`, a `\` escape, `@`, `<`, `>`, a brace,
  # `vw`/`vh`). Never: `z-index`, `inset`, `right`, `bottom`, `transform`.
  # `position`, `top` and `left` are judged by value (`placed?/2`).
  @style_properties ~w(
    align-items background background-color border border-bottom
    border-collapse border-left border-radius border-top border-top-width
    box-sizing color cursor display flex flex-direction font-family font-size
    font-style font-weight gap grid-column grid-template-columns height
    letter-spacing line-height list-style margin margin-bottom margin-inline
    margin-left margin-top max-width min-width opacity overflow overflow-wrap
    overflow-x padding padding-bottom padding-left padding-top text-align
    text-decoration text-transform vertical-align white-space width
  )
  @placed_properties ~w(position top left)

  # The custom properties the renderer sets, each with a value check: a
  # number, a length or a short token list (`repeat(3, 1fr)`), never
  # `url(`, `\\`, `@`, `;`, `}` or `expression(` (`allowed_decl?/1`).
  @custom_properties ~w(--bp-cols --bp-grid-gap --bp-tracks --i)

  # `class`: only the names the Paper renderer emits for body content. Read
  # at compile time off the renderer's source: every literal class token in a
  # `class="…"` and its block's `__element` and `--modifier` names, and for a
  # token built by interpolation (`bp-role-#{role}`) any name that starts
  # with its literal part.
  @render_sources [
    Path.join(__DIR__, "render.ex") | Path.wildcard(Path.join(__DIR__, "render/*.ex"))
  ]
  for path <- @render_sources, do: @external_resource(path)

  # And off what it renders: the goldens' `expectedHtml`, which hold names
  # the source builds without a `class="…"` literal (`"bp-role-" <> role`).
  @goldens Path.wildcard(
             Path.expand("../../../priv/portable_doc/goldens/*/*.golden.json", __DIR__)
           )
  for path <- @goldens, do: @external_resource(path)

  @rendered @goldens
            |> Enum.map(&(&1 |> File.read!() |> Jason.decode!() |> Map.get("expectedHtml")))
            |> Enum.filter(&is_binary/1)

  {exact, prefixes} =
    (Enum.map(@render_sources, &File.read!/1) ++ @rendered)
    |> Enum.flat_map(&Regex.scan(~r/class=\\?"([^"\\]*)/, &1, capture: :all_but_first))
    |> Enum.flat_map(fn [value] -> String.split(value) end)
    |> Enum.reduce({MapSet.new(), MapSet.new()}, fn token, {exact, prefixes} ->
      [base | _] = String.split(token, "\#{")
      block = base |> String.split(["__", "--"]) |> hd()

      cond do
        # Built by interpolation: what follows its literal start.
        String.contains?(token, "\#{") and Regex.match?(~r/^bp-[a-z0-9_-]+$/, base) ->
          {exact,
           prefixes |> MapSet.put(base) |> MapSet.put(block <> "__") |> MapSet.put(block <> "--")}

        String.contains?(token, "\#{") ->
          {exact, prefixes}

        # A BEM name: its block's elements and modifiers too.
        Regex.match?(~r/^bp-[a-z0-9_-]+$/, token) ->
          {MapSet.put(exact, token),
           prefixes |> MapSet.put(block <> "__") |> MapSet.put(block <> "--")}

        Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_-]*$/, token) ->
          {MapSet.put(exact, token), prefixes}

        true ->
          {exact, prefixes}
      end
    end)

  @render_classes exact
  @render_prefixes prefixes |> MapSet.to_list() |> Enum.sort()

  # `data-…`: only the names the renderer writes. CSS and the reader's
  # scripts select on data attributes too (the editor shell's
  # `[data-paper-link-open] { position: absolute; inset: 0 }`), so a stored
  # one is a hook, not inert data.
  @render_data_attrs (Enum.map(@render_sources, &File.read!/1) ++ @rendered)
                     |> Enum.flat_map(
                       &Regex.scan(~r/\b(data-[a-z0-9_-]*[a-z0-9])\b/, &1,
                         capture: :all_but_first
                       )
                     )
                     |> List.flatten()
                     |> MapSet.new()

  # Renderer classes the reader CSS takes out of the flow (`position:
  # absolute`, `fixed` or `sticky` on the element, or on an `input` under it)
  # while `style` can size the box: on stored markup each is an overlay
  # (#28404 review, F4). A test reads the reader CSS and reds when a
  # positioned rule's subject is reachable with the classes kept here.
  @denied_classes ~w(
    bp-rm__bar bp-rm__ms bp-rm__note bp-rm__today bp-rm__unplaced
    bp-toc--sticky bp-form-q--scale bp-form-q--yesno
  )

  # The attributes producer HTML carries (Markdown/pdrender and the Paper
  # renderer's own output), plus the renderer's `data-…` and any `aria-…`.
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
    clean = scrub(tree)

    # The input itself only when nothing was removed AND it ends closed. A tag
    # left open at the end (`<img src=x onerror=… `) parses to nothing here,
    # but in the page the markup after it (the reader's own `</article>`)
    # completes it (#28404 review, F1). So the input is read again with a
    # paragraph after it: markup that ends closed reads as its own tree and
    # that paragraph; an open tag, attribute, comment or raw-text element
    # takes the paragraph in. Else the clean tree is written back.
    if clean == tree and ends_closed?(html, tree),
      do: html,
      else: clean |> LazyHTML.from_tree() |> LazyHTML.to_html()
  end

  def sanitize(other), do: other

  @doc """
  The style of the box a reader draws a scrubbed legacy body in (the
  reader's HTML-only arm, the Studio's read-only arm, the `/s/` share
  reader): nothing inside it paints or takes a click outside it, a fixed
  box included (#28404 review, B2). What the scrub keeps cannot cover the
  page; this keeps a gap a future style lets through inside the article.
  """
  def contain, do: "contain: paint; overflow-x: auto"

  # The paragraph carries text: an `<a>`, `<b>`, `<font>`… left open across
  # a closing `</p>`, `</li>` or `</td>` stays on the parser's list of active
  # formatting elements and is built again around the next text, so in the
  # page it would wrap everything after the body (#28404 review, B1). An
  # empty paragraph never rebuilds it; one with text does, and then differs.
  defp ends_closed?(html, tree) do
    (html <> "<p>x</p>") |> LazyHTML.from_fragment() |> LazyHTML.to_tree() ==
      tree ++ [{"p", [], ["x"]}]
  end

  defp scrub(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &scrub_node/1)

  defp scrub_node({:comment, _text}), do: []

  defp scrub_node({tag, attrs, children}) when is_binary(tag) do
    cond do
      String.downcase(tag) in @dangerous_elements ->
        []

      # A name no element has, such as `scr<script` from `<scr<script>ipt>`:
      # its content stays, the tag goes.
      not Regex.match?(~r/^[a-z][a-z0-9-]*$/i, tag) ->
        scrub(children)

      # A custom element the renderer does not emit: its text stays.
      String.contains?(tag, "-") and String.downcase(tag) not in @custom_elements ->
        scrub(children)

      true ->
        [{tag, Enum.flat_map(attrs, &scrub_attr/1), scrub(children)}]
    end
  end

  defp scrub_node(text), do: [text]

  defp scrub_attr({name, value}) do
    key = String.downcase(name)

    cond do
      not allowed_attr?(key) -> []
      key in @url_attrs and dangerous_url?(value) -> [{name, "#"}]
      key == "style" -> scrub_style(name, value)
      key == "class" -> scrub_class(name, value)
      true -> [{name, value}]
    end
  end

  @doc "The custom elements the sanitizer keeps: those the Paper renderer emits."
  def custom_elements, do: @custom_elements

  @doc "The renderer classes dropped because the reader CSS takes them out of the flow."
  def denied_classes, do: @denied_classes

  @doc "Whether `class` keeps the name `token` (`@render_classes`, `@denied_classes`)."
  @spec keep_class?(String.t()) :: boolean()
  def keep_class?(token) when is_binary(token) do
    token not in @denied_classes and
      (MapSet.member?(@render_classes, token) or
         Enum.any?(@render_prefixes, &String.starts_with?(token, &1)))
  end

  defp scrub_class(name, value) do
    tokens = String.split(value)
    kept = Enum.filter(tokens, &keep_class?/1)

    cond do
      kept == tokens -> [{name, value}]
      kept == [] -> []
      true -> [{name, Enum.join(kept, " ")}]
    end
  end

  # Keep the declarations `@style_properties` allows, as written; the value is
  # the input's own bytes when every declaration stays.
  defp scrub_style(name, value) do
    decls = String.split(value, ";")
    kept = Enum.filter(decls, &(String.trim(&1) == "" or allowed_decl?(&1)))

    cond do
      kept == decls -> [{name, value}]
      Enum.all?(kept, &(String.trim(&1) == "")) -> []
      true -> [{name, Enum.join(kept, ";")}]
    end
  end

  defp allowed_decl?(decl) do
    case String.split(decl, ":", parts: 2) do
      [prop, val] ->
        prop = prop |> String.trim() |> String.downcase()
        val = String.trim(val)

        not Regex.match?(
          ~r/url\(|expression\(|image-set\(|\\|@|<|>|\}|\{|\d(?:[sld]?v[wh]|vmin|vmax)\b/i,
          val
        ) and
          (prop in @style_properties or prop in @placed_properties or prop in @custom_properties) and
          StyleGrammar.allowed?(prop, val)

      _ ->
        false
    end
  end

  defp allowed_attr?(key),
    do:
      key in @attributes or
        MapSet.member?(@render_data_attrs, key) or
        Regex.match?(~r/^aria-[a-z0-9_.:-]+$/, key)

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
