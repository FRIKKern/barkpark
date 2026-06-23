defmodule Barkpark.PortableDoc.RenderTest do
  # Pure, in-process port of the portable-doc static render walker — no DB.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  describe "render_html/2 doctype wrapping" do
    test "wraps the body in a full document by default" do
      html = Render.render_html(%{"kind" => "PdHr"})
      assert String.starts_with?(html, "<!doctype html><html><head>")
      assert String.contains?(html, ~s(<body style="background:#f9fafb;margin:0;padding:0;">))
      assert String.ends_with?(html, "</body></html>")
    end

    test "emits only the body fragment when doctype: false" do
      html = Render.render_html(%{"kind" => "PdHr"}, %{doctype: false})
      assert html == ~s(<hr style="border:none;border-top:1px solid #e5e7eb;margin:16px 0">)
    end
  end

  describe "walk/2 — one expected fragment per kind" do
    @opts %{doctype: false}

    test "PdContainer clamps width with min(maxWidth, width)" do
      node = %{"kind" => "PdContainer", "maxWidth" => 400, "children" => []}
      # default width 600, maxWidth 400 → clamps to 400
      assert Render.render_html(node, @opts) ==
               ~s(<div style="max-width:400px;margin:0 auto;padding:24px;font-family:-apple-system,'SF Pro Text',system-ui,sans-serif;color:#111827;background:#ffffff"></div>)
    end

    test "PdContainer clamps to the smaller container budget when maxWidth exceeds it" do
      node = %{"kind" => "PdContainer", "maxWidth" => 900, "children" => []}

      assert Render.render_html(node, %{doctype: false, container_width: 600}) =~
               "max-width:600px"
    end

    test "PdBox with empty style emits an empty style attr" do
      node = %{"kind" => "PdBox", "children" => []}
      assert Render.render_html(node, @opts) == ~s(<div style=""></div>)
    end

    test "PdBox composes flex + border style in order" do
      node = %{
        "kind" => "PdBox",
        "style" => %{
          "flexDirection" => "row",
          "padding" => 8,
          "borderWidth" => 2,
          "borderColor" => "#000000",
          "borderStyle" => "bold",
          "backgroundColor" => "#eeeeee"
        },
        "children" => []
      }

      assert Render.render_html(node, @opts) ==
               ~s(<div style="display:flex;flex-direction:row;padding:8px;border:2px solid #000000;background-color:#eeeeee"></div>)
    end

    test "PdText with no styling emits NO style attr (trap)" do
      node = %{"kind" => "PdText", "children" => ["hello"]}
      assert Render.render_html(node, @opts) == "<span>hello</span>"
    end

    test "PdText with styling and mixed children (string + child node)" do
      node = %{
        "kind" => "PdText",
        "weight" => "bold",
        "underline" => true,
        "color" => "#ff0000",
        "children" => [
          "plain ",
          %{"kind" => "PdInlineCode", "value" => "x"}
        ]
      }

      assert Render.render_html(node, @opts) ==
               ~s(<span style="font-weight:bold;text-decoration:underline;color:#ff0000">plain ) <>
                 ~s(<code style="background:#f3f4f6;padding:2px 6px;font-family:ui-monospace,Menlo,monospace;font-size:0.95em">x</code></span>)
    end

    test "PdLink escapes string children and uses safe href" do
      node = %{
        "kind" => "PdLink",
        "href" => "https://example.com",
        "children" => ["click <here>"]
      }

      assert Render.render_html(node, @opts) ==
               ~s(<a href="https://example.com" style="color:#1d4ed8;text-decoration:underline">click &lt;here&gt;</a>)
    end

    test "PdInlineCode escapes its value" do
      node = %{"kind" => "PdInlineCode", "value" => "a & b"}

      assert Render.render_html(node, @opts) ==
               ~s(<code style="background:#f3f4f6;padding:2px 6px;font-family:ui-monospace,Menlo,monospace;font-size:0.95em">a &amp; b</code>)
    end

    test "strikethrough / underline inline WRAPPER nodes compose + render to text-decoration" do
      # The new convert.js round-trip emits wrapper nodes; compose_inline must
      # turn them into PdText strike/underline (NOT hit the catch-all raise),
      # and the walk must render text-decoration. Guards the t4 marks round-trip.
      strike =
        Render.Inline.compose_inline(
          %{"type" => "strikethrough", "children" => [%{"type" => "text", "value" => "gone"}]},
          false
        )

      assert Render.render_html(strike, @opts) =~ "text-decoration:line-through"

      underline =
        Render.Inline.compose_inline(
          %{"type" => "underline", "children" => [%{"type" => "text", "value" => "keep"}]},
          false
        )

      assert Render.render_html(underline, @opts) =~ "text-decoration:underline"
    end

    test "PdButton primary uses brand background" do
      node = %{
        "kind" => "PdButton",
        "href" => "https://x.test",
        "label" => "Go",
        "priority" => "primary"
      }

      assert Render.render_html(node, @opts) ==
               ~s(<a href="https://x.test" style="display:inline-block;padding:10px 20px;background:#4f46e5;color:#ffffff;text-decoration:none;font-weight:bold;border-radius:0">Go</a>)
    end

    test "PdButton secondary uses brand border" do
      node = %{
        "kind" => "PdButton",
        "href" => "https://x.test",
        "label" => "Go",
        "priority" => "secondary"
      }

      assert Render.render_html(node, @opts) ==
               ~s(<a href="https://x.test" style="display:inline-block;padding:10px 20px;border:2px solid #4f46e5;color:#4f46e5;text-decoration:none;font-weight:bold;border-radius:0">Go</a>)
    end

    test "PdHr respects thickness, defaults to 1" do
      assert Render.render_html(%{"kind" => "PdHr", "thickness" => 2}, @opts) ==
               ~s(<hr style="border:none;border-top:2px solid #e5e7eb;margin:16px 0">)
    end

    test "PdImage emits dims and escapes alt; safe src" do
      node = %{
        "kind" => "PdImage",
        "src" => "https://img.test/a.png",
        "alt" => "an \"image\"",
        "width" => 100,
        "height" => 50
      }

      assert Render.render_html(node, @opts) ==
               ~s(<img src="https://img.test/a.png" alt="an &quot;image&quot;" style="max-width:100%;height:auto" width="100" height="50">)
    end

    test "PdTable renders rows/cells with recursed children" do
      node = %{
        "kind" => "PdTable",
        "rows" => [
          [
            [%{"kind" => "PdText", "children" => ["A"]}],
            [%{"kind" => "PdText", "children" => ["B"]}]
          ]
        ]
      }

      assert Render.render_html(node, @opts) ==
               ~s(<table role="presentation" style="border-collapse:collapse;width:100%">) <>
                 ~s(<tr><td style="border:1px solid #e5e7eb;padding:8px 12px;vertical-align:top"><span>A</span></td>) <>
                 ~s(<td style="border:1px solid #e5e7eb;padding:8px 12px;vertical-align:top"><span>B</span></td></tr></table>)
    end

    test "PdCallout uses tone palette and optional title" do
      node = %{
        "kind" => "PdCallout",
        "tone" => "warning",
        "title" => "Heads up",
        "children" => [%{"kind" => "PdText", "children" => ["body"]}]
      }

      assert Render.render_html(node, @opts) ==
               ~s(<div style="border-left:4px solid #92400e;background:#fffbeb;padding:16px;color:#92400e"><strong>Heads up</strong> <span>body</span></div>)
    end
  end

  describe "escape_html/1 — exact replace order & < > \" '" do
    test "escapes all five significant characters without double-encoding" do
      assert Render.escape_html("<") == "&lt;"
      assert Render.escape_html("&") == "&amp;"
      assert Render.escape_html("\"") == "&quot;"
      assert Render.escape_html("'") == "&#39;"
      assert Render.escape_html(">") == "&gt;"
    end

    test "ampersand-first order avoids double escaping the introduced entities" do
      # If `<` were escaped before `&`, the resulting `&lt;` would have its `&`
      # re-escaped into `&amp;lt;`. The ampersand-first order prevents that.
      assert Render.escape_html("<&\"'") == "&lt;&amp;&quot;&#39;"
    end
  end

  describe "render_block/1 — portable-doc block → fragment (Wave 4)" do
    test "heading composes to a bold span" do
      block = %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Title"}
      assert Render.render_block(block) == ~s(<span style="font-weight:bold">Title</span>)
    end

    test "paragraph with plain text composes to a span" do
      block = %{
        "id" => "p1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Hello"}]
      }

      assert Render.render_block(block) == "<span>Hello</span>"
    end

    test "divider composes to an hr" do
      assert Render.render_block(%{"id" => "d", "type" => "divider"}) ==
               ~s(<hr style="border:none;border-top:1px solid #e5e7eb;margin:16px 0">)
    end

    test "callout uses tone palette and title (matches fixture block shape)" do
      block = %{
        "id" => "c",
        "type" => "callout",
        "tone" => "warning",
        "title" => "Degraded",
        "content" => [%{"type" => "text", "value" => "API latency is elevated."}]
      }

      assert Render.render_block(block) ==
               ~s(<div style="border-left:4px solid #92400e;background:#fffbeb;padding:16px;color:#92400e">) <>
                 ~s(<strong>Degraded</strong> <span>API latency is elevated.</span></div>)
    end

    test "action composes to a primary button" do
      block = %{
        "id" => "a",
        "type" => "action",
        "label" => "Read more",
        "href" => "https://example.com/notes",
        "priority" => "primary"
      }

      assert Render.render_block(block) ==
               ~s(<a href="https://example.com/notes" style="display:inline-block;padding:10px 20px;background:#4f46e5;color:#ffffff;text-decoration:none;font-weight:bold;border-radius:0">Read more</a>)
    end

    test "section wraps children between leading/trailing hr rules" do
      block = %{
        "id" => "s",
        "type" => "section",
        "title" => "Highlights",
        "blocks" => [
          %{
            "id" => "p",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Body."}]
          }
        ]
      }

      html = Render.render_block(block)
      # Leading + trailing hr from the composed section sub-tree.
      assert html =~ ~s(<hr style="border:none;border-top:1px solid #e5e7eb;margin:16px 0">)
      assert html =~ ~s(<span style="font-weight:bold">Highlights</span>)
      assert html =~ "<span>Body.</span>"
    end

    test "render_blocks concatenates a list in order" do
      blocks = [
        %{"id" => "h", "type" => "heading", "text" => "A"},
        %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "B"}]}
      ]

      assert Render.render_blocks(blocks) ==
               ~s(<span style="font-weight:bold">A</span><span>B</span>)
    end

    # Flat-dialect ProseMirror text nodes carry a `marks` array (e.g.
    # `{"type":"text","value":"x","marks":[{"type":"bold"}]}`). The previous
    # text clause was a one-liner that dropped marks silently — these tests
    # pin the wrap order and tag mapping.
    test "text with a bold mark renders inside a font-weight:bold span" do
      block = %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "hi", "marks" => [%{"type" => "bold"}]}]
      }

      assert Render.render_block(block) ==
               ~s(<span><span style="font-weight:bold">hi</span></span>)
    end

    test "stacked bold + italic marks nest outer→inner in list order" do
      block = %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [
          %{
            "type" => "text",
            "value" => "x",
            "marks" => [%{"type" => "bold"}, %{"type" => "italic"}]
          }
        ]
      }

      # First mark is the outermost wrapper.
      assert Render.render_block(block) ==
               ~s(<span><span style="font-weight:bold"><span style="font-style:italic">x</span></span></span>)
    end

    test "code mark wraps the value as PdInlineCode" do
      block = %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "a&b", "marks" => [%{"type" => "code"}]}]
      }

      assert Render.render_block(block) ==
               ~s(<span><code style="background:#f3f4f6;padding:2px 6px;font-family:ui-monospace,Menlo,monospace;font-size:0.95em">a&amp;b</code></span>)
    end

    test "link mark reads href from attrs and emits a PdLink" do
      block = %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [
          %{
            "type" => "text",
            "value" => "click",
            "marks" => [%{"type" => "link", "attrs" => %{"href" => "https://x.test"}}]
          }
        ]
      }

      assert Render.render_block(block) ==
               ~s(<span><a href="https://x.test" style="color:#1d4ed8;text-decoration:underline">click</a></span>)
    end

    test "unknown marks pass through with no wrapper" do
      block = %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "x", "marks" => [%{"type" => "wat"}]}]
      }

      assert Render.render_block(block) == "<span>x</span>"
    end

    test "empty marks list parity with no-marks (no wrapping)" do
      block = %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "x", "marks" => []}]
      }

      assert Render.render_block(block) == "<span>x</span>"
    end
  end

  # field-reference View resolves the referenced doc's TITLE via the caller's
  # :ref_resolver (Render stays pure — no DB here, a stub fn stands in for
  # Content.reference_title/3). With no resolver it falls back to the raw id;
  # an empty value renders the em-dash placeholder.
  describe "render_block/2 — field-reference title resolution (Polish-1)" do
    @ref_block %{
      "id" => "f-ref",
      "type" => "field-reference",
      "label" => "Author",
      "refType" => "author",
      "value" => "a1"
    }

    test "resolves the referenced doc title when a :ref_resolver is supplied" do
      resolver = fn "a1", "author" -> "Knut Melvaer" end
      html = Render.render_block(@ref_block, %{ref_resolver: resolver})

      assert html =~ "Knut Melvaer"
      assert html =~ ~s(<span style="font-weight:bold">Author</span>)
      refute html =~ ">a1<"
    end

    test "falls back to the raw id when no resolver is supplied" do
      html = Render.render_block(@ref_block)
      assert html =~ "a1"
      refute html =~ "Knut Melvaer"
    end

    test "falls back to the raw id when the resolver can't find the doc" do
      # Content.reference_title/3 returns the value unchanged on a miss.
      resolver = fn value, _ref_type -> value end
      html = Render.render_block(@ref_block, %{ref_resolver: resolver})
      assert html =~ "a1"
    end

    test "renders an em-dash for an empty reference value (resolver never called)" do
      block = Map.put(@ref_block, "value", "")
      resolver = fn _v, _t -> flunk("resolver must not run for an empty value") end
      html = Render.render_block(block, %{ref_resolver: resolver})
      assert html =~ "—"
    end
  end

  describe "field-image v2 JSON values" do
    test "extracts url from asset reference JSON for preview" do
      block = %{
        "type" => "field-image",
        "label" => "Hero",
        "value" =>
          Jason.encode!(%{
            "url" => "/media/files/2026/05/hero.jpg",
            "assetId" => "drafts.asset-abc"
          })
      }

      html = Render.render_block(block, %{})
      assert html =~ ~s(src="/media/files/2026/05/hero.jpg")
      refute html =~ "assetId"
    end
  end

  # Article render mode (P1 slice 1) — an opt-in `:style => :article` palette
  # threaded through render_html / render_block. The DEFAULT (:email) output is
  # byte-unchanged; these cases pin the article divergence and the no-regression
  # guarantee for the email path.
  describe "render mode (:style) — article palette vs email default" do
    test "article mode emits the article palette (accent, serif stack, width 680)" do
      # A PdContainer carries the palette's body font + width budget; a PdButton
      # child carries the accent. Render through the full document so the body
      # background (parchment) is asserted too.
      tree = %{
        "kind" => "PdContainer",
        "children" => [
          %{
            "kind" => "PdButton",
            "href" => "https://x.test",
            "label" => "Go",
            "priority" => "primary"
          }
        ]
      }

      html = Render.render_html(tree, %{style: :article})

      # Accent terracotta is unreachable in the email palette. Article palette
      # now emits it via `var(--paper-accent, #a23925)` so the theme tokens
      # (root.html.heex `.bp-paper-surface`) can flip it for dark mode while
      # the fallback hex stays byte-identical for non-themed surfaces.
      assert html =~ "#a23925"
      # Serif body stack on the article container.
      assert html =~
               "'Iowan Old Style','Palatino Linotype',Palatino,Charter,Georgia,'Source Serif 4',serif"

      # Default article width budget (clamped maxWidth defaults to palette width).
      assert html =~ "max-width:680px"
      # Parchment page background on the doctype body — same hex, now wrapped
      # in `var(--paper-bg-deep, …)` so themed hosts can override.
      assert html =~ ~s|<body style="background:var(--paper-bg-deep, #fbfaf6);|
    end

    test "email/default mode output is unchanged for an existing block" do
      # The Wave 4 expectation for a heading block must still hold byte-for-byte.
      block = %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Title"}
      assert Render.render_block(block) == ~s(<span style="font-weight:bold">Title</span>)

      assert Render.render_block(block, %{style: :email}) ==
               ~s(<span style="font-weight:bold">Title</span>)
    end

    test "heading level 1/2/3 produce distinct article sizes" do
      h = fn level ->
        block = %{"type" => "heading", "level" => level, "text" => "H"}
        Render.render_block(block, %{style: :article})
      end

      assert h.(1) =~ "font-size:32px"
      assert h.(2) =~ "font-size:24px"
      assert h.(3) =~ "font-size:20px"
      # Distinct from one another.
      refute h.(1) =~ "font-size:24px"
      refute h.(2) =~ "font-size:32px"
      # All heading levels now use weight 600 — matches the Edit pane's
      # `.bp-paper-surface h1, h2, h3 { font-weight: 600 }` (root.html.heex
      # ~:2065), so a paper renders identically in View and Edit modes.
      assert h.(1) =~ "font-weight:600"
      assert h.(2) =~ "font-weight:600"
      assert h.(3) =~ "font-weight:600"
      # And the family is now serif throughout (was sans-serif system-ui).
      assert h.(1) =~ "font-family:'Iowan Old Style'"
      assert h.(2) =~ "font-family:'Iowan Old Style'"
    end

    test "eyebrow renders an uppercase accent kicker in article mode" do
      block = %{"type" => "eyebrow", "text" => "Field notes"}
      html = Render.render_block(block, %{style: :article})

      assert html =~ "Field notes"
      assert html =~ "text-transform:uppercase"
      assert html =~ "letter-spacing:0.08em"
      assert html =~ "color:var(--paper-accent, #a23925)"
    end

    test "byline joins items with a separator and carries a bottom rule (article)" do
      block = %{"type" => "byline", "items" => ["Pelle Jarl", "May 2026"]}
      html = Render.render_block(block, %{style: :article})

      assert html =~ "Pelle Jarl · May 2026"
      assert html =~ "border-bottom:1px solid var(--paper-rule, #e6e2d8)"
      assert html =~ "color:var(--paper-ink-soft, #6a6a6a)"
    end

    test "byline accepts a plain text fallback" do
      block = %{"type" => "byline", "text" => "Solo author"}
      html = Render.render_block(block, %{style: :article})
      assert html =~ "Solo author"
    end

    test "ingress renders a heavier, larger lead paragraph in article mode" do
      block = %{
        "type" => "ingress",
        "content" => [%{"type" => "text", "value" => "The lead."}]
      }

      html = Render.render_block(block, %{style: :article})
      assert html =~ "The lead."
      assert html =~ "font-size:1.28rem"
      assert html =~ "font-weight:500"
    end

    test "eyebrow/byline/ingress degrade to plain text in email mode (no article cues)" do
      eyebrow = Render.render_block(%{"type" => "eyebrow", "text" => "Kicker"}, %{style: :email})
      byline = Render.render_block(%{"type" => "byline", "text" => "Author"}, %{style: :email})

      ingress =
        Render.render_block(
          %{"type" => "ingress", "content" => [%{"type" => "text", "value" => "Lead"}]},
          %{style: :email}
        )

      assert eyebrow == "<span>Kicker</span>"
      assert byline == "<span>Author</span>"
      assert ingress == "<span>Lead</span>"
    end
  end

  # diagram / figure blocks (P1 slice 2) — the canonical paper-article Mermaid
  # figure. Article mode emits `<pre class="mermaid">` (the engine's selector)
  # with the source entity-encoded so it round-trips the static extractor and
  # Mermaid decodes it at runtime; email mode degrades (no engine trigger).
  describe "diagram block — Mermaid figure (article) and degraded (email)" do
    @diagram %{
      "id" => "dg1",
      "type" => "diagram",
      "source" => "graph TD\n  A[Start] --> B{x > 0 & y < 1}\n  B --> C",
      "caption" => "Figure 1. The control flow."
    }

    test "article mode emits pre.mermaid with entity-encoded source + figcaption" do
      html = Render.render_block(@diagram, %{style: :article})

      # The engine selects on this exact literal.
      assert html =~ ~s(<pre class="mermaid">)
      # & < > are entity-encoded inside the mermaid source.
      assert html =~ "x &gt; 0 &amp; y &lt; 1"
      # Raw structural chars must NOT survive in the source.
      refute html =~ "x > 0 & y < 1"
      # Bold "Figure N." run-in, remainder plain.
      assert html =~ "<b>Figure 1.</b>"
      assert html =~ "The control flow."
      # Article figure chrome: parchment card.
      assert html =~ "<figure"
      assert html =~ "background:var(--paper-bg-deep, #fbfaf6)"
    end

    test "email/default mode degrades — no pre.mermaid, source as a code block" do
      html = Render.render_block(@diagram, %{style: :email})

      # The Mermaid engine must NOT be triggered in email contexts.
      refute html =~ ~s(<pre class="mermaid">)
      # Source still shown (escaped) so the diagram intent survives in email.
      assert html =~ "graph TD"
      assert html =~ "x &gt; 0 &amp; y &lt; 1"
      # Caption still rendered with the bold run-in.
      assert html =~ "<b>Figure 1.</b>"
    end

    test "diagram with no caption omits the figcaption (article)" do
      block = Map.delete(@diagram, "caption")
      html = Render.render_block(block, %{style: :article})
      assert html =~ ~s(<pre class="mermaid">)
      refute html =~ "<figcaption"
    end

    test "a non-Figure caption renders without a bold run-in" do
      block = Map.put(@diagram, "caption", "Just a label")
      html = Render.render_block(block, %{style: :article})
      assert html =~ "Just a label"
      refute html =~ "<b>"
    end
  end

  # asciicast block — the terminal-recording figure. Article mode emits the
  # `div.bp-asciicast` mount point (the PaperMermaid hook's runAsciicast()
  # selector) with the cast URL in `data-cast-src`; email mode degrades to a
  # plain link (no player runtime triggered).
  describe "asciicast block — player mount (article) and degraded link (email)" do
    @asciicast %{
      "id" => "ac1",
      "type" => "asciicast",
      "src" => "https://asciinema.org/a/123.cast",
      "caption" => "Figure 3. A live terminal session."
    }

    test "article mode emits div.bp-asciicast with data-cast-src + figcaption" do
      html = Render.render_block(@asciicast, %{style: :article})

      # The hook selects on this exact mount-point class.
      assert html =~ ~s(class="bp-asciicast")
      # Cast URL carried in the data attribute (scheme allowlisted + escaped).
      assert html =~ ~s(data-cast-src="https://asciinema.org/a/123.cast")
      # Bold "Figure N." run-in, remainder plain.
      assert html =~ "<b>Figure 3.</b>"
      assert html =~ "A live terminal session."
      # Article figure chrome.
      assert html =~ "<figure"
      # NOT a degraded link in article mode.
      refute html =~ "Terminal recording"
    end

    test "email/default mode degrades — a link, no player mount point" do
      html = Render.render_block(@asciicast, %{style: :email})

      # The player runtime must NOT be triggered in email contexts.
      refute html =~ "bp-asciicast"
      # A plain link to the recording instead.
      assert html =~ ~s(<a href="https://asciinema.org/a/123.cast">Terminal recording</a>)
      # Caption still rendered with the bold run-in.
      assert html =~ "<b>Figure 3.</b>"
    end

    test "asciicast with no caption omits the figcaption (article)" do
      block = Map.delete(@asciicast, "caption")
      html = Render.render_block(block, %{style: :article})
      assert html =~ ~s(class="bp-asciicast")
      refute html =~ "<figcaption"
    end

    test "empty / missing src does not crash (article + email)" do
      block = %{"id" => "ac2", "type" => "asciicast"}
      article = Render.render_block(block, %{style: :article})
      email = Render.render_block(block, %{style: :email})

      # Mount point still emitted; empty src is neutralised to # by safe_url
      # (no scheme, not a leading "/") — never raw and never a crash.
      assert article =~ ~s(class="bp-asciicast")
      assert article =~ ~s(data-cast-src="#")
      assert email =~ "Terminal recording"
    end

    test "a disallowed-scheme src is neutralised to # in the data attribute" do
      block = Map.put(@asciicast, "src", "javascript:alert(1)")
      html = Render.render_block(block, %{style: :article})
      assert html =~ ~s(data-cast-src="#")
      refute html =~ "javascript:alert"
    end
  end

  describe "figure block — generic child + caption" do
    test "article mode wraps a composed child block with a captioned figure" do
      block = %{
        "id" => "fg1",
        "type" => "figure",
        "caption" => "Figure 2. A heading inside.",
        "child" => %{"id" => "h", "type" => "heading", "level" => 2, "text" => "Inner"}
      }

      html = Render.render_block(block, %{style: :article})
      assert html =~ "<figure"
      assert html =~ "Inner"
      assert html =~ "<b>Figure 2.</b>"
      assert html =~ "A heading inside."
    end
  end

  # Article-render fidelity polish (P1 slice 3) — real semantic headings, a
  # single `<pre>` code block, header-row table styling, the pullquote block,
  # and the "§" section divider. Each case pins the article divergence AND the
  # email no-regression guarantee (the email backend depends on byte-identical
  # output).
  describe "article fidelity — semantic headings (follow-up #1)" do
    test "article heading level 1/2/3 emit real <h1>/<h2>/<h3> tags" do
      h = fn level ->
        block = %{"type" => "heading", "level" => level, "text" => "Heading"}
        Render.render_block(block, %{style: :article})
      end

      assert h.(1) =~ ~r/<h1[ >]/
      assert h.(1) =~ "</h1>"
      assert h.(2) =~ ~r/<h2[ >]/
      assert h.(2) =~ "</h2>"
      assert h.(3) =~ ~r/<h3[ >]/
      assert h.(3) =~ "</h3>"

      # The level-sized rule still rides on the tag (sizing preserved).
      assert h.(1) =~ "font-size:32px"
      assert h.(2) =~ "font-size:24px"
      assert h.(3) =~ "font-size:20px"

      # No stray styled <span> heading anymore.
      refute h.(1) =~ "<span"
    end

    test "article heading escapes its text" do
      block = %{"type" => "heading", "level" => 2, "text" => "A < B & C"}
      html = Render.render_block(block, %{style: :article})
      assert html =~ "A &lt; B &amp; C"
    end

    test "an out-of-range level clamps to <h2>" do
      block = %{"type" => "heading", "level" => 9, "text" => "X"}
      assert Render.render_block(block, %{style: :article}) =~ ~r/<h2[ >]/
    end

    test "email heading output is byte-unchanged (regression)" do
      block = %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Title"}
      # Default (email) and explicit :email — both the original bold span.
      assert Render.render_block(block) == ~s(<span style="font-weight:bold">Title</span>)

      assert Render.render_block(block, %{style: :email}) ==
               ~s(<span style="font-weight:bold">Title</span>)

      # Levels 2 and 3 in email are also the plain bold span (no <hN>).
      assert Render.render_block(%{"type" => "heading", "level" => 2, "text" => "T"}, %{
               style: :email
             }) == ~s(<span style="font-weight:bold">T</span>)

      refute Render.render_block(%{"type" => "heading", "level" => 2, "text" => "T"}) =~ "<h2"
    end
  end

  describe "article fidelity — code block as a single <pre>" do
    @code %{"id" => "c1", "type" => "code", "value" => "let x = 1\nif x < 2 & y > 0:"}

    test "article mode renders one styled <pre> block (not per-line chips)" do
      html = Render.render_block(@code, %{style: :article})

      assert html =~ "<pre"
      # Parchment background, terracotta left-border, horizontal scroll —
      # now emitted through `var(--paper-*, hex)` for dark-mode theming.
      assert html =~ "background:var(--paper-bg-deep, #f1ede2)"
      assert html =~ "border-left:3px solid var(--paper-accent, #a23925)"
      assert html =~ "overflow-x:auto"
      # The value is escaped inside the single <pre> (no per-line <code> chips).
      assert html =~ "if x &lt; 2 &amp; y &gt; 0:"
      refute html =~ ~s(<code style="background:#f1ede2)
    end

    test "email mode keeps the per-line inline <code> chip stack (regression)" do
      html = Render.render_block(@code, %{style: :email})
      refute html =~ "<pre"
      # Per-line PdInlineCode chips on the email/default palette bg.
      assert html =~ ~s(<code style="background:#f3f4f6)
    end
  end

  describe "article fidelity — table header styling" do
    # Header-less table (the default emitted by upstream converters that
    # don't distinguish <th> from <td>). All rows are body rows; nothing is
    # auto-promoted to <thead>.
    @table %{
      "id" => "t1",
      "type" => "table",
      "rows" => [
        [[%{"type" => "text", "value" => "Name"}], [%{"type" => "text", "value" => "Role"}]],
        [[%{"type" => "text", "value" => "Pelle"}], [%{"type" => "text", "value" => "Author"}]]
      ]
    }

    # Opt-in header — the producer supplies an explicit `head` row separate
    # from `rows`; the article walker then emits a <thead>/<th> band and
    # keeps EVERY entry in `rows` as a body row.
    @table_with_head %{
      "id" => "t2",
      "type" => "table",
      "head" => [
        [%{"type" => "text", "value" => "Name"}],
        [%{"type" => "text", "value" => "Role"}]
      ],
      "rows" => [
        [[%{"type" => "text", "value" => "Pelle"}], [%{"type" => "text", "value" => "Author"}]]
      ]
    }

    test "article mode renders all rows as body when no head is supplied" do
      html = Render.render_block(@table, %{style: :article})

      # No header band — every supplied row becomes a body <tr>.
      refute html =~ "<thead>"
      refute html =~ "<th "
      # Both rows survive (regression — the old auto-promote dropped row 0
      # into <thead> which broke any data table without an explicit header).
      assert html =~ "Name"
      assert html =~ "Role"
      assert html =~ "Pelle"
      assert html =~ "Author"
      # Body cells use the warm rule colour (var-wrapped for dark-mode flip).
      assert html =~ "border-bottom:1px solid var(--paper-rule, #e6e2d8)"
      refute html =~ "#e5e7eb"
    end

    test "article mode emits a <thead>/<th> band when an explicit head row is supplied" do
      html = Render.render_block(@table_with_head, %{style: :article})

      assert html =~ "<thead>"
      assert html =~ "<th "
      # Uppercase, muted, 2px bottom rule under the header.
      assert html =~ "text-transform:uppercase"
      assert html =~ "border-bottom:2px solid var(--paper-rule, #e6e2d8)"
      assert html =~ "color:var(--paper-ink-soft, #6a6a6a)"
      # Body still renders.
      assert html =~ "border-bottom:1px solid var(--paper-rule, #e6e2d8)"
      assert html =~ "Name"
      assert html =~ "Pelle"
    end

    test "article mode tolerates scalar (plain-string) cells" do
      block = %{
        "id" => "t3",
        "type" => "table",
        "rows" => [["plain", "string"]]
      }

      html = Render.render_block(block, %{style: :article})

      assert html =~ "plain"
      assert html =~ "string"
      # And the cells render as <td>, not as empty cells.
      assert html =~ ~s(<td)
    end

    test "email mode keeps the flat <td>-only gray table (regression)" do
      html = Render.render_block(@table, %{style: :email})
      refute html =~ "<thead>"
      refute html =~ "<th "
      assert html =~ ~s(<td style="border:1px solid #e5e7eb)
    end
  end

  describe "article fidelity — pullquote block" do
    @pull %{
      "id" => "pq1",
      "type" => "pullquote",
      "content" => [%{"type" => "text", "value" => "The medium is the message."}]
    }

    test "article mode renders an italic, bordered, muted pullquote" do
      html = Render.render_block(@pull, %{style: :article})

      assert html =~ "The medium is the message."
      assert html =~ "font-style:italic"
      assert html =~ "border-left:3px solid var(--paper-accent, #a23925)"
      assert html =~ "color:var(--paper-ink-soft, #6a6a6a)"
      assert html =~ "font-size:1.2rem"
    end

    test "email mode degrades to a plain italic span (no border cues)" do
      html = Render.render_block(@pull, %{style: :email})
      assert html =~ "The medium is the message."
      assert html =~ "font-style:italic"
      refute html =~ "border-left:3px solid"
    end
  end

  describe "article fidelity — § section divider" do
    @divider %{"id" => "d1", "type" => "divider"}

    test "article mode renders the § glyph straddling a hairline rule" do
      html = Render.render_block(@divider, %{style: :article})
      assert html =~ "§"
      assert html =~ "border-top:1px solid var(--paper-rule, #e6e2d8)"
      refute html =~ "<hr"
    end

    test "email mode keeps a plain <hr> (regression)" do
      html = Render.render_block(@divider, %{style: :email})

      assert html ==
               ~s(<hr style="border:none;border-top:1px solid #e5e7eb;margin:16px 0">)

      refute html =~ "§"
    end
  end

  # form block (P4) — native portable-doc render of a grill /
  # questionnaire. Render-only: clean semantic <fieldset>/<legend>/<input>/
  # <textarea> markup, NO <script>, NO action/method, NO submit wiring (the
  # interactive layer is a later phase). Mirrors grill.js input types
  # (yesno/single/multi/scale/text). The whole-block container carries a
  # bp-form class; the kind discriminator picks bp-form-grill vs
  # bp-form-questionnaire. All user text flows through escape_html.
  describe "form block — grill / questionnaire render (P4)" do
    @grill %{
      "id" => "fm1",
      "type" => "form",
      "kind" => "grill",
      "questions" => [
        %{
          "id" => "q1",
          "prompt" => "Ship it?",
          "type" => "yesno",
          "rationale" => "Gauges confidence.",
          "recommendation" => "Ship."
        },
        %{
          "id" => "q2",
          "prompt" => "Pick a colour",
          "type" => "single",
          "options" => ["Red", "Green", "Blue"]
        },
        %{
          "id" => "q3",
          "prompt" => "Pick toppings",
          "type" => "multi",
          "options" => ["Cheese", "Ham"]
        },
        %{"id" => "q4", "prompt" => "Rate it", "type" => "scale"},
        %{"id" => "q5", "prompt" => "Anything else?", "type" => "text"}
      ]
    }

    test "wraps the block in a bp-form / bp-form-grill container section" do
      html = Render.render_block(@grill, %{style: :article})
      assert html =~ "<section"
      assert html =~ "bp-form"
      assert html =~ "bp-form-grill"
    end

    test "a questionnaire kind carries the bp-form-questionnaire hook" do
      block = Map.put(@grill, "kind", "questionnaire")
      html = Render.render_block(block, %{style: :article})
      assert html =~ "bp-form-questionnaire"
      refute html =~ "bp-form-grill"
    end

    test "kind defaults to grill when absent" do
      block = Map.delete(@grill, "kind")
      html = Render.render_block(block, %{style: :article})
      assert html =~ "bp-form-grill"
    end

    test "each question is a <fieldset> with an escaped <legend> prompt" do
      block = %{
        "type" => "form",
        "questions" => [%{"id" => "q", "prompt" => "A < B & C?", "type" => "text"}]
      }

      html = Render.render_block(block, %{style: :article})
      assert html =~ "<fieldset"
      assert html =~ "<legend"
      # The prompt is HTML-escaped, never raw.
      assert html =~ "A &lt; B &amp; C?"
      refute html =~ "A < B & C?"
    end

    test "rationale and recommendation render as muted lines when present" do
      html = Render.render_block(@grill, %{style: :article})
      assert html =~ "Gauges confidence."
      assert html =~ "Recommendation:"
      assert html =~ "Ship."
    end

    test "rationale / recommendation are omitted when absent" do
      block = %{
        "type" => "form",
        "questions" => [%{"id" => "q", "prompt" => "Bare?", "type" => "text"}]
      }

      html = Render.render_block(block, %{style: :article})
      refute html =~ "Recommendation:"
    end

    test "yesno emits two radios (Yes / No) sharing name = the question id" do
      html = Render.render_block(@grill, %{style: :article})
      assert html =~ ~s(type="radio")
      assert html =~ ~s(name="q1")
      assert html =~ "Yes"
      assert html =~ "No"
    end

    test "single emits one radio per option, sharing name = id, with labels" do
      html = Render.render_block(@grill, %{style: :article})
      assert html =~ ~s(name="q2")
      assert html =~ "Red"
      assert html =~ "Green"
      assert html =~ "Blue"
      # Three radios for q2 share the same name.
      assert length(Regex.scan(~r/name="q2"/, html)) == 3
    end

    test "multi emits one checkbox per option, name = id" do
      html = Render.render_block(@grill, %{style: :article})
      assert html =~ ~s(type="checkbox")
      assert html =~ ~s(name="q3")
      assert html =~ "Cheese"
      assert html =~ "Ham"
      assert length(Regex.scan(~r/name="q3"/, html)) == 2
    end

    test "scale defaults to radios 1..5 sharing name = id" do
      html = Render.render_block(@grill, %{style: :article})
      assert html =~ ~s(name="q4")
      # Five integer radios 1..5.
      assert length(Regex.scan(~r/name="q4"/, html)) == 5
      assert html =~ ">1<"
      assert html =~ ">5<"
    end

    test "scale honours an explicit min/max range" do
      block = %{
        "type" => "form",
        "questions" => [
          %{
            "id" => "s",
            "prompt" => "Rate",
            "type" => "scale",
            "scale" => %{"min" => 0, "max" => 2}
          }
        ]
      }

      html = Render.render_block(block, %{style: :article})
      # 0, 1, 2 → three radios.
      assert length(Regex.scan(~r/name="s"/, html)) == 3
      assert html =~ ">0<"
      assert html =~ ">2<"
    end

    test "text emits a <textarea> named for the question id" do
      html = Render.render_block(@grill, %{style: :article})
      assert html =~ "<textarea"
      assert html =~ ~s(name="q5")
    end

    test "render-only: NO script / action / method / submit wiring" do
      html = Render.render_block(@grill, %{style: :article})
      refute html =~ "<script"
      refute html =~ "action="
      refute html =~ "method="
      refute html =~ "type=\"submit\""
      refute html =~ "<button"
    end

    test "an empty / absent questions list renders a bare bp-form section (no crash)" do
      empty = %{"type" => "form", "questions" => []}
      absent = %{"type" => "form"}

      html_empty = Render.render_block(empty, %{style: :article})
      html_absent = Render.render_block(absent, %{style: :article})

      assert html_empty =~ "bp-form"
      refute html_empty =~ "<fieldset"
      assert html_absent =~ "bp-form"
      refute html_absent =~ "<fieldset"
    end

    test "questionnaire is a true alias of form (same fieldset machinery)" do
      block = %{
        "type" => "questionnaire",
        "questions" => [%{"id" => "q", "prompt" => "Scope?", "type" => "text"}]
      }

      html = Render.render_block(block, %{style: :article})
      assert html =~ "bp-form-questionnaire"
      assert html =~ "<fieldset"
      assert html =~ ~s(name="q")
      assert html =~ "<textarea"
    end

    test "email mode is deterministic and still semantic (plainer)" do
      html = Render.render_block(@grill, %{style: :email})
      assert html =~ "<section"
      assert html =~ "bp-form"
      assert html =~ "<fieldset"
      assert html =~ ~s(name="q1")
      assert html =~ "<textarea"
      refute html =~ "<script"
    end
  end

  # Regression discipline (P4): adding the form clause must not perturb the
  # email-default output of any existing block. Pin one simple block
  # byte-for-byte — the divider in email mode — exactly as it was before.
  describe "regression — existing block email output byte-unchanged (P4)" do
    test "divider email output is byte-identical" do
      assert Render.render_block(%{"id" => "d", "type" => "divider"}) ==
               ~s(<hr style="border:none;border-top:1px solid #e5e7eb;margin:16px 0">)
    end

    test "bold heading email output is byte-identical" do
      block = %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Title"}
      assert Render.render_block(block) == ~s(<span style="font-weight:bold">Title</span>)
    end
  end

  describe "safe_url/1 — scheme allowlist" do
    test "allows http/https/mailto/tel case-insensitively" do
      assert Render.safe_url("http://a.test") == "http://a.test"
      assert Render.safe_url("HTTPS://a.test") == "HTTPS://a.test"
      assert Render.safe_url("mailto:x@y.test") == "mailto:x@y.test"
      assert Render.safe_url("TEL:+123") == "TEL:+123"
    end

    test "collapses a non-allowlisted scheme to #" do
      assert Render.safe_url("javascript:alert(1)") == "#"
      assert Render.safe_url("data:text/html,<script>") == "#"
      assert Render.safe_url("\tjavascript:alert(1)") == "#"
    end

    test "allows same-origin root-relative paths" do
      assert Render.safe_url("/media/files/2026/05/hero.jpg") ==
               "/media/files/2026/05/hero.jpg"
    end
  end

  # Article mode emits semantic <ul>/<ol>/<li> via PdList/PdListItem so the
  # rendered paper is real HTML lists (a11y, copy-paste, native indentation).
  # Email mode keeps the byte-stable flex-row scaffold with literal "• " /
  # "1. " prefix spans — Outlook strips <ul> padding, and that scaffold is
  # the historical Outlook-safe target.
  describe "render_block/2 — list" do
    @list_items [
      [%{"type" => "text", "value" => "a"}],
      [%{"type" => "text", "value" => "b"}],
      [%{"type" => "text", "value" => "c"}]
    ]

    test "unordered article emits <ul>/<li>, no flex scaffold, no bullet prefix" do
      block = %{"id" => "L", "type" => "list", "items" => @list_items}
      html = Render.render_block(block, %{style: :article})

      assert html =~ "<ul"
      # All three items make it through as semantic <li>.
      assert html |> String.split("<li") |> length() == 4
      assert html =~ "<span>a</span>"
      assert html =~ "<span>b</span>"
      assert html =~ "<span>c</span>"
      # No prefix-as-text scaffold leaks into the article output.
      refute html =~ "• "
      refute html =~ "flex-direction"
    end

    test "ordered article emits <ol> with no numeric prefix literal" do
      block = %{
        "id" => "L",
        "type" => "list",
        "ordered" => true,
        "items" => @list_items
      }

      html = Render.render_block(block, %{style: :article})

      assert html =~ "<ol"
      assert html |> String.split("<li") |> length() == 4
      # The browser draws the marker — we must NOT also stamp "1. ".
      refute html =~ "1. "
      refute html =~ "2. "
      refute html =~ "flex-direction"
    end

    test "email/default mode is byte-unchanged (frozen prefix scaffold)" do
      block = %{"id" => "L", "type" => "list", "items" => @list_items}

      expected =
        ~s(<div style="display:flex;flex-direction:column">) <>
          ~s(<div style="display:flex;flex-direction:row"><span>• </span><span>a</span></div>) <>
          ~s(<div style="display:flex;flex-direction:row"><span>• </span><span>b</span></div>) <>
          ~s(<div style="display:flex;flex-direction:row"><span>• </span><span>c</span></div>) <>
          ~s(</div>)

      assert Render.render_block(block) == expected
      assert Render.render_block(block, %{style: :email}) == expected
    end

    test "empty items: <ul></ul> in article, empty flex-column div in email" do
      empty = %{"id" => "L", "type" => "list", "items" => []}

      article = Render.render_block(empty, %{style: :article})
      assert article =~ "<ul"
      assert String.ends_with?(article, "></ul>")
      refute article =~ "<li"

      assert Render.render_block(empty) ==
               ~s(<div style="display:flex;flex-direction:column"></div>)
    end

    test "inline marks (bold) inside an item survive inside <li> in article mode" do
      block = %{
        "id" => "L",
        "type" => "list",
        "items" => [
          [%{"type" => "text", "value" => "loud", "marks" => [%{"type" => "bold"}]}]
        ]
      }

      html = Render.render_block(block, %{style: :article})

      assert html =~ "<li"
      assert html =~ ~s(<span style="font-weight:bold">loud</span>)
    end
  end
end
