defmodule Barkpark.PortableDoc.HtmlSanitizerReviewTest do
  @moduledoc """
  The #28404 review's findings (task-65430475d0552e36). Each output is judged
  as the reader draws it: inside `<article id="paper-body">…</article>`, the
  page's markup after it included.

    * F1: a tag left open at the end parsed to nothing, so the input came
      back as it was, and in the page the reader's `</article>` closed it.
    * F2: `plaintext` (and `listing`) were kept.
    * F3: a custom element was kept; `bp-rich-text-editor` draws its
      `data-value` into the page.
    * F4: `style`, `class` and `data-…` could put a stored link over the
      page: `position: fixed`, or a renderer class the reader CSS takes out
      of the flow.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.HtmlSanitizer, as: S
  alias Barkpark.PortableDoc.HtmlSanitizer.StyleGrammar

  # The reader's page around the body.
  defp page(html),
    do: LazyHTML.from_fragment(~s|<article id="paper-body">| <> html <> "</article><p>after</p>")

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  defp tree(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.to_tree()

  # Clean markup comes back as the same tree, and a second pass as the same bytes.
  defp same_tree?(html) do
    out = S.sanitize(html)
    tree(out) == tree(html) and S.sanitize(out) == out
  end

  describe "F1: a tag left open at the end" do
    for {payload, selector} <- [
          {~s|<p>x</p><img src=x onerror=alert(1) |, "img"},
          {~s|<p>x</p><img src=x onerror="alert(1)" |, "img"},
          {~s|<p>x</p><meta http-equiv="refresh" content="0;url=https://evil.example" |, "meta"},
          {~s|<p>x</p><iframe src="https://evil.example" style="position:fixed;inset:0" |,
           "iframe"},
          {~s|<p>x</p><a href="https://evil.example" style="position:fixed;inset:0;z-index:9" |,
           "a[style*=fixed]"},
          {~s|<p>x</p><!-- |, "p:not(:first-child):not(:last-child)"}
        ] do
      @payload payload
      @selector selector
      test "#{inspect(payload)} builds no #{selector} in the page" do
        assert @payload |> S.sanitize() |> page() |> count(@selector) == 0
        assert @payload |> page() |> count(@selector) > 0 or @selector =~ "not("
      end
    end

    test "the page's own markup after the body stays the page's" do
      for payload <- [~s|<p>x</p><img src=x |, ~s|<p>x</p><!-- |, ~s|<p>x</p><textarea>|] do
        assert payload
               |> S.sanitize()
               |> page()
               |> LazyHTML.query("p")
               |> Enum.map(&LazyHTML.text/1) ==
                 ["x", "after"],
               inspect(payload)
      end
    end

    test "control: clean markup that ends closed keeps its tree, an open p included" do
      for html <- [
            ~s|<p>a</p><img src="https://x/y.png" alt="">|,
            ~s|<p>a<img src="https://x/y.png" alt=""/>b|,
            ~s|text only|
          ] do
        assert same_tree?(html), html
      end
    end
  end

  describe "F2: plaintext and listing" do
    for tag <- ~w(plaintext listing) do
      @tag_name tag
      test "<#{tag}> is dropped" do
        out = S.sanitize("<p>a</p><#{@tag_name}><p>b</p>")
        assert out |> LazyHTML.from_fragment() |> count(@tag_name) == 0
        assert out |> page() |> count("p") >= 2
      end
    end
  end

  describe "F3: custom elements" do
    test "a Studio component is unwrapped, its text kept" do
      out =
        S.sanitize(
          ~s|<bp-rich-text-editor data-value="&lt;img src=x onerror=alert(1)&gt;" value="&lt;meta http-equiv=refresh&gt;">kept</bp-rich-text-editor>|
        )

      assert out == "kept"
    end

    test "any hyphenated tag is unwrapped" do
      assert S.sanitize(~s|<x-card data-value="x"><p>t</p></x-card>|) == "<p>t</p>"
    end

    test "every custom element the renderer emits is kept (none today)" do
      emitted =
        for f <-
              Path.wildcard(
                Path.expand("../../../priv/portable_doc/goldens/*/*.golden.json", __DIR__)
              ),
            %{"expectedHtml" => html} when is_binary(html) <- [Jason.decode!(File.read!(f))],
            [_, tag] <- Regex.scan(~r/<([a-z][a-z0-9]*-[a-z0-9-]*)/, html),
            uniq: true,
            do: tag

      assert emitted -- S.custom_elements() == []
    end
  end

  describe "F4: nothing stored covers the page" do
    defp style_of(html),
      do: html |> LazyHTML.from_fragment() |> LazyHTML.query("a") |> LazyHTML.attribute("style")

    defp class_of(html),
      do: html |> LazyHTML.from_fragment() |> LazyHTML.query("a") |> LazyHTML.attribute("class")

    test "a fixed full-page overlay link comes out in the flow" do
      out =
        S.sanitize(
          ~s|<a href="https://evil.example" style="position:fixed;inset:0;top:0;left:0;right:0;bottom:0;z-index:99999;width:100vw;height:100vh;transform:none;background:url(https://evil.example/x.png)">x</a>|
        )

      # Nothing in it is a value the renderer writes there: `top:0` and
      # `left:0` too (it writes `top:-0.7rem` and `left: N%`).
      assert style_of(out) == []
    end

    test "the worst renderer class with a placed style cannot cover the page" do
      # `.bp-rm__bar` is `position: absolute` in the reader CSS; with `style`
      # sizing it, a stored one was a full-page link.
      out =
        S.sanitize(
          ~s|<a href="https://evil.example" class="bp-rm__bar bp-rm__lane" style="position:relative;top:2rem;width:100%">x</a>|
        )

      assert class_of(out) == ["bp-rm__lane"]
      assert style_of(out) == ["position:relative;width:100%"]

      for denied <-
            ~w(bp-rm__bar bp-rm__ms bp-rm__note bp-rm__today bp-rm__unplaced bp-toc--sticky bp-form-q--scale bp-form-q--yesno) do
        refute S.keep_class?(denied), denied
      end
    end

    test "position, top and left are kept only by value" do
      for {decl, kept?} <- [
            {"position:relative", true},
            {"position:absolute", false},
            {"position:sticky", false},
            {"position:fixed", false},
            {"top:-0.7rem", true},
            {"top:-0.8rem", false},
            {"top:2em", false},
            {"top:3rem", false},
            {"top:0", false},
            {"left:40%", true},
            {"left:100%", true},
            {"left:101%", false},
            {"left:-1%", false},
            {"top:20px", false}
          ] do
        out = S.sanitize(~s|<a href="#" style="#{decl};color:#fff">x</a>|)
        assert style_of(out) == [if(kept?, do: "#{decl};color:#fff", else: "color:#fff")], decl
      end
    end

    test "a custom property keeps only a short value that cannot load or escape" do
      for {decl, kept?} <- [
            {"--bp-cols:3", true},
            {"--bp-cols:13", false},
            {"--i:1", true},
            {"--bp-tracks:repeat(3, 1fr)", false},
            {"--bp-grid-gap:var(--bp-space-md, 1.2rem)", true},
            {"--bp-grid-gap:1.2rem", false},
            {"--bp-cols:url(https://evil.example/x)", false},
            {"--bp-cols:a\\62 c", false},
            {"--bp-cols:@import", false},
            {"--bp-cols:}", false},
            {"--bp-cols:expression(alert(1))", false},
            {"--bp-cols:" <> String.duplicate("1", 65), false},
            {"--evil:1", false}
          ] do
        out = S.sanitize(~s|<a href="#" style="#{decl};color:#fff">x</a>|)
        assert style_of(out) == [if(kept?, do: "#{decl};color:#fff", else: "color:#fff")], decl
      end
    end

    test "class and data-… keep only the renderer's names" do
      out =
        S.sanitize(
          ~s|<a href="#" class="bp-callout bp-callout--danger modal-backdrop bp-object-dialog" data-level="1" data-paper-link-open data-phx-link="redirect">x</a>|
        )

      assert class_of(out) == ["bp-callout bp-callout--danger"]
      doc = LazyHTML.from_fragment(out)
      assert count(doc, "a[data-level]") == 1
      assert count(doc, "a[data-paper-link-open], a[data-phx-link]") == 0
    end

    # Every rule in the CSS on the reader page (and the editor's, loaded when
    # an editor opens Edit there) that takes an element out of the flow must
    # name a class or data attribute stored markup can no longer carry.
    test "no positioned rule in the reader CSS can match stored markup" do
      api = Path.expand("../../..", __DIR__)

      css =
        [
          Barkpark.PortableDoc.Render.Stylesheet.css(),
          File.read!(Path.join(api, "lib/barkpark_web/layouts/bulldocs.html.heex")),
          File.read!(Path.join(api, "priv/static/assets/bp-paper-editor-shell.css")),
          File.read!(Path.join(api, "priv/static/assets/bp-media-picker.css")),
          File.read!(Path.join(api, "priv/static/assets/asciinema-player.css"))
        ]
        |> Enum.join("\n")
        |> then(&Regex.replace(~r{/\*.*?\*/}s, &1, ""))

      reachable =
        for [_, selectors, body] <- Regex.scan(~r/([^{}]+)\{([^{}]*)\}/, css),
            Regex.match?(~r/position\s*:\s*(fixed|sticky|absolute)/, body),
            selector <- String.split(selectors, ","),
            selector = String.trim(selector),
            reachable?(selector),
            do: selector

      assert Enum.uniq(reachable) == []
    end
  end

  describe "B1: a formatting element left open across a closing tag" do
    # In the page, the first text after the body builds it again, around the
    # rest of the page.
    defp wraps_after?(html, tag) do
      html
      |> page()
      |> LazyHTML.query(tag)
      |> Enum.any?(&(LazyHTML.text(&1) =~ "after"))
    end

    for tag <- ~w(a b font i em strong u s code nobr big),
        {name, before, close} <- [
          {"</p>", "<p>Clean ", "</p>"},
          {"</li>", "<ul><li>Clean ", "</li></ul>"},
          {"</td>", "<table><tr><td>Clean ", "</td></tr></table>"},
          {"</div>", "<div>Clean ", "</div>"}
        ] do
      @tag_name tag
      @close name
      @payload before <>
                 ~s|<#{tag} href="https://evil.example/" style="display:block" color="red">link| <>
                 close
      test "<#{tag}> left open across #{name} wraps nothing after the body" do
        # A table cell ends what was opened in it (a marker on the list), so
        # the raw `</td>` payload wraps nothing either; it is kept as a case.
        if @close != "</td>",
          do: assert(wraps_after?(@payload, @tag_name), "control: the raw payload wraps the page")

        refute @payload |> S.sanitize() |> wraps_after?(@tag_name)
      end
    end

    test "control: a formatting element closed in its paragraph keeps its bytes" do
      html = ~s|<p>Clean <a href="https://x.example/">link</a></p><p><b>b</b> <i>i</i></p>|
      assert S.sanitize(html) == html
    end
  end

  describe "B2: an overlay without position" do
    # A kept style cannot pull its box over what came before (no negative
    # number) nor size it past the renderer's own boxes.
    defp contained!(out) do
      for style <- style_of(out), {_unit, x} <- elem(StyleGrammar.Shape.read(style), 1) do
        assert x >= 0, style
        assert x <= 640, style
      end
    end

    for {name, style, kept} <- [
          {"the review's overlay",
           "display:block;opacity:0.99;background:#fff;margin-top:-5000px;margin-left:-5000px;width:20000px;height:20000px",
           "display:block;background:#fff"},
          {"inline-block without opacity",
           "display:inline-block;width:20000px;height:20000px;margin:-100px 0 0 -100px;background:#fff",
           "display:inline-block;background:#fff"},
          {"padding in place of width", "display:block;padding:5000px;background:#fff",
           "display:block;background:#fff"},
          {"a negative text-indent", "display:block;text-indent:-9999px;font-size:900px",
           "display:block"},
          {"a negative margin shorthand and a big border",
           "margin:-50px 0 0;border:900px solid #fff;line-height:40", nil},
          {"a large em and rem", "width:400em;height:300rem;max-width:5000px;min-width:9999px",
           nil}
        ] do
      @style style
      @kept kept
      test "#{name} comes out unable to cover the page" do
        out = S.sanitize(~s|<a href="https://evil.example/" style="#{@style}">x</a>|)
        assert style_of(out) == if(@kept, do: [@kept], else: [])
        contained!(out)
      end
    end

    test "opacity keeps only the values the renderer writes, display only its own" do
      for {decl, kept?} <- [
            {"opacity:0.6", true},
            {"opacity:0.85", true},
            {"opacity:0.99", false},
            {"opacity:1", false},
            {"display:flex", true},
            {"display:inline-block", true},
            {"display:table", false},
            {"display:contents", false},
            {"margin:0 0 16px", true},
            {"margin:0 0 -16px", false},
            {"width:100%", true},
            {"width:120%", false},
            {"width:200px", true},
            {"width:2000px", false}
          ] do
        out = S.sanitize(~s|<a href="#" style="#{decl};color:#fff">x</a>|)
        assert style_of(out) == [if(kept?, do: "#{decl};color:#fff", else: "color:#fff")], decl
      end
    end
  end

  describe "B3: an element a browser parses differently is never passed through" do
    alias Barkpark.PortableDoc.HtmlSanitizer.Elements

    @refresh ~s|<meta http-equiv="refresh" content="0;url=https://e.example/">|
    @handler ~s|<img src=x onerror="alert(1)">|

    # lexbor reads a select by the old rules and drops the tags in it; Chrome
    # builds them, so the bytes navigated the reader.
    test "a meta in a select is gone" do
      out = S.sanitize("<select>" <> @refresh <> "</select>")
      refute out =~ ~r/meta|refresh/i
      assert out |> page() |> count("meta, select") == 0
    end

    test "an img with a handler in a select is gone" do
      out =
        S.sanitize(
          "<select>" <> @handler <> ~s|<iframe src="https://e.example/"></iframe></select>|
        )

      refute out =~ ~r/onerror|<img|<iframe/i
    end

    for tag <- ~w(select option optgroup datalist selectedcontent template noscript textarea) do
      @tag_name tag
      test "<#{tag}> goes with its content, the text around it stays" do
        out =
          S.sanitize(
            "<p>a</p><#{@tag_name}>" <> @handler <> @refresh <> "</#{@tag_name}><p>b</p>"
          )

        refute out =~ ~r/onerror|<img|<meta|<#{@tag_name}/i

        assert out |> page() |> LazyHTML.query("p") |> Enum.map(&LazyHTML.text/1) == [
                 "a",
                 "b",
                 "after"
               ]
      end
    end

    test "an element the renderer does not write is unwrapped, so its bytes never pass" do
      for tag <- ~w(dialog search marquee font center portal geolocation) do
        html = "<p>a</p><#{tag}>t</#{tag}>"
        out = S.sanitize(html)
        refute out == html, tag
        assert out |> LazyHTML.from_fragment() |> count(tag) == 0, tag
        assert out =~ "a"
      end
    end

    test "a legacy body with em, br and dl keeps them" do
      for html <- [
            ~s|<p>One<br>two<br/>three, <em>stressed</em>, <s>old</s> <ins>new</ins></p>|,
            ~s|<dl><dt>Term</dt><dd>Its <abbr title="definition">def</abbr>, <time datetime="2026-11-23">today</time></dd></dl>|,
            ~s|<table><caption>Sums</caption><tbody><tr><td>1</td></tr></tbody><tfoot><tr><td>1</td></tr></tfoot></table>|,
            ~s|<p><kbd>K</kbd> <samp>s</samp> <var>v</var> <small>x</small> <q>y</q> <u>z</u> <del>d</del> long<wbr>word</p>|
          ] do
        assert same_tree?(html), html
      end
    end

    test "the kept elements are the renderer's, none parsed in a mode of its own" do
      special = ~w(select option optgroup datalist selectedcontent template noscript textarea
                   iframe object embed svg math script style title xmp plaintext listing)

      assert Elements.kept() -- special == Elements.kept()
      assert Elements.inert() -- Elements.kept() == []
      assert Enum.all?(special, &(&1 in Elements.dropped()))
      assert ~w(a p div span table td img h2 h6 code pre) -- Elements.kept() == []
    end
  end

  describe "B4: a stray end tag never closes the reader's box" do
    # A fragment parse ignores an end tag it has nothing open for; the page
    # obeys it and closes the reader's `<article style="contain: paint">`, or
    # the /email box, and the rest of the body lands outside it.
    defp reader(html),
      do:
        LazyHTML.from_document(
          ~s|<html><body><main><section><div><article id="paper-body">| <>
            html <> ~s|</article></div></section><p id="after">after</p></main></body></html>|
        )

    for tag <- ~w(article main div section body html) do
      @tag_name tag
      test "</#{tag}> in the body closes nothing outside it" do
        html = "<p>a</p></#{@tag_name}><p id=\"bp-anchor-esc\">b</p>"
        out = S.sanitize(html)

        refute out =~ "</#{@tag_name}>"
        doc = reader(out)
        assert count(doc, "#paper-body > p") == 2
        assert count(doc, "#paper-body #bp-anchor-esc") == 1
        assert count(doc, "main > #after") == 1
      end
    end

    test "control: the raw input does close the box" do
      doc = reader(~s|<p>a</p></article><p id="bp-anchor-esc">b</p>|)
      assert count(doc, "#paper-body #bp-anchor-esc") == 0
    end

    test "the output is always the serialised tree, and a second pass the same bytes" do
      for html <- [
            ~s|<p>a</p></article></main></div><p>b</p>|,
            ~s|<p>x</p><img src=x onerror=alert(1) |,
            ~s|<p><a href="https://x.example/">open|,
            ~s|<button><button>x</button></button>|,
            ~s|<h4>a<u>b<h3>c</h3></u></h4>|,
            ~s|<select><meta http-equiv="refresh" content="0;url=https://e.example/"></select>|
          ] do
        out = S.sanitize(html)
        # What a tree serialises to: it reads back as itself.
        assert out == out |> tree() |> LazyHTML.from_tree() |> LazyHTML.to_html(), html
        assert S.sanitize(out) == out, html
        refute out =~ ~r{</(article|main|body|html)>}
      end
    end
  end

  # Whether stored markup can be the subject of `selector`: the subject has
  # no class or data attribute the sanitizer drops, and no ancestor names a
  # renderer class it denies (the page's own markup never carries one). A pseudo-element subject holds no stored markup.
  # The asciinema player's `pre.ap-terminal .ap-line span` is its own widget:
  # stored markup can neither carry `ap-` classes nor sit inside it.
  defp reachable?(selector) do
    compounds = String.split(selector, ~r/\s*[>+~]\s*|\s+/, trim: true)
    subject = List.last(compounds) || ""
    classes = &Regex.scan(~r/\.([a-zA-Z_][a-zA-Z0-9_-]*)/, &1, capture: :all_but_first)
    data = &Regex.scan(~r/\[(data-[a-z0-9_-]+)/, &1, capture: :all_but_first)

    cond do
      subject =~ ~r/::|:(before|after|marker|placeholder|backdrop)\b/ ->
        false

      Enum.any?(classes.(selector), fn [c] -> String.starts_with?(c, "ap-") end) ->
        false

      Enum.any?(classes.(subject), fn [c] -> not S.keep_class?(c) end) ->
        false

      Enum.any?(data.(subject), fn [d] -> S.sanitize(~s|<p #{d}="1">x</p>|) == "<p>x</p>" end) ->
        false

      Enum.any?(classes.(selector), fn [c] -> c in S.denied_classes() end) ->
        false

      true ->
        true
    end
  end
end
