defmodule Barkpark.PortableDoc.Render.WalkTest do
  # Pure, in-process walker — no DB, no side-effects.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Walk
  alias Barkpark.PortableDoc.Render.Palettes

  @email Palettes.email_palette()
  @article Palettes.article_palette()
  @width 600

  # ── render_body/3 ──────────────────────────────────────────────────────────

  describe "render_body/3 — PdHr" do
    test "emits hr with default thickness 1 and palette rule colour" do
      html = Walk.render_body(%{"kind" => "PdHr"}, @width, @email)
      assert html == ~s(<hr style="border:none;border-top:1px solid #e5e7eb;margin:16px 0">)
    end

    test "respects explicit thickness" do
      html = Walk.render_body(%{"kind" => "PdHr", "thickness" => 3}, @width, @email)
      assert html =~ "border-top:3px solid"
    end
  end

  describe "render_body/3 — PdInlineCode" do
    test "escapes HTML entities inside value" do
      html = Walk.render_body(%{"kind" => "PdInlineCode", "value" => "a & <b>"}, @width, @email)
      assert html =~ "a &amp; &lt;b&gt;"
      assert html =~ "<code style="
    end

    test "uses empty string when value is absent" do
      html = Walk.render_body(%{"kind" => "PdInlineCode"}, @width, @email)
      assert html =~ "<code style="
      refute html =~ "nil"
    end
  end

  describe "render_body/3 — PdText" do
    test "emits bare span with no style when node has no decoration" do
      html = Walk.render_body(%{"kind" => "PdText", "children" => ["hello"]}, @width, @email)
      assert html == "<span>hello</span>"
    end

    test "combines bold + strike into correct style attributes" do
      node = %{
        "kind" => "PdText",
        "weight" => "bold",
        "strike" => true,
        "children" => ["x"]
      }

      html = Walk.render_body(node, @width, @email)
      assert html =~ "font-weight:bold"
      assert html =~ "text-decoration:line-through"
    end

    test "escapes HTML in string children" do
      node = %{"kind" => "PdText", "children" => ["<script>"]}
      html = Walk.render_body(node, @width, @email)
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
    end
  end

  describe "render_body/3 — PdLink" do
    test "wraps children in anchor with safe href" do
      node = %{"kind" => "PdLink", "href" => "https://example.com", "children" => ["go"]}
      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s(href="https://example.com")
      assert html =~ "go"
      assert html =~ "<a "
    end

    test "javascript: href is sanitised by safe_url (returns # sentinel)" do
      node = %{"kind" => "PdLink", "href" => "javascript:alert(1)", "children" => ["bad"]}
      html = Walk.render_body(node, @width, @email)
      # safe_url returns "#" for unsafe schemes — never a bare javascript: in the DOM
      assert html =~ ~s(href="#")
      refute html =~ "javascript:"
    end
  end

  describe "render_body/3 — PdWikilink" do
    test "renders unresolved target as dotted span (no href)" do
      node = %{
        "kind" => "PdWikilink",
        "target" => "Missing Page",
        "children" => ["Missing Page"]
      }

      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s(data-wikilink="Missing Page")
      assert html =~ "text-decoration:underline dotted"
      refute html =~ "<a "
    end

    test "renders resolved target as <a href=/papers/:id>" do
      pal = Map.put(@email, :wikilinks, %{"Home" => %{id: "doc-42"}})

      node = %{
        "kind" => "PdWikilink",
        "target" => "Home",
        "children" => ["Home"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(href="/papers/doc-42")
      assert html =~ "<a "
    end

    test "id-pin: a carried doc_id resolves to /papers/:id with an EMPTY :wikilinks palette" do
      # Proves the id-pin bypasses title resolution — the palette has no entry
      # for "Setup" (in fact it has no entries at all), yet the pin still links.
      pal = Map.put(@email, :wikilinks, %{})

      node = %{
        "kind" => "PdWikilink",
        "target" => "Setup",
        "doc_id" => "p-pinned-99",
        "children" => ["Setup"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(href="/papers/p-pinned-99")
      assert html =~ ~s(data-wikilink="Setup")
      assert html =~ "text-decoration:none"
      refute html =~ "dotted"
    end

    test "id-pin: doc_id wins over a clashing title entry (duplicate-title hole)" do
      # Two papers share the title "Setup"; the palette resolves the title to
      # the WRONG one. The pinned doc_id must override and link the picked paper.
      pal = Map.put(@email, :wikilinks, %{"Setup" => %{id: "wrong-doc"}})

      node = %{
        "kind" => "PdWikilink",
        "target" => "Setup",
        "doc_id" => "right-doc",
        "children" => ["Setup"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(href="/papers/right-doc")
      refute html =~ "wrong-doc"
    end

    test "no doc_id: empty/missing pin is byte-identical to the pre-pin render" do
      # A typed-not-picked wikilink (no doc_id) must round-trip exactly as
      # before — resolved via palette, dotted span when absent, and an empty
      # "" doc_id must NOT trigger the fast path.
      node = %{"kind" => "PdWikilink", "target" => "Home", "children" => ["Home"]}
      node_empty = Map.put(node, "doc_id", "")
      pal = Map.put(@email, :wikilinks, %{"Home" => %{id: "doc-42"}})

      # Resolved-via-palette path is untouched whether doc_id is absent or "".
      assert Walk.render_body(node, @width, pal) == Walk.render_body(node_empty, @width, pal)
      assert Walk.render_body(node, @width, pal) =~ ~s(href="/papers/doc-42")

      # Unresolved (empty palette) still degrades to the dotted span.
      bare = Map.put(@email, :wikilinks, %{})
      assert Walk.render_body(node, @width, bare) =~ "text-decoration:underline dotted"
      assert Walk.render_body(node_empty, @width, bare) == Walk.render_body(node, @width, bare)
    end
  end

  describe "render_body/3 — PdEmbed" do
    test "renders the transclusion container with the injected, pre-rendered html" do
      # The :embeds entry IS renderer output — injected verbatim inside the
      # <section class="paper-embed"> with the data-embed pointing at the target.
      pal = Map.put(@email, :embeds, %{"Note A" => "<p>hello world</p>"})
      node = %{"kind" => "PdEmbed", "target" => "Note A"}

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(<section class="paper-embed" data-embed="Note A")
      assert html =~ "<p>hello world</p>"
      refute html =~ "paper-embed--unresolved"
    end

    test "renders the unresolved fallback when the target is absent from :embeds" do
      # No matching entry → a NON-navigating broken-embed placeholder (no <a>,
      # since a raw human title is not a slug and would 404), mirroring the
      # wikilink dotted-span treatment.
      pal = Map.put(@email, :embeds, %{})
      node = %{"kind" => "PdEmbed", "target" => "Ghost Note"}

      html = Walk.render_body(node, @width, pal)
      assert html =~ "paper-embed paper-embed--unresolved"
      assert html =~ ~s(data-embed="Ghost Note")
      assert html =~ "↪ Ghost Note"
      refute html =~ "<a "
      refute html =~ "/papers/"
      refute html =~ "<p>"
    end

    test "no :embeds key at all degrades to the unresolved fallback" do
      # Byte-identical to a caller who never opts in — empty map ≡ missing key.
      node = %{"kind" => "PdEmbed", "target" => "Note A"}
      with_empty = Map.put(@email, :embeds, %{})

      assert Walk.render_body(node, @width, @email) =~ "paper-embed--unresolved"
      assert Walk.render_body(node, @width, @email) == Walk.render_body(node, @width, with_empty)
    end

    test "injected html is NOT double-escaped — it appears verbatim inside the section" do
      # The resolver already produced safe HTML; the walker emits it as-is. A
      # raw "<p>hi</p>" must survive intact, NOT become "&lt;p&gt;hi&lt;/p&gt;".
      pal = Map.put(@email, :embeds, %{"Note A" => "<p>hi</p>"})
      node = %{"kind" => "PdEmbed", "target" => "Note A"}

      html = Walk.render_body(node, @width, pal)
      assert html =~ "<p>hi</p>"
      refute html =~ "&lt;p&gt;"
    end

    test "the data-embed attr value IS escaped" do
      # The target string flows through escape_html — quotes/brackets can't
      # break out of the attribute, even though the injected body is verbatim.
      pal = Map.put(@email, :embeds, %{~s(A "quote" & <b>) => "<p>ok</p>"})
      node = %{"kind" => "PdEmbed", "target" => ~s(A "quote" & <b>)}

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(data-embed="A &quot;quote&quot; &amp; &lt;b&gt;")
      # The injected body is still verbatim — only the attr was escaped.
      assert html =~ "<p>ok</p>"
    end
  end

  describe "render_body/3 — PdTag" do
    test "renders a navigable <a href=/tags/:name> chip with #name text" do
      node = %{"kind" => "PdTag", "name" => "design"}

      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s(<a href="/tags/design")
      assert html =~ ~s(data-tag="design")
      assert html =~ "#design"
      # Chip styling survives the span → anchor conversion.
      assert html =~ "border-radius:3px"
      assert html =~ "font-size:0.9em"
      assert html =~ "text-decoration:none"
    end

    test "url-encodes the name in the href but shows it decoded in the chip" do
      node = %{"kind" => "PdTag", "name" => "my tag"}

      html = Walk.render_body(node, @width, @email)
      # Space is percent-encoded in the href…
      assert html =~ ~s(href="/tags/my%20tag")
      # …but the visible text + data-tag attr stay decoded.
      assert html =~ ">#my tag</a>"
      assert html =~ ~s(data-tag="my tag")
    end

    test "url-encodes a unicode tag name in the href" do
      node = %{"kind" => "PdTag", "name" => "café"}

      html = Walk.render_body(node, @width, @email)
      assert html =~ "href=\"/tags/caf%C3%A9"
      assert html =~ ">#café</a>"
    end

    test "component-encodes a NESTED tag so it stays one path segment" do
      # Obsidian's signature nested tag: the slash MUST be percent-encoded
      # (%2F), or /tags/project/active would split into two path segments and
      # 404 the single-segment [tag] route. The visible chip stays decoded.
      node = %{"kind" => "PdTag", "name" => "project/active"}

      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s(href="/tags/project%2Factive")
      refute html =~ ~s(href="/tags/project/active")
      assert html =~ ">#project/active</a>"
      assert html =~ ~s(data-tag="project/active")
    end
  end

  describe "render_body/3 — PdHeading (article only)" do
    test "emits <h2> for level 2 with article font" do
      node = %{"kind" => "PdHeading", "level" => 2, "children" => ["Title"]}
      html = Walk.render_body(node, @width, @article)
      assert html =~ "<h2 style="
      assert html =~ "font-size:24px"
      assert html =~ "Title</h2>"
    end

    test "clamps unknown level to h2" do
      node = %{"kind" => "PdHeading", "level" => 99, "children" => ["H?"]}
      html = Walk.render_body(node, @width, @article)
      assert html =~ "<h2 style="
    end
  end

  describe "render_body/3 — unhandled kind raises" do
    test "raises ArgumentError for unknown kind" do
      assert_raise ArgumentError, ~r/unhandled PdUnknownWidget/, fn ->
        Walk.render_body(%{"kind" => "PdUnknownWidget"}, @width, @email)
      end
    end
  end

  describe "render_body/3 — _raw passthrough" do
    test "emits pre-rendered HTML byte-exact" do
      raw = "<figure><pre class=\"mermaid\">graph LR; A-->B</pre></figure>"
      html = Walk.render_body(%{"kind" => "_raw", "html" => raw}, @width, @email)
      assert html == raw
    end
  end

  # ── stored-XSS: raw block attribute breakout ────────────────────────────────
  # Numeric/color block fields (image width/height, hr thickness, every
  # box_style/1 field) are spliced into inline HTML attributes. A stray double
  # quote in the value must be neutralized to &quot; so it can't close the attr
  # and inject an event handler against every viewer of the public paper.

  describe "render_body/3 — attribute-breakout escaping" do
    test "PdImage width can't break out of the attribute" do
      node = %{
        "kind" => "PdImage",
        "src" => "https://example.com/a.png",
        "width" => ~s(1" onerror="x)
      }

      html = Walk.render_body(node, @width, @email)

      assert html =~ "&quot;"
      # The only literal double-quotes are the attribute delimiters; the
      # injected payload's quotes are escaped, so no `onerror` handler survives.
      refute html =~ ~s(onerror=")
    end

    test "PdBox backgroundColor can't break out of the style attribute" do
      node = %{
        "kind" => "PdBox",
        "style" => %{"backgroundColor" => ~s(red" onclick="x)},
        "children" => []
      }

      html = Walk.render_body(node, @width, @email)

      assert html =~ "&quot;"
      refute html =~ ~s(onclick=")
    end

    test "PdHr thickness can't break out of the style attribute" do
      node = %{"kind" => "PdHr", "thickness" => ~s(1" onload="x)}
      html = Walk.render_body(node, @width, @email)

      assert html =~ "&quot;"
      refute html =~ ~s(onload=")
    end

    test "legit integer dimensions render byte-identically (no escaping noise)" do
      node = %{"kind" => "PdImage", "src" => "https://example.com/a.png", "width" => 640}
      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s( width="640")
      refute html =~ "&quot;"
    end
  end
end
