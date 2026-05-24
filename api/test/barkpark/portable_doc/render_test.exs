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
      node = %{"kind" => "PdLink", "href" => "https://example.com", "children" => ["click <here>"]}

      assert Render.render_html(node, @opts) ==
               ~s(<a href="https://example.com" style="color:#1d4ed8;text-decoration:underline">click &lt;here&gt;</a>)
    end

    test "PdInlineCode escapes its value" do
      node = %{"kind" => "PdInlineCode", "value" => "a & b"}

      assert Render.render_html(node, @opts) ==
               ~s(<code style="background:#f3f4f6;padding:2px 6px;font-family:ui-monospace,Menlo,monospace;font-size:0.95em">a &amp; b</code>)
    end

    test "PdButton primary uses brand background" do
      node = %{"kind" => "PdButton", "href" => "https://x.test", "label" => "Go", "priority" => "primary"}

      assert Render.render_html(node, @opts) ==
               ~s(<a href="https://x.test" style="display:inline-block;padding:10px 20px;background:#4f46e5;color:#ffffff;text-decoration:none;font-weight:bold;border-radius:0">Go</a>)
    end

    test "PdButton secondary uses brand border" do
      node = %{"kind" => "PdButton", "href" => "https://x.test", "label" => "Go", "priority" => "secondary"}

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
          %{"id" => "p", "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Body."}]}
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
        %{"id" => "p", "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "B"}]}
      ]

      assert Render.render_blocks(blocks) ==
               ~s(<span style="font-weight:bold">A</span><span>B</span>)
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
end
