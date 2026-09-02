defmodule Barkpark.PortableDoc.RenderTest do
  # Pure, in-process port of the portable-doc static render walker — no DB.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  describe "body_html_render_version/0 — source digest" do
    test "is a sha256 hex digest, not a hand-typed literal" do
      # It succeeded a hand-bumped integer (v1→v3) that went four renderer
      # rounds without a bump. Derived from source, the stamp cannot lag.
      version = Render.body_html_render_version()

      assert is_binary(version)
      assert String.match?(version, ~r/\A[0-9a-f]{64}\z/)
    end

    test "recomputing the digest from the covered files on disk reproduces it" do
      # The independent recomputation below is what makes the next test's
      # covered-set assertion load-bearing rather than decorative: if the
      # module hashed a different set, or in a different order, these diverge.
      recomputed =
        [Render.render_source_names(), Render.render_source_files()]
        |> Enum.zip_reduce(:crypto.hash_init(:sha256), fn [name, path], acc ->
          :crypto.hash_update(acc, name <> "\0" <> File.read!(path))
        end)
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      assert recomputed == Render.body_html_render_version()
    end

    test "the covered set is exactly render.ex + slots.ex + every render/*.ex" do
      # A newly added render/*.ex that nobody lists would fall silently outside
      # the digest, and every paper it changed would go stale behind a matching
      # stamp — the exact failure this digest exists to make unreachable. This
      # assertion is the tripwire: adding a renderer file reds it here.
      covered = Render.render_source_names()

      assert covered == Enum.sort(covered), "the digest must hash in sorted order"

      assert covered ==
               Enum.sort(~w(
                   render.ex slots.ex
                   render/cards_email.ex render/components.ex render/compose.ex
                   render/data_viz.ex render/figures.ex render/fleet_email.ex
                   render/forms.ex render/inline.ex render/math.ex render/palettes.ex
                   render/panels_email.ex render/status_vocab.ex render/stylesheet.ex
                   render/tokens_gen.ex render/util.ex render/walk.ex
                 ))

      # …and the list must still match what is actually on disk.
      render_dir = Path.join(__DIR__, "../../../lib/barkpark/portable_doc/render")
      on_disk = render_dir |> Path.join("*.ex") |> Path.wildcard() |> Enum.map(&Path.basename/1)

      assert on_disk != [], "expected to find the render/ source directory"

      assert Enum.sort(on_disk) ==
               covered
               |> Enum.filter(&String.starts_with?(&1, "render/"))
               |> Enum.map(&Path.basename/1)
               |> Enum.sort()
    end

    test "every covered path exists and contributes bytes" do
      for path <- Render.render_source_files() do
        assert File.exists?(path), "covered file missing: #{path}"
        assert File.read!(path) != "", "covered file is empty: #{path}"
      end
    end
  end

  describe "render_html/2 doctype wrapping" do
    test "wraps the body in a full document by default" do
      html = Render.render_html(%{"kind" => "PdHr"})
      assert String.starts_with?(html, "<!doctype html><html><head>")
      assert String.contains?(html, ~s(<body style="background:#eaf1ee;margin:0;padding:0;">))
      assert String.ends_with?(html, "</body></html>")
    end

    test "emits only the body fragment when doctype: false" do
      html = Render.render_html(%{"kind" => "PdHr"}, %{doctype: false})
      assert html == ~s(<hr style="border:none;border-top:1px solid #dde7e2;margin:30px 0 26px">)
    end
  end

  describe "walk/2 — one expected fragment per kind" do
    @opts %{doctype: false}

    test "PdContainer clamps width with min(maxWidth, width)" do
      node = %{"kind" => "PdContainer", "maxWidth" => 400, "children" => []}
      # default width 600, maxWidth 400 → clamps to 400
      assert Render.render_html(node, @opts) ==
               ~s(<div style="max-width:400px;margin:0 auto;padding:24px;font-family:'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif;color:#15211d;background:#ffffff"></div>)
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
                 ~s(<code style="background:#eaf1ee;padding:1px 5px;border-radius:4px;font-family:ui-monospace,Menlo,monospace;font-size:0.88em">x</code></span>)
    end

    test "PdLink escapes string children and uses safe href" do
      node = %{
        "kind" => "PdLink",
        "href" => "https://example.com",
        "children" => ["click <here>"]
      }

      assert Render.render_html(node, @opts) ==
               ~s(<a href="https://example.com" style="color:#1e5347;text-decoration:underline">click &lt;here&gt;</a>)
    end

    test "PdInlineCode escapes its value" do
      node = %{"kind" => "PdInlineCode", "value" => "a & b"}

      assert Render.render_html(node, @opts) ==
               ~s(<code style="background:#eaf1ee;padding:1px 5px;border-radius:4px;font-family:ui-monospace,Menlo,monospace;font-size:0.88em">a &amp; b</code>)
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

    test "text leaf keyed by legacy `text` renders its prose — canonical `value` wins" do
      # 2026-08-23: raw mutate writers persisted whole papers whose text leaves
      # were keyed {"type":"text","text":…}. Hollow's @text_keys blesses BOTH
      # spellings as content, so those papers passed every write seam — and then
      # rendered as 22–34 headings with ZERO visible characters (text_sha256 of
      # the empty string). The leaf must dual-read value || legacy text, in
      # parity with the Go twin's attrStrFirst(n, "value", "text").
      assert Render.Inline.compose_inline(%{"type" => "text", "text" => "legacy prose"}, false) ==
               "legacy prose"

      assert Render.Inline.compose_inline(
               %{"type" => "text", "value" => "canonical", "text" => "stale"},
               false
             ) == "canonical"

      # Marks still wrap the fallback-read prose.
      marked =
        Render.Inline.compose_inline(
          %{"type" => "text", "text" => "bold legacy", "marks" => [%{"type" => "strong"}]},
          false
        )

      assert Render.render_html(marked, @opts) =~ "bold legacy"

      # A junk legacy key degrades to "" exactly like a junk canonical value.
      assert Render.Inline.compose_inline(%{"type" => "text", "text" => %{"x" => 1}}, false) == ""
    end

    test "wikilink / blockref / tag inline nodes compose + render (no raise, graceful)" do
      # Internal-link infra: compose_inline must produce PdWikilink/PdBlockref/
      # PdTag (NOT fall through to the unknown-type catch-all in
      # `Inline.compose_inline/2` or `Walk`'s unknown-kind clause, which now
      # DEGRADE rather than raise), and the
      # walk degrades gracefully on an UNRESOLVED target (raw label/anchor/name).
      wikilink =
        Render.Inline.compose_inline(
          %{
            "type" => "wikilink",
            "target" => "intro",
            "children" => [%{"type" => "text", "value" => "intro"}]
          },
          false
        )

      assert Render.render_html(wikilink, @opts) =~ ~s(data-wikilink="intro")

      blockref =
        Render.Inline.compose_inline(
          %{"type" => "blockref", "target" => "doc-7", "anchor" => "abc"},
          false
        )

      assert Render.render_html(blockref, @opts) =~ "^abc"

      tag = Render.Inline.compose_inline(%{"type" => "tag", "name" => "epic"}, false)
      assert Render.render_html(tag, @opts) =~ "#epic"
    end

    test "wikilink renders <a href> when the target resolves, dotted span otherwise" do
      node =
        Render.Inline.compose_inline(
          %{
            "type" => "wikilink",
            "target" => "Intro to X",
            "children" => [%{"type" => "text", "value" => "the intro"}]
          },
          false
        )

      # No :wikilinks map → unresolved → the dotted span.
      unresolved = Render.render_html(node, @opts)
      assert unresolved =~ ~s(<span data-wikilink="Intro to X")
      assert unresolved =~ "underline dotted"
      refute unresolved =~ "<a href"

      # Caller passes a resolved map → a navigable <a href="/papers/<id>">.
      resolved =
        Render.render_html(node, Map.put(@opts, :wikilinks, %{"Intro to X" => %{id: "p-intro"}}))

      assert resolved =~ ~s(<a href="/papers/p-intro")
      assert resolved =~ ~s(data-wikilink="Intro to X")
      assert resolved =~ "the intro"
      refute resolved =~ "underline dotted"
    end

    test "blockref renders <a href> with #anchor when the target resolves, span otherwise" do
      node =
        Render.Inline.compose_inline(
          %{"type" => "blockref", "target" => "Design Doc", "anchor" => "b-42"},
          false
        )

      unresolved = Render.render_html(node, @opts)
      assert unresolved =~ ~s(<span data-blockref="Design Doc")
      assert unresolved =~ "^b-42"
      refute unresolved =~ "<a href"

      resolved =
        Render.render_html(node, Map.put(@opts, :wikilinks, %{"Design Doc" => %{id: "p-design"}}))

      assert resolved =~ ~s(<a href="/papers/p-design#b-42")
      assert resolved =~ ~s(data-blockref="Design Doc")
      assert resolved =~ "^b-42"
    end

    test "an empty :wikilinks map is byte-identical to no map (opt-in regression guard)" do
      node =
        Render.Inline.compose_inline(
          %{
            "type" => "wikilink",
            "target" => "intro",
            "children" => [%{"type" => "text", "value" => "intro"}]
          },
          false
        )

      assert Render.render_html(node, @opts) ==
               Render.render_html(node, Map.put(@opts, :wikilinks, %{}))
    end

    test "collapsible callout renders <details> in article, expanded <div> in email" do
      block = %{
        "id" => "c1",
        "type" => "callout",
        "tone" => "warning",
        "title" => "Heads up",
        "collapsible" => true,
        "content" => [%{"type" => "text", "value" => "body text"}]
      }

      article = Render.render_blocks([block], %{style: :article})
      assert article =~ "<details"
      assert article =~ "Heads up"
      assert article =~ "body text"

      # Email shares walk.ex callout/3 — it MUST stay an expanded <div>, never
      # <details> (Gmail/Outlook strip <details> and hide the body).
      email = Render.render_blocks([block], %{style: :email})
      refute email =~ "<details"
      assert email =~ "body text"
    end

    test "callout collapsed omits open attr; expanded keeps it" do
      mk = fn collapsed ->
        %{
          "id" => "c",
          "type" => "callout",
          "tone" => "info",
          "collapsible" => true,
          "collapsed" => collapsed,
          "content" => [%{"type" => "text", "value" => "x"}]
        }
      end

      assert Render.render_blocks([mk.(false)], %{style: :article}) =~ "<details open"
      refute Render.render_blocks([mk.(true)], %{style: :article}) =~ "<details open"
    end

    test "non-collapsible callout is byte-identical (no <details>, no collapsible leak)" do
      block = %{
        "id" => "c2",
        "type" => "callout",
        "tone" => "info",
        "content" => [%{"type" => "text", "value" => "plain"}]
      }

      html = Render.render_blocks([block], %{style: :article})
      refute html =~ "<details"
      # Stage 2 wave 2: the tone card is class-driven (`.bp-paper-surface`
      # `.bp-callout.bp-callout--info` owns the tone tokens); no inline border.
      assert html =~ ~s(<div class="bp-callout bp-callout--info">)
      refute html =~ "border-left:4px solid"
    end

    test "article callout tone → modifier class, unknown falls back to info (mirrors Util.tone_palette/1)" do
      mk = fn tone, extra ->
        Map.merge(
          %{
            "id" => "t",
            "type" => "callout",
            "tone" => tone,
            "content" => [%{"type" => "text", "value" => "x"}]
          },
          extra
        )
      end

      # Each known tone maps to its own modifier — the class IS the tone now,
      # so a mis-mapped clause would silently paint the wrong tone tokens.
      for tone <- ["success", "warning", "danger", "neutral", "info"] do
        html = Render.render_blocks([mk.(tone, %{})], %{style: :article})

        assert html =~ ~s(<div class="bp-callout bp-callout--#{tone}">),
               "tone #{inspect(tone)} did not map to its own modifier class"
      end

      # Unknown (and absent) tones fall back to info, exactly like
      # Util.tone_palette/1's catch-all — never an unstyled `bp-callout--`.
      for tone <- ["sparkle", nil] do
        html = Render.render_blocks([mk.(tone, %{})], %{style: :article})
        assert html =~ ~s(<div class="bp-callout bp-callout--info">)
      end

      # The collapsible article form carries the same tone card classes plus
      # the summary/body chrome hooks (all resolved by paper-surface.css).
      html =
        Render.render_blocks(
          [mk.("warning", %{"collapsible" => true, "title" => "Heads up"})],
          %{style: :article}
        )

      assert html =~ ~s(<details open class="bp-callout bp-callout--warning">)
      assert html =~ ~s(<summary class="bp-callout__summary">Heads up</summary>)
      assert html =~ ~s(<div class="bp-callout__body">)
    end

    test "PdButton primary uses brand background" do
      node = %{
        "kind" => "PdButton",
        "href" => "https://x.test",
        "label" => "Go",
        "priority" => "primary"
      }

      assert Render.render_html(node, @opts) ==
               ~s(<a href="https://x.test" style="display:inline-block;padding:10px 20px;background:#1e5347;color:#ffffff;text-decoration:none;font-weight:bold;border-radius:0">Go</a>)
    end

    test "PdButton secondary uses brand border" do
      node = %{
        "kind" => "PdButton",
        "href" => "https://x.test",
        "label" => "Go",
        "priority" => "secondary"
      }

      assert Render.render_html(node, @opts) ==
               ~s(<a href="https://x.test" style="display:inline-block;padding:10px 20px;border:2px solid #1e5347;color:#1e5347;text-decoration:none;font-weight:bold;border-radius:0">Go</a>)
    end

    test "PdHr respects thickness, defaults to 1" do
      assert Render.render_html(%{"kind" => "PdHr", "thickness" => 2}, @opts) ==
               ~s(<hr style="border:none;border-top:2px solid #dde7e2;margin:30px 0 26px">)
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
               ~s(<table role="presentation" style="border-collapse:collapse;width:100%;margin:18px 0"><tbody>) <>
                 ~s(<tr><td style="border-bottom:1px solid #dde7e2;padding:10px 12px;vertical-align:top"><span>A</span></td>) <>
                 ~s(<td style="border-bottom:1px solid #dde7e2;padding:10px 12px;vertical-align:top"><span>B</span></td></tr>) <>
                 ~s(</tbody></table>)
    end

    test "PdCallout uses tone palette and optional title" do
      node = %{
        "kind" => "PdCallout",
        "tone" => "warning",
        "title" => "Heads up",
        "children" => [%{"kind" => "PdText", "children" => ["body"]}]
      }

      assert Render.render_html(node, @opts) ==
               ~s(<div style="border-left:3px solid #8a6420;background:#f7f0df;padding:14px 18px;border-radius:0 8px 8px 0;color:#15211d;margin:20px 0"><div style="color:#8a6420;font-weight:600;margin:0 0 6px">Heads up</div><span>body</span></div>)
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

      assert Render.render_block(block) ==
               ~s(<h1 style="font-family:'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif;color:#15211d;letter-spacing:-0.02em;line-height:1.15;margin:0 0 12px;font-weight:600;font-size:32px">Title</h1>)
    end

    test "paragraph with plain text composes to a span" do
      block = %{
        "id" => "p1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Hello"}]
      }

      assert Render.render_block(block) == email_p("Hello")
    end

    test "divider composes to an hr" do
      assert Render.render_block(%{"id" => "d", "type" => "divider"}) ==
               ~s(<hr style="border:none;border-top:1px solid #dde7e2;margin:30px 0 26px">)
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
               ~s(<div style="border-left:3px solid #8a6420;background:#f7f0df;padding:14px 18px;border-radius:0 8px 8px 0;color:#15211d;margin:20px 0">) <>
                 ~s(<div style="color:#8a6420;font-weight:600;margin:0 0 6px">Degraded</div><span>API latency is elevated.</span></div>)
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
               ~s(<a href="https://example.com/notes" style="display:inline-block;padding:10px 20px;background:#1e5347;color:#ffffff;text-decoration:none;font-weight:bold;border-radius:0">Read more</a>)
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
      assert html =~ ~s(<hr style="border:none;border-top:1px solid #dde7e2;margin:30px 0 26px">)
      assert html =~ ~s(<span style="font-weight:bold">Highlights</span>)
      assert html =~ email_p("Body.")
    end

    test "render_blocks concatenates a list in order" do
      blocks = [
        %{"id" => "h", "type" => "heading", "text" => "A"},
        %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "B"}]}
      ]

      assert Render.render_blocks(blocks) ==
               ~s(<h2 style="font-family:'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif;color:#15211d;line-height:1.25;margin:30px 0 10px;font-weight:600;font-size:24px">A</h2>) <>
                 email_p("B")
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
               email_p(~s(<span style="font-weight:bold">hi</span>))
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
               email_p(
                 ~s(<span style="font-weight:bold"><span style="font-style:italic">x</span></span>)
               )
    end

    test "code mark wraps the value as PdInlineCode" do
      block = %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "a&b", "marks" => [%{"type" => "code"}]}]
      }

      assert Render.render_block(block) ==
               email_p(
                 ~s(<code style="background:#eaf1ee;padding:1px 5px;border-radius:4px;font-family:ui-monospace,Menlo,monospace;font-size:0.88em">a&amp;b</code>)
               )
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
               email_p(
                 ~s(<a href="https://x.test" style="color:#1e5347;text-decoration:underline">click</a>)
               )
    end

    test "unknown marks pass through with no wrapper" do
      block = %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "x", "marks" => [%{"type" => "wat"}]}]
      }

      assert Render.render_block(block) == email_p("x")
    end

    test "empty marks list parity with no-marks (no wrapping)" do
      block = %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "x", "marks" => []}]
      }

      assert Render.render_block(block) == email_p("x")
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

  # Doctrine rule 3 + t13 (featured-image placeholder): a locked `role: "featured"`
  # image block seeded with NO asset (post-#1161 template) is editor scaffolding — it
  # must render NOTHING on the public /papers surface, never a broken empty <img>. An
  # image WITH a real src stays byte-identical (D3 additive).
  describe "render_block/1 — asset-less image is skipped on the public render (t13)" do
    test "an image block with no src composes to empty output" do
      assert Render.render_block(%{"id" => "f", "type" => "image", "role" => "featured"}) == ""
    end

    test "an image block with an empty-string src composes to empty output" do
      assert Render.render_block(%{"id" => "f", "type" => "image", "src" => ""}) == ""
    end

    test "an image block with a whitespace-only src composes to empty output" do
      assert Render.render_block(%{"id" => "f", "type" => "image", "src" => "   "}) == ""
    end

    test "a skipped image does not break the walker mid-list — neighbours still render" do
      blocks = [
        %{"id" => "h", "type" => "heading", "text" => "A"},
        %{"id" => "f", "type" => "image", "role" => "featured"},
        %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "B"}]}
      ]

      # The asset-less image contributes nothing; the heading + paragraph render in
      # order with no empty <img> between them.
      assert Render.render_blocks(blocks) ==
               ~s(<h2 style="font-family:'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif;color:#15211d;line-height:1.25;margin:30px 0 10px;font-weight:600;font-size:24px">A</h2>) <>
                 email_p("B")

      refute Render.render_blocks(blocks) =~ "<img"
    end

    test "D3: an image WITH a src is byte-unchanged (renders its <img> exactly as before)" do
      block = %{
        "id" => "i",
        "type" => "image",
        "src" => "https://img.test/a.png",
        "alt" => "A pic",
        "width" => 100,
        "height" => 50
      }

      assert Render.render_block(block) ==
               ~s(<img src="https://img.test/a.png" alt="A pic" style="max-width:100%;height:auto" width="100" height="50">)
    end

    test "D3: a locked featured image gains its src → renders normally (the bound state)" do
      block = %{
        "id" => "tpl-featured",
        "type" => "image",
        "role" => "featured",
        "locked" => true,
        "src" => "/media/files/2026/07/hero.jpg",
        "alt" => "Hero"
      }

      assert Render.render_block(block) ==
               ~s(<img src="/media/files/2026/07/hero.jpg" alt="Hero" style="max-width:100%;height:auto">)
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

      # Wave 2 slice 6: :article render_html is now a self-contained export — the
      # canonical paper-surface stylesheet is embedded in <head>, so the accent
      # token (`--paper-accent: #1e5347`) and the serif stack legitimately live in
      # that <style> block (covered by the ":article document wrapper" describe).
      # These guards are about the BODY carrying no INLINE theme, so scope to it.
      body = html |> String.split("</head>", parts: 2) |> List.last()

      # Stage 2 wave 2: the PdButton child is now CLASS-driven — the accent fill
      # lives in `.bp-paper-surface .bp-button--primary` (single-sourced from
      # `var(--paper-accent)`), so no accent hex rides the button inline anymore.
      assert body =~ ~s(class="bp-button bp-button--primary")
      refute body =~ "#1e5347"
      # Stage 2: the article container is bare of ink/bg/font — the
      # `.bp-paper-surface` root owns the serif family (single-sourced from
      # `--paper-font-serif`). No serif stack rides the container inline anymore.
      refute body =~
               "'Iowan Old Style','Palatino Linotype',Palatino,Charter,Georgia,'Source Serif 4',serif"

      # Default article width budget stays inline — maxWidth is author DATA
      # (clamped maxWidth defaults to the palette width).
      assert html =~ "max-width:680px"
      # …and the container carries ONLY geometry now (no colour/background/font).
      assert html =~ ~s(<div style="max-width:680px;margin:0 auto;padding:24px">)
      # Parchment page background on the doctype body — same hex, wrapped in
      # `var(--paper-bg-deep, …)` so themed hosts can override; the inline bg
      # stays as the no-CSS fallback. Wave-2 slice 6 (export self-containment):
      # the standalone article document now also embeds the ONE canonical
      # stylesheet in <head> and tags <body class="bp-paper-surface">, so the
      # export styles itself from the single source.
      assert html =~
               ~s|<body class="bp-paper-surface" style="background:var(--paper-bg-deep, #eaf1ee);|

      assert html =~ "<style>" <> Barkpark.PortableDoc.Render.Stylesheet.css() <> "</style>"
    end

    test "email/default mode output is unchanged for an existing block" do
      # The Wave 4 expectation for a heading block must still hold byte-for-byte.
      block = %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Title"}

      assert Render.render_block(block) ==
               ~s(<h1 style="font-family:'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif;color:#15211d;letter-spacing:-0.02em;line-height:1.15;margin:0 0 12px;font-weight:600;font-size:32px">Title</h1>)

      assert Render.render_block(block, %{style: :email}) ==
               ~s(<h1 style="font-family:'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif;color:#15211d;letter-spacing:-0.02em;line-height:1.15;margin:0 0 12px;font-weight:600;font-size:32px">Title</h1>)
    end

    test "heading level 1/2/3 emit distinct BARE tags — sizing lives in the surface CSS" do
      h = fn level ->
        block = %{"type" => "heading", "level" => level, "text" => "H"}
        Render.render_block(block, %{style: :article})
      end

      # Stage 2: the level shows in the TAG, not an inline font-size. Sizing,
      # weight, and family are single-sourced from the `--bp-*` heading tokens
      # via `.bp-paper-surface h1/h2/h3` — so View and Edit render identically
      # by construction. The frame carries no inline style at all.
      assert h.(1) == "<h1>H</h1>"
      assert h.(2) == "<h2>H</h2>"
      assert h.(3) == "<h3>H</h3>"
      refute h.(1) =~ "font-size"
      refute h.(1) =~ "font-weight"
      refute h.(1) =~ "font-family"
    end

    test "eyebrow renders an uppercase accent kicker in article mode" do
      block = %{"type" => "eyebrow", "text" => "Field notes"}
      html = Render.render_block(block, %{style: :article})

      assert html =~ "Field notes"
      # Stage 2 wave 2: the eyebrow role is class-driven (`.bp-paper-surface`
      # `.bp-role-eyebrow` owns the uppercase accent kicker); no inline theme.
      assert html =~ ~s(class="bp-role-eyebrow")
      refute html =~ "text-transform:uppercase"
    end

    test "byline joins items with a separator and carries a bottom rule (article)" do
      block = %{"type" => "byline", "items" => ["Pelle Jarl", "May 2026"]}
      html = Render.render_block(block, %{style: :article})

      assert html =~ "Pelle Jarl · May 2026"
      # Stage 2 wave 2: the byline rule/colour live in `.bp-role-byline` now.
      assert html =~ ~s(class="bp-role-byline")
      refute html =~ "border-bottom:1px solid"
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
      # Stage 2 wave 2: the ingress role (larger, heavier lead) is class-driven.
      assert html =~ ~s(class="bp-role-ingress")
      refute html =~ "font-size:1.28rem"
    end

    test "eyebrow/byline/ingress are typographic BLOCKS in email mode (email-prose-polish: the span form fused the masthead into one line)" do
      eyebrow = Render.render_block(%{"type" => "eyebrow", "text" => "Kicker"}, %{style: :email})
      byline = Render.render_block(%{"type" => "byline", "text" => "Author"}, %{style: :email})

      ingress =
        Render.render_block(
          %{"type" => "ingress", "content" => [%{"type" => "text", "value" => "Lead"}]},
          %{style: :email}
        )

      assert eyebrow ==
               ~s(<p style="margin:0 0 6px;font-weight:600;color:#55635e;text-transform:uppercase;letter-spacing:0.14em;font-size:12px">Kicker</p>)

      assert byline ==
               ~s(<p style="border-bottom:1px solid #dde7e2;padding-bottom:10px;margin:0 0 20px;color:#55635e;font-size:13px">Author</p>)

      assert ingress == ~s(<p style="margin:0 0 10px;line-height:1.55;font-size:18px">Lead</p>)
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
      assert html =~ "background:var(--paper-bg-deep, #eaf1ee)"
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

    # SUPERSEDED BY THE EMPTY-CHROME INVARIANT, not deleted. This test pinned the
    # DEFECT it was written to make safe: a src-less asciicast still emitted the
    # bordered mount, and `safe_url("")` neutralised the empty src to `"#"` — so
    # the reader got a 303-byte player box the hook then tried to fetch and play,
    # and email got `<a href="#">Terminal recording</a>`, a dead link whose text
    # no author wrote. Neutralising the URL was right; EMITTING the frame was the
    # bug. The don't-crash half is kept, re-aimed at the new answer; the
    # `safe_url` neutralisation itself is still pinned by the
    # disallowed-scheme test below and by the caption-only case here.
    test "empty / missing src composes to nothing, and never crashes (article + email)" do
      block = %{"id" => "ac2", "type" => "asciicast"}

      assert Render.render_block(block, %{style: :article}) == ""
      assert Render.render_block(block, %{style: :email}) == ""
    end

    # A caption WITHOUT a src keeps the frame — the guard is an AND over every
    # field a reader could see, so it never deletes authored prose. This is also
    # where the empty-src `safe_url` neutralisation stays covered.
    test "a captioned but src-less asciicast keeps its frame with a neutralised src" do
      block = %{"id" => "ac3", "type" => "asciicast", "caption" => "Recording pending"}
      article = Render.render_block(block, %{style: :article})

      assert article =~ ~s(class="bp-asciicast")
      assert article =~ ~s(data-cast-src="#")
      assert article =~ "Recording pending"
      assert Render.render_block(block, %{style: :email}) =~ "Terminal recording"
    end

    test "a disallowed-scheme src is neutralised to # in the data attribute" do
      block = Map.put(@asciicast, "src", "javascript:alert(1)")
      html = Render.render_block(block, %{style: :article})
      assert html =~ ~s(data-cast-src="#")
      refute html =~ "javascript:alert"
    end

    # `poster` — the per-block resting frame. The two hydrating twins
    # (client.ts / bulldocs.html.heex runAsciicast) default to `npt:0:1`, which
    # is near-empty black for a cast that opens on a banner and a reading pause;
    # a block may name a LATER, full frame instead.
    test "a poster rides data-cast-poster on the article mount" do
      block = Map.put(@asciicast, "poster", "npt:0:12")
      html = Render.render_block(block, %{style: :article})
      assert html =~ ~s(data-cast-poster="npt:0:12")
    end

    test "a compact row count rides data-cast-rows on the article mount" do
      block = Map.put(@asciicast, "rows", 18)
      html = Render.render_block(block, %{style: :article})
      assert html =~ ~s(data-cast-rows="18")
    end

    test "no poster → no attribute, so the client keeps its npt:0:1 default" do
      html = Render.render_block(@asciicast, %{style: :article})
      refute html =~ "data-cast-poster"
    end

    test "a blank / whitespace-only poster is treated as unset" do
      html = Render.render_block(Map.put(@asciicast, "poster", "   "), %{style: :article})
      refute html =~ "data-cast-poster"
    end

    test "a non-stringish poster is fail-soft (→ unset, never a crash)" do
      html =
        Render.render_block(Map.put(@asciicast, "poster", %{"npt" => 12}), %{style: :article})

      assert html =~ ~s(class="bp-asciicast")
      refute html =~ "data-cast-poster"
    end

    test "a poster is attribute-escaped, so it cannot break out of the mount" do
      block = Map.put(@asciicast, "poster", ~s(npt:0:1" onerror="x))
      html = Render.render_block(block, %{style: :article})
      refute html =~ ~s(onerror="x)
      assert html =~ "&quot;"
    end

    test "email mode ignores poster — no player runtime to poster" do
      html = Render.render_block(Map.put(@asciicast, "poster", "npt:0:12"), %{style: :email})
      refute html =~ "data-cast-poster"
      assert html =~ "Terminal recording"
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

      # Stage 2: the level-sized rule moved OFF the tag into the
      # `.bp-paper-surface h1/h2/h3` element rules — the tag is bare, sizing is
      # single-sourced from the `--bp-*` tokens (View ≡ Edit by construction).
      refute h.(1) =~ ~r/<h1[^>]*style=/
      refute h.(1) =~ "font-size"

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

    test "email heading is the inline-styled semantic element (gp-w3 email view)" do
      html =
        Render.render_block(%{"type" => "heading", "level" => 2, "text" => "T"}, %{style: :email})

      assert html =~ ~r/^<h2 style="/
      assert html =~ ">T</h2>"
      assert html =~ "#15211d"
    end
  end

  describe "article fidelity — code block as a single <pre>" do
    @code %{"id" => "c1", "type" => "code", "value" => "let x = 1\nif x < 2 & y > 0:"}

    test "article mode renders one styled <pre> block (not per-line chips)" do
      html = Render.render_block(@code, %{style: :article})

      assert html =~ "<pre"
      # Parchment background, terracotta left-border, horizontal scroll —
      # now emitted through `var(--paper-*, hex)` for dark-mode theming.
      assert html =~ "background:var(--paper-bg-deep, #eaf1ee)"
      # S8 (au-eg): geometry is token-bound (--bp-codeblock-*); the code bar is a
      # reading-character cue (TUI twin ReadingAccent), so its accent now binds the
      # terracotta --paper-reading-accent (color.reading-accent), not the evergreen
      # chrome --paper-accent.
      assert html =~
               "border-left:var(--bp-codeblock-accent-w, 3px) solid var(--paper-reading-accent, #a23925)"

      assert html =~ "font-size:var(--bp-codeblock-size, 0.9rem)"
      assert html =~ "overflow-x:auto"
      # The value is escaped inside the single <pre> (no per-line <code> chips).
      assert html =~ "if x &lt; 2 &amp; y &gt; 0:"
      refute html =~ ~s(<code style="background:#f1ede2)
    end

    test "email mode keeps the per-line inline <code> chip stack (regression)" do
      html = Render.render_block(@code, %{style: :email})
      refute html =~ "<pre"
      # Per-line PdInlineCode chips on the email/default palette bg.
      assert html =~ ~s(<code style="background:#eaf1ee)
    end
  end

  # The asset-less-image doctrine (rule 3) applied to `code`. Found authoring
  # /papers/epic-cycle-session-card: a code block whose source never reached the
  # `value` key composed to the FULL parchment/terracotta <pre> frame around ""
  # — an empty box on the public reader that looks like a broken callout — while
  # the email/default arm emitted a PdBox holding one empty <code> chip (a stray
  # blank line). Blank source is scaffolding, not content: both style arms now
  # compose to the empty `_raw` node and the block is SKIPPED.
  describe "render_block/1 — sourceless code block composes to nothing" do
    for {label, block} <- [
          {"a missing value key", %{"id" => "c", "type" => "code"}},
          {"an explicit nil value", %{"id" => "c", "type" => "code", "value" => nil}},
          {"an empty-string value", %{"id" => "c", "type" => "code", "value" => ""}},
          {"an ASCII-whitespace-only value",
           %{"id" => "c", "type" => "code", "value" => "  \n\t \n"}},
          # NBSP U+00A0 + EM SPACE U+2003 + IDEOGRAPHIC SPACE U+3000 — Unicode
          # White_Space that a naive `== ""` check would wave through as content.
          {"a Unicode-whitespace-only value",
           %{"id" => "c", "type" => "code", "value" => "\u00A0\u2003\u3000"}},
          {"a non-stringish (map) value", %{"id" => "c", "type" => "code", "value" => %{}}}
        ] do
      test "#{label} renders nothing in article mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :article}) == ""
      end

      test "#{label} renders nothing in email/default mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :email}) == ""
        assert Render.render_block(unquote(Macro.escape(block))) == ""
      end
    end

    test "a skipped code block does not break the walker — neighbours still render" do
      blocks = [
        %{"id" => "h", "type" => "heading", "text" => "A"},
        %{"id" => "c", "type" => "code", "value" => "   "},
        %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "B"}]}
      ]

      html = Render.render_blocks(blocks, %{style: :article})
      refute html =~ "<pre"
      assert html =~ ">A</h2>"
      assert html =~ "B"
    end

    # BYTE-IDENTITY: a code block with real source is unchanged by the guard —
    # both arms pinned to their exact pre-guard bytes (escaping and all), so a
    # future "simplification" of the blank check cannot quietly move a byte.
    test "article: a nonempty code block is byte-identical to the pre-guard emitter" do
      assert Render.render_block(@code, %{style: :article}) ==
               ~s|<pre style="background:var(--paper-bg-deep, #eaf1ee);border:0;| <>
                 ~s|border-radius:var(--bp-codeblock-radius, 0);| <>
                 ~s|border-left:var(--bp-codeblock-accent-w, 3px) solid var(--paper-reading-accent, #a23925);| <>
                 ~s|color:var(--paper-ink, #15211d);| <>
                 ~s|padding:var(--bp-codeblock-pad, 0.9rem 1.1rem);| <>
                 ~s|margin:var(--bp-codeblock-margin, 1.2rem 0);| <>
                 ~s|font-family:var(--paper-font-mono, ui-monospace,Menlo,monospace);| <>
                 ~s|font-size:var(--bp-codeblock-size, 0.9rem);| <>
                 ~s|line-height:var(--bp-codeblock-lh, 1.5);overflow-x:auto;white-space:pre">| <>
                 ~s|let x = 1\nif x &lt; 2 &amp; y &gt; 0:</pre>|
    end

    test "email/default: a nonempty code block is byte-identical to the pre-guard emitter" do
      chip =
        ~s|<code style="background:#eaf1ee;padding:1px 5px;border-radius:4px;| <>
          ~s|font-family:ui-monospace,Menlo,monospace;font-size:0.88em">|

      expected =
        ~s|<div style="display:flex;flex-direction:column">| <>
          ~s|<span>| <>
          chip <>
          ~s|let x = 1</code></span>| <>
          ~s|<span>| <>
          chip <>
          ~s|if x &lt; 2 &amp; y &gt; 0:</code></span>| <>
          ~s|</div>|

      assert Render.render_block(@code, %{style: :email}) == expected
      assert Render.render_block(@code) == expected
    end

    # A source that is only whitespace-PADDED still renders in full: the guard
    # decides emptiness on the trimmed source but emits the UNTRIMMED bytes, so
    # leading indentation is never eaten.
    test "leading/trailing whitespace around real source is preserved verbatim" do
      html = Render.render_block(%{"type" => "code", "value" => "  x\n"}, %{style: :article})
      assert html =~ ~s(white-space:pre">  x\n</pre>)
    end

    # Zero-width characters are NOT Unicode White_Space — they are typed glyphs,
    # so the block keeps its frame (the guard must not over-reach into content).
    test "a zero-width-space source is content, not scaffolding" do
      html = Render.render_block(%{"type" => "code", "value" => "\u200B"}, %{style: :article})
      assert html =~ "<pre"
    end
  end

  @pd_parity_input_diagram %{
    "caption" => "The three-stage pipeline",
    "source" => "graph TD; A[Ingest] --> B[Render] --> C[Publish]",
    "type" => "diagram"
  }
  @pd_parity_input_asciicast %{
    "caption" => "A terminal walkthrough",
    "poster" => "npt:0:12",
    "src" => "https://example.com/casts/demo.cast",
    "type" => "asciicast"
  }
  @pd_parity_input_figure %{
    "caption" => "Figure with a captioned child",
    "child" => %{
      "content" => [%{"type" => "text", "value" => "The figure body."}],
      "type" => "paragraph"
    },
    "type" => "figure"
  }
  @pd_parity_input_action %{
    "href" => "https://example.com/docs",
    "label" => "Read the docs",
    "priority" => "primary",
    "type" => "action"
  }
  @pd_parity_input_filetree %{
    "legend" => "● created · ○ injected · ✕ removed",
    "text" =>
      "api/lib/barkpark/portable_doc/render/\n├── components.ex ● diff_html/1 + filetree_html/1\n├── compose.ex ○ grew the diff + filetree clauses\n└── starter_stub.ex ✕ removed",
    "type" => "filetree"
  }

  # ── THE EMPTY-CHROME INVARIANT (extends #14806 from `code` to its siblings) ──
  #
  # #14806 applied the asset-less-image doctrine (rule 3: scaffolding composes to
  # the empty `_raw` node and the reader shows NOTHING) to the standalone `code`
  # block. Its measured survey — all 64 in-scope types rendered with a contentless
  # block in BOTH compose styles — found five more framed blocks that painted
  # chrome around no content on the public reader:
  #
  #   diagram    328 B bordered parchment card around an empty <pre class="mermaid">
  #   asciicast  303 B player mount carrying data-cast-src="#" (safe_url("") -> "#")
  #   figure     183 B empty bordered <figure>
  #   action     <a href="#" class="bp-button"></a> — a CLICKABLE empty button
  #   filetree   291 B bordered mono card containing literally nothing
  #
  # THE RULE, one sentence: a block composes to nothing when EVERY field a reader
  # could see is blank — an AND, never an OR, so the guard can only remove a block
  # from which nothing authored survives. Blank is `blank_field?/2` in compose.ex,
  # the predicate #14806 introduced: missing key, explicit nil, non-stringish, ""
  # or Unicode-whitespace-only (`String.trim/1` strips the whole White_Space set,
  # not just ASCII); zero-width characters (U+200B, U+FEFF) are typed glyphs and
  # stay CONTENT. Chrome-only keys never count as content: `priority` on an action
  # is a button skin, `poster`/`rows` on an asciicast are options for a recording
  # that is not there.
  #
  # Dropping a caption because its media is missing would DELETE authored prose —
  # the silent-content-loss shape `Slots.lossy_shape?/1` exists to catch. That
  # predicate answers only note/card/callout/pipeline (`Slots.field_vocab/1`
  # returns nil for every type here), so it neither covers nor double-answers
  # these five; the AND rule is what keeps them from ever disagreeing.

  describe "render_block/1 — a contentless diagram composes to nothing" do
    for {label, block} <- [
          {"missing source and caption keys", %{"id" => "d", "type" => "diagram"}},
          {"explicit nil source and caption",
           %{"id" => "d", "type" => "diagram", "source" => nil, "caption" => nil}},
          {"empty-string source and caption",
           %{"id" => "d", "type" => "diagram", "source" => "", "caption" => ""}},
          {"ASCII-whitespace-only source and caption",
           %{"id" => "d", "type" => "diagram", "source" => "  \n\t ", "caption" => "\n "}},
          # NBSP U+00A0 + EM SPACE U+2003 + IDEOGRAPHIC SPACE U+3000 — Unicode
          # White_Space a naive `== ""` check would wave through as content.
          {"Unicode-whitespace-only source and caption",
           %{"id" => "d", "type" => "diagram", "source" => "\u00A0\u2003", "caption" => "\u3000"}},
          {"non-stringish source and caption",
           %{"id" => "d", "type" => "diagram", "source" => %{}, "caption" => []}}
        ] do
      test "#{label} renders nothing in article mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :article}) == ""
      end

      test "#{label} renders nothing in email/default mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :email}) == ""
        assert Render.render_block(unquote(Macro.escape(block))) == ""
      end
    end

    # EITHER half alone keeps the card: the guard is an AND over everything the
    # reader could see, so it never deletes an author's caption to tidy a border.
    test "a caption with no source still renders — prose is never deleted" do
      block = %{"id" => "d", "type" => "diagram", "caption" => "Pipeline, coming soon"}
      assert Render.render_block(block, %{style: :article}) =~ "Pipeline, coming soon"
      assert Render.render_block(block, %{style: :email}) =~ "Pipeline, coming soon"
    end

    test "a source with no caption still renders" do
      block = %{"id" => "d", "type" => "diagram", "source" => "graph TD; A --> B"}
      assert Render.render_block(block, %{style: :article}) =~ ~s(<pre class="mermaid">)
      refute Render.render_block(block, %{style: :article}) =~ "<figcaption"
    end

    # Zero-width characters are NOT Unicode White_Space — the guard must not
    # over-reach into content.
    test "a zero-width-space source is content, not scaffolding" do
      block = %{"id" => "d", "type" => "diagram", "source" => "\u200B"}
      assert Render.render_block(block, %{style: :article}) =~ "<figure"
    end
  end

  describe "render_block/1 — a contentless asciicast composes to nothing" do
    for {label, block} <- [
          {"missing src and caption keys", %{"id" => "a", "type" => "asciicast"}},
          {"explicit nil src and caption",
           %{"id" => "a", "type" => "asciicast", "src" => nil, "caption" => nil}},
          {"empty-string src and caption",
           %{"id" => "a", "type" => "asciicast", "src" => "", "caption" => ""}},
          {"ASCII-whitespace-only src and caption",
           %{"id" => "a", "type" => "asciicast", "src" => " \t", "caption" => "  \n"}},
          {"Unicode-whitespace-only src and caption",
           %{"id" => "a", "type" => "asciicast", "src" => "\u00A0", "caption" => "\u2003\u3000"}},
          {"non-stringish src and caption",
           %{"id" => "a", "type" => "asciicast", "src" => %{}, "caption" => ["nope"]}},
          # `poster` and `rows` are PLAYER OPTIONS, not content: a poster names a
          # resting frame of a recording that is not there.
          {"only chrome keys (poster + rows), no src or caption",
           %{"id" => "a", "type" => "asciicast", "poster" => "npt:0:12", "rows" => 24}}
        ] do
      test "#{label} renders nothing in article mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :article}) == ""
      end

      test "#{label} renders nothing in email/default mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :email}) == ""
        assert Render.render_block(unquote(Macro.escape(block))) == ""
      end
    end

    test "a caption with no src still renders — prose is never deleted" do
      block = %{"id" => "a", "type" => "asciicast", "caption" => "Recording pending"}
      assert Render.render_block(block, %{style: :article}) =~ "Recording pending"
      assert Render.render_block(block, %{style: :email}) =~ "Recording pending"
    end

    test "a src with no caption still renders the mount" do
      block = %{"id" => "a", "type" => "asciicast", "src" => "https://example.com/x.cast"}
      html = Render.render_block(block, %{style: :article})
      assert html =~ ~s(class="bp-asciicast")
      assert html =~ ~s(data-cast-src="https://example.com/x.cast")
    end
  end

  # THE FIGURE RULE, written down: a figure is blank when NOTHING it would paint
  # survives — its child contributes NO BYTES **and** its caption is blank. "No
  # bytes" is asked of the COMPOSED child, not of the key, which is deliberately
  # stronger than a key check: a missing / nil / non-map child composes to "", and
  # so does a child that is itself scaffolding — an asset-less `image`, or (since
  # #14806) a sourceless `code` block. The 183-byte empty bordered <figure> the
  # survey measured is exactly the wrapping-a-nothing-child shape, which a key
  # check would miss.
  describe "render_block/1 — a contentless figure composes to nothing" do
    for {label, block} <- [
          {"a missing child key", %{"id" => "f", "type" => "figure"}},
          {"an explicit nil child", %{"id" => "f", "type" => "figure", "child" => nil}},
          {"a non-map child", %{"id" => "f", "type" => "figure", "child" => "not a block"}},
          {"a list child", %{"id" => "f", "type" => "figure", "child" => []}},
          {"no child and an empty-string caption",
           %{"id" => "f", "type" => "figure", "caption" => ""}},
          {"no child and an ASCII-whitespace caption",
           %{"id" => "f", "type" => "figure", "caption" => " \n\t "}},
          {"no child and a Unicode-whitespace caption",
           %{"id" => "f", "type" => "figure", "caption" => "\u00A0\u3000"}},
          # The interlock with the asset-less-image doctrine and with #14806: a
          # child that ITSELF composes to nothing leaves the frame empty too.
          {"a child that is an asset-less image",
           %{"id" => "f", "type" => "figure", "child" => %{"type" => "image", "src" => "  "}}},
          {"a child that is a sourceless code block",
           %{"id" => "f", "type" => "figure", "child" => %{"type" => "code", "value" => "   "}}}
        ] do
      test "#{label} renders nothing in article mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :article}) == ""
      end

      test "#{label} renders nothing in email/default mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :email}) == ""
        assert Render.render_block(unquote(Macro.escape(block))) == ""
      end
    end

    test "a caption with no child still renders — prose is never deleted" do
      block = %{"id" => "f", "type" => "figure", "caption" => "Diagram to follow"}
      assert Render.render_block(block, %{style: :article}) =~ "Diagram to follow"
      assert Render.render_block(block, %{style: :email}) =~ "Diagram to follow"
    end

    test "a real child with no caption still renders, with no figcaption" do
      block = %{
        "id" => "f",
        "type" => "figure",
        "child" => %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Hi"}]}
      }

      html = Render.render_block(block, %{style: :article})
      assert html =~ "<figure"
      assert html =~ "Hi"
      refute html =~ "<figcaption"
    end
  end

  describe "render_block/1 — a contentless action composes to nothing" do
    for {label, block} <- [
          {"missing label and href keys", %{"id" => "b", "type" => "action"}},
          {"explicit nil label and href",
           %{"id" => "b", "type" => "action", "label" => nil, "href" => nil}},
          # The exact shape the Studio canvas seeds:
          # `Blocks.default_block("action", id)`.
          {"the Studio default_block shape",
           %{"id" => "b", "type" => "action", "href" => "", "label" => ""}},
          {"ASCII-whitespace-only label and href",
           %{"id" => "b", "type" => "action", "label" => "  ", "href" => "\t\n"}},
          {"Unicode-whitespace-only label and href",
           %{"id" => "b", "type" => "action", "label" => "\u00A0", "href" => "\u2003"}},
          {"non-stringish label and href",
           %{"id" => "b", "type" => "action", "label" => %{}, "href" => []}},
          # `priority` is CHROME — which button skin, never content.
          {"only a priority, no label or href",
           %{"id" => "b", "type" => "action", "priority" => "primary"}}
        ] do
      test "#{label} renders nothing in article mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :article}) == ""
      end

      test "#{label} renders nothing in email/default mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :email}) == ""
        assert Render.render_block(unquote(Macro.escape(block))) == ""
      end
    end

    test "a label with no href still renders the button" do
      html = Render.render_block(%{"type" => "action", "label" => "Read"}, %{style: :article})
      assert html =~ ~s(class="bp-button")
      assert html =~ "Read"
    end

    test "an href with no label still renders the link" do
      html =
        Render.render_block(%{"type" => "action", "href" => "https://x.test"}, %{style: :article})

      assert html =~ ~s(href="https://x.test")
    end

    # The action clause is also the `action` CHILD path for card / terminal /
    # columns (render_children/2 -> render_blocks/2 -> compose_block/2), so the
    # empty button cannot come back through a container.
    test "a blank action nested in a container emits no anchor" do
      block = %{
        "id" => "cols",
        "type" => "columns",
        "columns" => [[%{"id" => "b", "type" => "action", "href" => "", "label" => ""}]]
      }

      for style <- [:article, :email] do
        refute Render.render_block(block, %{style: style}) =~ "<a "
      end
    end
  end

  # The ONE framed arm from the criterion-2 sweep that was a genuine SILENT BOX.
  # Its neighbours self-describe and are deliberately left: `diff` prints its own
  # `+0 -0` counts row, and every `chat-*` card prints its literal title.
  describe "render_block/1 — a contentless filetree composes to nothing" do
    for {label, block} <- [
          {"missing text and legend keys", %{"id" => "t", "type" => "filetree"}},
          {"explicit nil text and legend",
           %{"id" => "t", "type" => "filetree", "text" => nil, "legend" => nil}},
          {"empty-string text and legend",
           %{"id" => "t", "type" => "filetree", "text" => "", "legend" => ""}},
          {"ASCII-whitespace-only text and legend",
           %{"id" => "t", "type" => "filetree", "text" => "  \n ", "legend" => "\t"}},
          {"Unicode-whitespace-only text and legend",
           %{"id" => "t", "type" => "filetree", "text" => "\u00A0", "legend" => "\u3000"}},
          {"non-stringish text and legend",
           %{"id" => "t", "type" => "filetree", "text" => %{}, "legend" => []}}
        ] do
      test "#{label} renders nothing in article mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :article}) == ""
      end

      test "#{label} renders nothing in email/default mode" do
        assert Render.render_block(unquote(Macro.escape(block)), %{style: :email}) == ""
        assert Render.render_block(unquote(Macro.escape(block))) == ""
      end
    end

    test "a legend with no tree still renders — prose is never deleted" do
      block = %{"id" => "t", "type" => "filetree", "legend" => "* created"}
      assert Render.render_block(block, %{style: :article}) =~ "* created"
    end

    test "a tree with no legend still renders" do
      block = %{"id" => "t", "type" => "filetree", "text" => "api/\n  compose.ex"}
      assert Render.render_block(block, %{style: :article}) =~ "compose.ex"
    end
  end

  describe "the empty-chrome guards do not disturb the walker or real content" do
    test "skipped blocks do not break the walker — neighbours still render" do
      blocks = [
        %{"id" => "h", "type" => "heading", "text" => "A"},
        %{"id" => "d", "type" => "diagram"},
        %{"id" => "a", "type" => "asciicast"},
        %{"id" => "f", "type" => "figure"},
        %{"id" => "b", "type" => "action", "href" => "", "label" => ""},
        %{"id" => "t", "type" => "filetree"},
        %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => "B"}]}
      ]

      for style <- [:article, :email] do
        html = Render.render_blocks(blocks, %{style: style})
        refute html =~ "<figure"
        refute html =~ "bp-button"
        refute html =~ "bp-asciicast"
        refute html =~ "bp-filetree"
        refute html =~ "<a "
        assert html =~ "A"
        assert html =~ "B"
      end
    end

    # BYTE-IDENTITY: the five nonempty pd-parity golden inputs, pinned to their
    # EXACT pre-guard bytes in BOTH style arms, so a future "simplification" of a
    # blank predicate cannot quietly move a byte a golden or fixture depends on.
    # (These literals are the frozen origin/main output of the same inputs — the
    # `expectedHtml` in test/support/fixtures/pd-parity/<type>.golden.json for the
    # article arm.)

    test "a nonempty diagram is byte-identical to the pre-guard emitter" do
      input = @pd_parity_input_diagram

      assert Render.render_block(input, %{style: :article}) ==
               ~s|<figure style="margin:var(--bp-air-figure, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;padding:1.2rem;background:var(--paper-bg-deep, #eaf1ee);border:1px solid var(--paper-rule, #dde7e2);border-radius:4px;overflow-x:auto"><pre class="mermaid">graph TD; A[Ingest] --&gt; B[Render] --&gt; C[Publish]</pre><figcaption style="margin-top:0.8rem;color:var(--paper-ink-soft, #55635e);font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif;max-width:var(--bp-evidence-caption, 72ch)">The three-stage pipeline</figcaption></figure>|

      assert Render.render_block(input, %{style: :email}) ==
               ~s|<figure style="margin:16px 0"><pre style="background:#f3f4f6;padding:12px;font-family:ui-monospace,Menlo,monospace;font-size:0.9em;overflow:auto;white-space:pre-wrap">graph TD; A[Ingest] --&gt; B[Render] --&gt; C[Publish]</pre><div style="color:#6b7280;font-style:italic;font-size:0.9em;margin-top:8px">The three-stage pipeline</div></figure>|
    end

    test "a nonempty asciicast is byte-identical to the pre-guard emitter" do
      input = @pd_parity_input_asciicast

      assert Render.render_block(input, %{style: :article}) ==
               ~s|<figure style="margin:var(--bp-air-asciicast, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;overflow-x:auto"><div class="bp-asciicast" data-cast-src="https://example.com/casts/demo.cast" data-cast-poster="npt:0:12" style="border:1px solid #dde7e2;border-radius:6px;overflow:hidden"></div><figcaption style="margin-top:0.8rem;color:#55635e;font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif;max-width:var(--bp-evidence-caption, 72ch)">A terminal walkthrough</figcaption></figure>|

      assert Render.render_block(input, %{style: :email}) ==
               ~s|<figure style="margin:16px 0"><a href="https://example.com/casts/demo.cast">Terminal recording</a><div style="color:#6b7280;font-style:italic;font-size:0.9em;margin-top:8px">A terminal walkthrough</div></figure>|
    end

    test "a nonempty figure is byte-identical to the pre-guard emitter" do
      input = @pd_parity_input_figure

      assert Render.render_block(input, %{style: :article}) ==
               ~s|<figure style="margin:var(--bp-air-figure, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;overflow-x:auto"><p>The figure body.</p><figcaption style="margin-top:0.8rem;color:var(--paper-ink-soft, #55635e);font-style:italic;font-size:0.9rem;font-family:system-ui,-apple-system,'SF Pro Text',sans-serif;max-width:var(--bp-evidence-caption, 72ch)">Figure with a captioned child</figcaption></figure>|

      assert Render.render_block(input, %{style: :email}) ==
               ~s|<figure style="margin:16px 0">| <>
                 email_p("The figure body.") <>
                 ~s|<div style="color:#6b7280;font-style:italic;font-size:0.9em;margin-top:8px">Figure with a captioned child</div></figure>|
    end

    test "a nonempty action is byte-identical to the pre-guard emitter" do
      input = @pd_parity_input_action

      assert Render.render_block(input, %{style: :article}) ==
               ~s|<a href="https://example.com/docs" class="bp-button bp-button--primary">Read the docs</a>|

      assert Render.render_block(input, %{style: :email}) ==
               ~s|<a href="https://example.com/docs" style="display:inline-block;padding:10px 20px;background:#1e5347;color:#ffffff;text-decoration:none;font-weight:bold;border-radius:0">Read the docs</a>|
    end

    test "a nonempty filetree is byte-identical to the pre-guard emitter" do
      input = @pd_parity_input_filetree

      assert Render.render_block(input, %{style: :article}) ==
               ~s|<div class="bp-filetree text-xs" style="font-family: var(--font-mono); margin: 4px var(--bp-evidence-pull, 0px); width: var(--bp-evidence-width, 100%); box-sizing: border-box; background: var(--muted-surface); border-radius: 6px; padding: 6px 8px; overflow-x: auto; line-height: 1.5;"><div style="white-space: pre;">api/lib/barkpark/portable_doc/render/</div><div style="white-space: pre;">├── components.ex<span class="bp-filetree-note" style="color: var(--ok);"> ● diff_html/1 + filetree_html/1</span></div><div style="white-space: pre;">├── compose.ex<span class="bp-filetree-note" style="color: var(--fg-dim);"> ○ grew the diff + filetree clauses</span></div><div style="white-space: pre;">└── starter_stub.ex<span class="bp-filetree-note" style="color: var(--danger);"> ✕ removed</span></div><div class="bp-filetree-legend text-dim" style="font-size: 11px; margin-top: 4px;">● created · ○ injected · ✕ removed</div></div>|

      assert Render.render_block(input, %{style: :email}) ==
               ~s|<div class="bp-filetree text-xs" style="font-family: var(--font-mono); margin: 4px var(--bp-evidence-pull, 0px); width: var(--bp-evidence-width, 100%); box-sizing: border-box; background: var(--muted-surface); border-radius: 6px; padding: 6px 8px; overflow-x: auto; line-height: 1.5;"><div style="white-space: pre;">api/lib/barkpark/portable_doc/render/</div><div style="white-space: pre;">├── components.ex<span class="bp-filetree-note" style="color: var(--ok);"> ● diff_html/1 + filetree_html/1</span></div><div style="white-space: pre;">├── compose.ex<span class="bp-filetree-note" style="color: var(--fg-dim);"> ○ grew the diff + filetree clauses</span></div><div style="white-space: pre;">└── starter_stub.ex<span class="bp-filetree-note" style="color: var(--danger);"> ✕ removed</span></div><div class="bp-filetree-legend text-dim" style="font-size: 11px; margin-top: 4px;">● created · ○ injected · ✕ removed</div></div>|
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
      # Stage 2 wave 2: body cells are class-driven (`.bp-table__td` owns the
      # warm rule colour); no inline theme, and never the email gray.
      assert html =~ ~s(<td class="bp-table__td">)
      refute html =~ "#dde7e2"
    end

    test "article mode emits a <thead>/<th> band when an explicit head row is supplied" do
      html = Render.render_block(@table_with_head, %{style: :article})

      assert html =~ "<thead>"
      # Stage 2 wave 2: the header band + body cells are class-driven
      # (`.bp-table__th` = uppercase/muted/2px rule, `.bp-table__td` = body rule).
      assert html =~ ~s(<th class="bp-table__th">)
      assert html =~ ~s(<td class="bp-table__td">)
      refute html =~ "text-transform:uppercase"
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

    test "article mode treats scalar columns as a header row without crashing" do
      block = %{
        "id" => "t4",
        "type" => "table",
        "columns" => ["Corner", "Failure", "Proof"],
        "rows" => [["Reader", "Empty list", "No empty list elements"]]
      }

      html = Render.render_block(block, %{style: :article})

      assert html =~ "<thead>"
      assert html =~ "Corner"
      assert html =~ "Failure"
      assert html =~ "Proof"
      assert html =~ "Reader"
      assert html =~ "No empty list elements"
    end

    test "article mode promotes a boolean header when an empty head placeholder exists" do
      block = %{
        "id" => "t5",
        "type" => "table",
        "header" => true,
        "head" => [],
        "rows" => [["Surface", "Proof"], ["TUI", "Visible"]]
      }

      html = Render.render_block(block, %{style: :article})

      assert html =~ "<thead>"
      assert html =~ "Surface"
      assert html =~ "Proof"
      assert html =~ "TUI"
      assert html =~ "Visible"
    end

    test "email mode keeps the flat <td>-only gray table (regression)" do
      html = Render.render_block(@table, %{style: :email})
      refute html =~ "<thead>"
      refute html =~ "<th "

      assert html =~
               ~s(<table role="presentation" style="border-collapse:collapse;width:100%;margin:18px 0"><tbody><tr><td style="border-bottom:1px solid #dde7e2;padding:10px 12px;vertical-align:top"><span>Name</span></td><td style="border-bottom:1px solid #dde7e2;padding:10px 12px;vertical-align:top"><span>Role</span></td></tr><tr><td style="border-bottom:1px solid #dde7e2;padding:10px 12px;vertical-align:top"><span>Pelle</span></td><td style="border-bottom:1px solid #dde7e2;padding:10px 12px;vertical-align:top"><span>Author</span></td></tr></tbody></table>)
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
      # Stage 2 wave 2: the pullquote role (block, left rule, muted, larger) is
      # class-driven; only the author `italic` mark stays inline (DATA).
      assert html =~ ~s(class="bp-role-pullquote")
      assert html =~ "font-style:italic"

      refute html =~
               ~s(<span style="margin:22px 0;padding:2px 0 2px 16px;border-left:3px solid #1e5347;color:#15211d;font-style:italic;font-size:19px;font-style:italic">The medium is the message.</span>)
    end

    test "email mode renders an inline-styled block pullquote (accent rule + rhythm)" do
      html = Render.render_block(@pull, %{style: :email})
      assert html =~ "The medium is the message."
      assert html =~ "font-style:italic"
      assert html =~ "border-left:3px solid #1e5347"
      assert html =~ "margin:22px 0"
      # a real block, not an inline span — spans cannot carry vertical margins
      assert String.starts_with?(html, "<p ")
    end
  end

  describe "article fidelity — § section divider" do
    @divider %{"id" => "d1", "type" => "divider"}

    test "article mode renders the § glyph straddling a hairline rule" do
      html = Render.render_block(@divider, %{style: :article})
      assert html =~ "§"
      assert html =~ "border-top:1px solid var(--paper-rule, #dde7e2)"
      refute html =~ "<hr"
    end

    test "email mode keeps a plain <hr> (regression)" do
      html = Render.render_block(@divider, %{style: :email})

      assert html ==
               ~s(<hr style="border:none;border-top:1px solid #dde7e2;margin:30px 0 26px">)

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
               ~s(<hr style="border:none;border-top:1px solid #dde7e2;margin:30px 0 26px">)
    end

    test "bold heading email output is byte-identical" do
      block = %{"id" => "h1", "type" => "heading", "level" => 1, "text" => "Title"}

      assert Render.render_block(block) ==
               ~s(<h1 style="font-family:'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif;color:#15211d;letter-spacing:-0.02em;line-height:1.15;margin:0 0 12px;font-weight:600;font-size:32px">Title</h1>)
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

  # Every style emits semantic <ul>/<ol>/<li> via PdList/PdListItem so rendered
  # papers and email retain list structure for assistive technology and
  # copy-paste. Article structure stays bare for the paper stylesheet; email
  # keeps its Outlook-safe spacing inline on the semantic elements.
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

    test "email/default mode emits inline-styled semantic list elements" do
      block = %{"id" => "L", "type" => "list", "items" => @list_items}

      expected =
        ~s(<ul style="margin:0 0 24px;padding-left:24px;) <>
          ~s(font-family:'Iowan Old Style','Palatino Linotype',Palatino,Georgia,serif;) <>
          ~s(color:#15211d;line-height:1.7">) <>
          ~s(<li style="margin:4pt 0 0"><span>a</span></li>) <>
          ~s(<li style="margin:4pt 0 0"><span>b</span></li>) <>
          ~s(<li style="margin:4pt 0 0"><span>c</span></li></ul>)

      assert Render.render_block(block) == expected
      assert Render.render_block(block, %{style: :email}) == expected
      refute expected =~ "• "
      refute expected =~ "flex-direction"
    end

    test "empty items remain semantic empty lists in article and email" do
      empty = %{"id" => "L", "type" => "list", "items" => []}

      article = Render.render_block(empty, %{style: :article})
      assert article =~ "<ul"
      assert String.ends_with?(article, "></ul>")
      refute article =~ "<li"

      email = Render.render_block(empty)
      assert email =~ "<ul"
      assert String.ends_with?(email, "></ul>")
      refute email =~ "<li"
      refute email =~ "flex-direction"
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

  # ── the `:email` body-paragraph stamp ───────────────────────────────────────
  #
  # `Render.render_block/1` defaults to the `:email` style, whose `<p>` carries
  # its type INLINE because mail clients strip stylesheets (walk.ex body_type/2).
  # These expectations read the stamp from the PALETTE rather than re-typing the
  # hex/font, so a theme override moves the test with the render.
  defp email_p(inner) do
    pal = Barkpark.PortableDoc.Render.Palettes.email_palette()

    ~s(<p style="margin:0 0 16px;font-family:#{pal.font_body};font-size:17px;) <>
      ~s(line-height:1.55;color:#{pal.text}">) <> inner <> "</p>"
  end
end
