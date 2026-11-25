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

    * only the ELEMENTS the Paper renderer writes are kept (`Elements`,
      read off its goldens and source); any other element is unwrapped, its
      text kept, a custom element (`bp-rich-text-editor` draws its `value`
      into the page) included;
    * script-bearing / sandbox-escaping elements, and those a parser reads
      in a mode of its own, are removed with their content (`script`,
      `style`, `iframe`, `object`, `embed`, `noscript`, `template`, `svg`,
      `math`, `form`, `link`, `meta`, `base`, `title`, the raw-text
      `xmp`, `noframes`, `plaintext`, `listing` and the no-embed element,
      and `select`, `option`, `optgroup`, `datalist`, `selectedcontent`
      and `textarea`: lexbor drops the tags inside a `select`, which a
      current browser builds; #28404 review, B3);
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

  ## The output is always the clean tree, serialised

  The input's own bytes never come back, clean or not (#28404 review, B4).
  Every hole the old "nothing removed, return the input" shortcut let through
  was markup the fragment parse read one way and the page another: a tag left
  open at the end, a formatting element left open across a close, a
  `<select>`, a stray `</article>` the fragment ignored but the page obeyed.
  A serialised tree closes what it opens and holds no end tag it did not open,
  so none of these reaches the page as written.

  The tree is written by `HtmlSanitizer.Serializer`, not `LazyHTML.to_html/1`,
  which wrote `<s><br></br></s>` and so doubled line breaks on every save
  (#28404 review, B6).

  One pass is not always a tree the parser builds (#28404 review, B5).
  Unwrapping an element moves its children where the parser never puts them
  (`<li>a<div><aside><li>b` becomes `<li>a<div><li>b`), and the page's parse
  of that closes the page's own `div`. So `sanitize/2` repeats the pass until
  its output parses and serialises back to itself, for at most 3 passes. That
  is a fixed point: `sanitize(sanitize(x)) == sanitize(x)`, byte for byte. A
  body that does not settle is served as its text alone, in one `<p>`. Clean
  markup comes back as the same tree (same elements, attributes and text).

  lexbor and a current browser still build different trees for a few
  misnested kept elements (a `button` in a `button`). A fixed point is
  lexbor's tree written so that lexbor reads it back unchanged. Those shapes
  come out already rearranged (two sibling buttons), and a browser reads
  them the same way.

  This is the first layer; the reader's `script-src 'self' 'nonce-…'` CSP is
  the backstop. Defense in depth — neither layer is trusted alone.
  """

  require Logger

  alias Barkpark.PortableDoc.HtmlSanitizer.{Anchors, Cache, Elements, Serializer, StyleGrammar}

  # Passes `sanitize/2` makes before it fails closed (#28404 review, B5).
  @max_passes 3

  # Elements removed with their content, and the elements kept: those the
  # Paper renderer writes (`Elements`). Every other element is unwrapped, its
  # text kept, so a tree holding one is always written back (#28404 review,
  # B3). A custom element (a tag name with a hyphen) is never kept: a Studio
  # component such as `bp-rich-text-editor` draws its `value`/`data-value`
  # into the page. A test derives the renderer's names from its goldens and
  # reds when one is missing.
  @dangerous_elements Elements.dropped()
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

  The result is a fixed point: `sanitize(sanitize(x)) == sanitize(x)`. Each
  pass parses, scrubs and serialises. Up to #{@max_passes} passes are made
  until a pass returns its own input. A body that never settles is served as
  its text alone, escaped inside one `<p>`, and a warning names `opts[:id]`
  (never the content). `opts[:max_passes]` can only lower the cap (tests use
  it to reach the fail-closed path).

  `editor: true` scrubs the copy a Studio rich text editor draws inside its
  form (`Content.LegacyRichHtml`): no form control, no `style`, `id` or
  `name`, and an `href` that `opts[:href_allowed?]` refuses is kept as
  `data-refused-href`. The reader's policy drops `data-refused-href`.
  """
  @spec sanitize(term(), keyword()) :: term()
  def sanitize(html, opts \\ [])

  def sanitize(html, opts) when is_binary(html) do
    # Always the clean tree, serialised: never the input's own bytes. A
    # serialised tree closes what it opens and holds no end tag it did not
    # open, so nothing stored can close the reader's box or reach past it
    # (#28404 review, B4: a stray `</article>` the fragment parse ignored).
    #
    # One pass is not enough (#28404 review, B5). Unwrapping an element
    # (`aside`, `center`, `marquee`…) moves its children where the parser
    # never puts them: `<li>a<div><aside><li>b` becomes `<li>a<div><li>b`,
    # and the browser's parse of that closes the page's own `div`. A pass
    # whose output parses back to itself has no such tree left.
    #
    # The same body comes out every time, so a reader's scrub is kept
    # (`Cache`, task-13c9d34562701725).
    Cache.fetch(html, opts, fn ->
      passes =
        opts
        |> Keyword.get(:max_passes, @max_passes)
        |> min(@max_passes)
        |> min(configured_max_passes())
        |> max(1)

      settle(html, passes, Keyword.put(opts, :policy, policy(opts)))
    end)
  end

  def sanitize(other, _opts), do: other

  # Like `opts[:max_passes]`, the app env can only lower the cap. Nothing
  # stored is known to need more than three passes, so a test reaches the
  # fail-closed branch through a write path (`Content.Writer`) by lowering it.
  @doc false
  # The pass cap the app env sets; part of `Cache.version/0`.
  def configured_max_passes,
    do: Application.get_env(:barkpark, __MODULE__, []) |> Keyword.get(:max_passes, @max_passes)

  defp settle(html, passes, opts) do
    {out, tree} = pass(html, opts[:policy])

    cond do
      out == html -> out
      passes > 1 -> settle(out, passes - 1, opts)
      true -> fail_closed(tree, opts)
    end
  end

  defp pass(html, policy) do
    parsed = html |> LazyHTML.from_fragment() |> LazyHTML.to_tree()
    # The ids an in-page link may follow into the body's namespace (`Anchors`).
    tree = scrub(parsed, Map.put(policy, :anchors, Anchors.collect(parsed)))
    {Serializer.to_html(tree), tree}
  end

  # Never the unstable HTML: its text, escaped, in one paragraph. That parses
  # back to itself, so it is a fixed point too.
  defp fail_closed(tree, opts) do
    Logger.warning(
      "HtmlSanitizer: a legacy body did not settle in its passes; " <>
        "serving its text only (id=#{inspect(opts[:id])})"
    )

    text = Serializer.text(tree)

    if text == "",
      do: "",
      else: IO.iodata_to_binary(["<p>", Serializer.escape_text(text), "</p>"])
  end

  @doc """
  The style of the box a reader draws a scrubbed legacy body in (the
  reader's HTML-only arm, the Studio's read-only arm, the `/s/` share
  reader): nothing inside it paints or takes a click outside it, a fixed
  box included (#28404 review, B2). What the scrub keeps cannot cover the
  page; this keeps a gap a future style lets through inside the article.

  A wide block in a renderer copy (a figure, a table, code) is pulled past
  the column by `--bp-evidence-pull`; here it keeps to the column instead
  of being cut off, and anything wider scrolls inside the box.
  """
  def contain,
    do: "contain: paint; overflow-x: auto; --bp-evidence-pull: 0px; --bp-evidence-width: 100%"

  @doc """
  The same box on the `/papers/:slug/email` page (#28404 review, S1). That
  page is the email's bytes, all styles inline, so it sets no custom
  property: a mail client that keeps `style` reads plain CSS, and one that
  does not know `contain` ignores it. A wide block scrolls inside the box.
  """
  def contain(:email), do: "contain: paint; overflow-x: auto"

  # The editor policy (`editor: true`): the copy a Studio rich text editor
  # draws inside `#editor-form` (#28402). No form control, so nothing stored
  # can add a value to the form's post (#28404 review, N2), and no `style`.
  # An `href` that `href_allowed?` refuses is kept as `data-refused-href`
  # with its address, so the link draws as its words and an edit keeps the
  # address, inert. Any other `on…` or element rule is the reader's.
  defp policy(opts) do
    base =
      if opts[:editor],
        do: %{editor: true, href_allowed?: opts[:href_allowed?] || fn _ -> true end},
        else: %{editor: false}

    # A link to the Paper's own path is a same-page link (`Anchors.href/3`).
    Map.put(base, :self, Anchors.self_path(opts[:id]))
  end

  @form_controls ~w(input button label fieldset legend)

  defp scrub(nodes, policy) when is_list(nodes),
    do: Enum.flat_map(nodes, &scrub_node(&1, policy))

  defp scrub_node({:comment, _text}, _policy), do: []

  defp scrub_node({tag, attrs, children}, policy) when is_binary(tag) do
    tag_key = String.downcase(tag)

    cond do
      tag_key in @dangerous_elements ->
        []

      # The editor's copy unwraps a form control; `input` holds no text.
      policy.editor and tag_key in @form_controls ->
        scrub(children, policy)

      # An element the renderer writes is kept, its attributes scrubbed.
      Elements.kept?(tag_key) ->
        attr_policy = Map.put(policy, :tag, tag_key)
        [{tag, Enum.flat_map(attrs, &scrub_attr(&1, attr_policy)), scrub(children, policy)}]

      # Any other element, a custom one or a name no element has (`scr<script`
      # from `<scr<script>ipt>`) included: its content stays, the tag goes.
      true ->
        scrub(children, policy)
    end
  end

  defp scrub_node(text, _policy), do: [text]

  defp scrub_attr({name, value}, %{editor: true} = policy) do
    case String.downcase(name) do
      "style" -> []
      # The copy sits in the light DOM inside `#editor-form`: a stored `name`
      # or `id` would shadow the form's or the document's own properties
      # (`form.getAttribute`, `document.querySelector`) or a later field's
      # hidden input (#28402 review r2, S1). The reader keeps them for now.
      key when key in ["id", "name"] -> []
      "data-refused-href" -> [{"data-refused-href", value}]
      "href" -> editor_href(value, policy)
      _ -> scrub_attr({name, value}, %{policy | editor: false})
    end
  end

  defp scrub_attr({name, value}, policy) do
    key = String.downcase(name)

    cond do
      not allowed_attr?(key) -> []
      key in @url_attrs and dangerous_url?(value) -> [{name, "#"}]
      # A stored id never takes a page element's place (`Anchors`).
      key == "id" -> Anchors.id(name, value)
      key == "name" -> Anchors.name(name, value, policy.tag)
      key in Anchors.ref_attrs() -> Anchors.refs(name, value)
      key == "href" -> [{name, Anchors.href(value, policy.anchors, policy.self)}]
      key == "style" -> scrub_style(name, value)
      key == "class" -> scrub_class(name, value)
      true -> [{name, value}]
    end
  end

  defp editor_href(value, policy) do
    if dangerous_url?(value) or not policy.href_allowed?.(value),
      do: [{"data-refused-href", value}],
      else: [{"href", value}]
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
