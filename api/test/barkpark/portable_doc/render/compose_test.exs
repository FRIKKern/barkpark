defmodule Barkpark.PortableDoc.Render.ComposeTest do
  # Pure, in-process — no DB, no plugins needed.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Compose

  describe "compose_block/1 (email/default style)" do
    test "heading emits a semantic PdHeading in every style (email included)" do
      b = %{"type" => "heading", "level" => 1, "text" => "Hello"}

      assert Compose.compose_block(b) == %{
               "kind" => "PdHeading",
               "level" => 1,
               "children" => ["Hello"]
             }
    end

    test "heading level defaults to 2 for unknown level" do
      b = %{"type" => "heading", "text" => "X", "level" => 99}
      result = Compose.compose_block(b, :article)
      assert result == %{"kind" => "PdHeading", "level" => 2, "children" => ["X"]}
    end

    test "heading emits semantic PdHeading in article mode" do
      b = %{"type" => "heading", "text" => "Title", "level" => 1}
      result = Compose.compose_block(b, :article)
      assert result == %{"kind" => "PdHeading", "level" => 1, "children" => ["Title"]}
    end

    test "heading renders a persisted PortableDoc inline content array" do
      b = %{
        "type" => "heading",
        "level" => 1,
        "content" => [%{"type" => "text", "value" => "Portable title"}]
      }

      assert Compose.compose_block(b, :article) == %{
               "kind" => "PdHeading",
               "level" => 1,
               "children" => ["Portable title"]
             }
    end

    test "divider emits PdHr in email mode" do
      assert Compose.compose_block(%{"type" => "divider"}) == %{"kind" => "PdHr"}
    end

    test "divider emits _raw html in article mode" do
      result = Compose.compose_block(%{"type" => "divider"}, :article)
      assert result["kind"] == "_raw"
      assert is_binary(result["html"])
    end

    test "action emits PdButton with href and label" do
      b = %{
        "type" => "action",
        "href" => "https://example.com",
        "label" => "Go",
        "priority" => "primary"
      }

      result = Compose.compose_block(b)

      assert result == %{
               "kind" => "PdButton",
               "href" => "https://example.com",
               "label" => "Go",
               "priority" => "primary"
             }
    end

    # SUPERSEDED BY THE EMPTY-CHROME INVARIANT, not deleted. This test pinned the
    # DEFECT: an action with neither key composed to a PdButton whose href and
    # label were both "", which the walker painted as
    # `<a href="#" class="bp-button"></a>` — a zero-width CLICKABLE control that
    # goes nowhere and says nothing. Its real content (don't crash on missing
    # keys; `priority` stays absent) is kept below, re-aimed at the new answer:
    # blank composes to the empty `_raw` node in every style arm.
    test "action missing keys composes to the empty raw node, not an empty button" do
      b = %{"type" => "action"}

      assert Compose.compose_block(b) == %{"kind" => "_raw", "html" => ""}
      assert Compose.compose_block(b, :article) == %{"kind" => "_raw", "html" => ""}
      assert Render.render_block(b, %{style: :article}) == ""
      assert Render.render_block(b, %{style: :email}) == ""
    end

    # The half of the old pin that still describes live behaviour: `priority` is
    # CHROME, so it neither survives into a blank block nor rescues it.
    test "an action with a label keeps defaulting the absent href and priority" do
      result = Compose.compose_block(%{"type" => "action", "label" => "Go"})

      assert result["kind"] == "PdButton"
      assert result["href"] == ""
      assert result["label"] == "Go"
      assert result["priority"] == nil
    end

    test "image emits PdImage with optional dimensions" do
      b = %{
        "type" => "image",
        "src" => "https://example.com/img.png",
        "alt" => "A pic",
        "width" => 400,
        "height" => 300
      }

      result = Compose.compose_block(b)
      assert result["kind"] == "PdImage"
      assert result["src"] == "https://example.com/img.png"
      assert result["alt"] == "A pic"
      assert result["width"] == 400
      assert result["height"] == 300
    end

    test "image without optional dims omits width/height keys" do
      b = %{"type" => "image", "src" => "x.png", "alt" => ""}
      result = Compose.compose_block(b)
      refute Map.has_key?(result, "width")
      refute Map.has_key?(result, "height")
    end

    test "embed block composes to PdEmbed carrying the raw target" do
      b = %{"type" => "embed", "target" => "Note A"}
      assert Compose.compose_block(b) == %{"kind" => "PdEmbed", "target" => "Note A"}
    end

    test "embed with a missing/blank target still composes (renders unresolved)" do
      assert Compose.compose_block(%{"type" => "embed"}) ==
               %{"kind" => "PdEmbed", "target" => ""}

      assert Compose.compose_block(%{"type" => "embed", "target" => ""}) ==
               %{"kind" => "PdEmbed", "target" => ""}
    end

    test "list in email mode preserves semantic PdList/PdListItem structure" do
      b = %{"type" => "list", "ordered" => false, "items" => [["Apple"], ["Banana"]]}
      result = Compose.compose_block(b)
      assert result["kind"] == "PdList"
      assert result["ordered"] == false
      [first | _] = result["children"]
      assert first["kind"] == "PdListItem"
      [text_node] = first["children"]
      assert text_node["children"] == ["Apple"]
    end

    test "list in article mode emits PdList with PdListItem children" do
      b = %{"type" => "list", "ordered" => true, "items" => [["First"], ["Second"]]}
      result = Compose.compose_block(b, :article)
      assert result["kind"] == "PdList"
      assert result["ordered"] == true
      assert length(result["children"]) == 2
      [item | _] = result["children"]
      assert item["kind"] == "PdListItem"
    end

    # RENDER BYTE-IDENTITY (obsidian list-item-crash normalize proof). A legacy
    # FLAT-STRING list item and its normalized inline-text-array form compose to
    # the BYTE-IDENTICAL PdNode tree — `compose_inline_children("x")` and
    # `compose_inline_children([%{"type"=>"text","value"=>"x"}])` both yield
    # ["x"]. So normalizing string→inline in the STORED data is provably
    # render-preserving (`body_html` is byte-identical before and after).
    test "string-item list composes IDENTICALLY to its normalized inline-array form (email mode)" do
      string_items = %{"type" => "list", "ordered" => false, "items" => ["one", "two"]}

      inline_items = %{
        "type" => "list",
        "ordered" => false,
        "items" => [
          [%{"type" => "text", "value" => "one"}],
          [%{"type" => "text", "value" => "two"}]
        ]
      }

      assert Compose.compose_block(string_items) == Compose.compose_block(inline_items)
    end

    test "string-item list composes IDENTICALLY to its normalized inline-array form (article mode)" do
      string_items = %{"type" => "list", "ordered" => true, "items" => ["a", "b"]}

      inline_items = %{
        "type" => "list",
        "ordered" => true,
        "items" => [
          [%{"type" => "text", "value" => "a"}],
          [%{"type" => "text", "value" => "b"}]
        ]
      }

      assert Compose.compose_block(string_items, :article) ==
               Compose.compose_block(inline_items, :article)
    end

    # The end-to-end proof the backfill relies on: a whole-paper render of a
    # string-item list yields BYTE-IDENTICAL body_html to the normalized form, in
    # the article palette (the live paper render). This is what makes the data
    # write provably render-preserving — body_html does not change.
    test "render_blocks: string-item list → BYTE-IDENTICAL body_html as the normalized form (article)" do
      opts = %{style: :article}

      string_blocks = [
        %{"id" => "l-1", "type" => "list", "ordered" => false, "items" => ["x", "y"]}
      ]

      inline_blocks = [
        %{
          "id" => "l-1",
          "type" => "list",
          "ordered" => false,
          "items" => [
            [%{"type" => "text", "value" => "x"}],
            [%{"type" => "text", "value" => "y"}]
          ]
        }
      ]

      assert Render.render_blocks(string_blocks, opts) ==
               Render.render_blocks(inline_blocks, opts)
    end

    test "byline with items joins with ·" do
      b = %{"type" => "byline", "items" => ["Alice", "Bob"]}
      result = Compose.compose_block(b, :email)
      assert result["children"] == ["Alice · Bob"]
    end

    test "byline in article mode emits PdParagraph" do
      b = %{"type" => "byline", "text" => "Alice"}
      result = Compose.compose_block(b, :article)
      assert result["kind"] == "PdParagraph"
      assert result["_role"] == "byline"
    end

    test "field-boolean true shows Yes" do
      b = %{"type" => "field-boolean", "label" => "Active", "value" => true}
      result = Compose.compose_block(b)
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["Yes"]
    end

    test "field-boolean false shows No" do
      b = %{"type" => "field-boolean", "label" => "Active", "value" => false}
      result = Compose.compose_block(b)
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["No"]
    end

    test "field-reference with no value shows em-dash" do
      b = %{"type" => "field-reference", "label" => "Ref", "value" => ""}
      result = Compose.compose_block(b)
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["—"]
    end

    test "field-reference falls back to raw id when no _ref_title" do
      b = %{"type" => "field-reference", "label" => "Ref", "value" => "doc-123"}
      result = Compose.compose_block(b)
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["doc-123"]
    end

    test "field-reference uses _ref_title when present" do
      b = %{
        "type" => "field-reference",
        "label" => "Ref",
        "value" => "doc-123",
        "_ref_title" => "My Doc"
      }

      result = Compose.compose_block(b)
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["My Doc"]
    end

    test "sheet block with no snapshot emits empty PdSheet" do
      b = %{"type" => "sheet"}
      result = Compose.compose_block(b)
      assert result["kind"] == "PdSheet"
      assert result["rows"] == []
    end

    test "sheet block with snapshot rows and head" do
      b = %{
        "type" => "sheet",
        "snapshot" => %{
          "head" => ["Name", "Age"],
          "rows" => [["Alice", 30], ["Bob", 25]]
        }
      }

      result = Compose.compose_block(b)
      assert result["kind"] == "PdSheet"
      assert result["head"] == ["Name", "Age"]
      assert result["rows"] == [["Alice", "30"], ["Bob", "25"]]
    end

    # PROCESS RULE: this test used to assert the old `raise ArgumentError` crash
    # contract. Papers are schemaless, so a raw API/SDK/CLI mutate can persist an
    # unknown block type; crashing there took down every render surface (Studio
    # crash-loop, ingest 500, body_html rebuild 500). The engine now degrades to
    # a visible placeholder — the Go twin (pdrender.go fallbackRenderer) already
    # did. Rewritten to assert the degrade node.
    test "unknown block type degrades to a visible bp-unknown-block node (no raise)" do
      result = Compose.compose_block(%{"type" => "nonexistent-type"})
      assert result["kind"] == "_raw"
      assert result["html"] =~ ~s(class="bp-unknown-block")
      assert result["html"] =~ "Unsupported block: nonexistent-type"
    end
  end

  # A paragraph / ingress / pullquote authored the HEADING way — a bare `text`
  # string instead of a `content` inline-node array — used to render as an EMPTY
  # <p> on the /papers reader, because these three clauses read `content` only.
  # The Hollow publish predicate counts a bare-`text` paragraph as content, so
  # such a paragraph passed the publish gate as "has content" yet showed nothing.
  # The `paragraph_inline/1` fallback fixes it while staying strictly additive:
  # `content`-form and empty scaffolds compose byte-identically.
  describe "compose_block bare-`text` fallback for paragraph / ingress / pullquote" do
    test "paragraph with a bare `text` composes to a PdParagraph carrying the text (email)" do
      b = %{"type" => "paragraph", "text" => "Hi"}
      assert Compose.compose_block(b) == %{"kind" => "PdParagraph", "children" => ["Hi"]}
    end

    test "paragraph with a bare `text` composes IDENTICALLY to its `content` inline-array form" do
      text_form = %{"type" => "paragraph", "text" => "Hi"}

      content_form = %{
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Hi"}]
      }

      # The bugfix: the text-form no longer collapses to [] children.
      assert Compose.compose_block(text_form) == Compose.compose_block(content_form)

      # And the content-form is byte-UNCHANGED from what it has always emitted.
      assert Compose.compose_block(content_form) ==
               %{"kind" => "PdParagraph", "children" => ["Hi"]}
    end

    test "a `content`-form paragraph ignores a stray `text` sibling (content wins, byte-unchanged)" do
      b = %{
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "real"}],
        "text" => "ignored"
      }

      assert Compose.compose_block(b) == %{"kind" => "PdParagraph", "children" => ["real"]}
    end

    test "an empty scaffold paragraph (no content, no text) stays [] children (byte-identical)" do
      # The fresh-paper `tpl-body` seed and any empty paragraph must NOT change:
      # paragraph_inline/1 returns [] exactly as compose_inline_children([]) did.
      assert Compose.compose_block(%{"type" => "paragraph"}) ==
               %{"kind" => "PdParagraph", "children" => []}

      assert Compose.compose_block(%{"type" => "paragraph", "content" => []}) ==
               %{"kind" => "PdParagraph", "children" => []}

      assert Compose.compose_block(%{"type" => "paragraph", "text" => ""}) ==
               %{"kind" => "PdParagraph", "children" => []}

      # A non-string `text` (map/list a raw mutate may persist) falls through
      # to [] rather than being coerced into a leaf.
      assert Compose.compose_block(%{"type" => "paragraph", "text" => %{}}) ==
               %{"kind" => "PdParagraph", "children" => []}
    end

    test "ingress with a bare `text` renders its text (text-fallback), content-form unchanged" do
      text_form = Compose.compose_block(%{"type" => "ingress", "text" => "Lead"}, :article)
      assert text_form["kind"] == "PdParagraph"
      assert text_form["_role"] == "ingress"
      assert text_form["children"] == ["Lead"]

      content_form =
        Compose.compose_block(
          %{"type" => "ingress", "content" => [%{"type" => "text", "value" => "Lead"}]},
          :article
        )

      assert content_form["children"] == ["Lead"]
    end

    test "pullquote with a bare `text` renders its text (text-fallback), content-form unchanged" do
      text_form = Compose.compose_block(%{"type" => "pullquote", "text" => "Quote"}, :article)
      assert text_form["kind"] == "PdParagraph"
      assert text_form["_role"] == "pullquote"
      assert text_form["italic"] == true
      assert text_form["children"] == ["Quote"]

      content_form =
        Compose.compose_block(
          %{"type" => "pullquote", "content" => [%{"type" => "text", "value" => "Quote"}]},
          :article
        )

      assert content_form["children"] == ["Quote"]
    end

    # The end-to-end proof: a whole-paper render of a bare-`text` paragraph emits
    # a real <p> carrying the prose (was <p></p> before the fix), while the
    # `content`-form render is byte-identical to today.
    test "render_blocks: a bare-`text` paragraph emits a <p> containing its prose (article)" do
      opts = %{style: :article}

      text_html =
        Render.render_blocks(
          [%{"id" => "p-1", "type" => "paragraph", "text" => "Some prose"}],
          opts
        )

      assert text_html =~ "<p"
      assert text_html =~ "Some prose"
      refute text_html =~ "<p></p>"

      content_html =
        Render.render_blocks(
          [
            %{
              "id" => "p-1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Some prose"}]
            }
          ],
          opts
        )

      # View↔Edit / cross-form parity: the two authoring shapes render identically.
      assert text_html == content_html
    end

    test "render_blocks: an empty scaffold stays authorable but emits no reader HTML" do
      block = %{"id" => "tpl-body", "type" => "paragraph", "content" => []}

      assert Compose.compose_block(block, :article) ==
               %{"kind" => "PdParagraph", "children" => []}

      assert Render.render_blocks([block], %{style: :article}) == ""
      assert Render.render_blocks([block], %{style: :email}) == ""
    end
  end

  # A schemaless paper can carry a block type this engine has no clause for, a
  # map with no `"type"` at all, or (inside a section / figure child, which call
  # compose_block directly) a non-map entry. Each USED to FunctionClauseError /
  # ArgumentError and 500 every render surface. They now degrade to a visible
  # `bp-unknown-block` placeholder so a poisoned sibling can't sink the render.
  describe "compose_block/2 graceful degrade for unknown / malformed blocks" do
    test "unknown block type HTML-escapes the type name (no markup injection)" do
      result = Compose.compose_block(%{"type" => "<script>", "text" => "x"}, :article)
      assert result["kind"] == "_raw"
      assert result["html"] =~ ~s(class="bp-unknown-block")
      assert result["html"] =~ "Unsupported block: &lt;script&gt;"
      refute result["html"] =~ "<script>"
    end

    test "unknown block type surfaces the type name for the reader" do
      result = Compose.compose_block(%{"type" => "future-widget", "text" => "x"})
      assert result["html"] =~ "Unsupported block: future-widget"
    end

    test "typeless map degrades to an 'invalid block' placeholder" do
      result = Compose.compose_block(%{"text" => "x"})
      assert result["kind"] == "_raw"
      assert result["html"] == ~s(<div class="bp-unknown-block">invalid block</div>)
    end

    test "non-map entry (string or number) degrades instead of FunctionClauseError" do
      for garbage <- ["garbage", 42] do
        result = Compose.compose_block(garbage, :email)
        assert result["kind"] == "_raw"
        assert result["html"] == ~s(<div class="bp-unknown-block">invalid block</div>)
      end
    end

    # End-to-end through the public render pipeline: a poisoned sibling block
    # must not take down its healthy neighbours. render_blocks over a valid
    # paragraph + an unknown-type block still produces the paragraph's HTML AND
    # the degrade placeholder.
    test "render_blocks: a poisoned unknown-type sibling degrades, healthy blocks still render" do
      blocks = [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "alive"}]
        },
        %{"id" => "x-1", "type" => "future-widget", "text" => "boom"}
      ]

      html = Render.render_blocks(blocks, %{style: :article})
      assert html =~ "alive"
      assert html =~ ~s(class="bp-unknown-block")
      assert html =~ "Unsupported block: future-widget"
    end

    # A non-map / typeless child inside a SECTION reaches compose_block directly
    # (bypassing render_block's is_map guard). It too degrades through the public
    # render pipeline rather than crashing the whole section.
    test "render_blocks: a non-map child inside a section degrades in place" do
      blocks = [
        %{
          "id" => "s-1",
          "type" => "section",
          "title" => "Sec",
          "blocks" => ["garbage", %{"nope" => true}]
        }
      ]

      html = Render.render_blocks(blocks, %{style: :article})
      assert html =~ "Sec"
      assert html =~ ~s(class="bp-unknown-block")
      assert html =~ "invalid block"
    end
  end

  # A JSON object / array landing in an author-controlled leaf field (text /
  # caption / src / value / label / byline items / sheet cells) used to raise
  # Protocol.UndefinedError (map) or emit a garbled charlist (small-int list),
  # 500-ing the public /papers reader. `stringish/1` degrades them to "" while
  # keeping every working document byte-identical (binaries pass through,
  # numbers stringify unchanged).
  describe "compose_block/2 fail-soft coercion on author-controlled leaf fields" do
    test "eyebrow text as a map degrades to empty children (no 500)" do
      result = Compose.compose_block(%{"type" => "eyebrow", "text" => %{}}, :email)
      assert result["kind"] == "PdParagraph"
      assert result["children"] == [""]
    end

    test "eyebrow text as a list degrades to empty children" do
      result = Compose.compose_block(%{"type" => "eyebrow", "text" => [1, 2]}, :email)
      assert result["children"] == [""]
    end

    test "byline text as a map degrades to empty children" do
      result = Compose.compose_block(%{"type" => "byline", "text" => %{}}, :email)
      assert result["children"] == [""]
    end

    test "embed target as a map degrades to an empty target" do
      assert Compose.compose_block(%{"type" => "embed", "target" => %{}}) ==
               %{"kind" => "PdEmbed", "target" => ""}
    end

    test "field-string value as a map or list degrades to an empty value node" do
      [_label, map_val] =
        Compose.compose_block(%{"type" => "field-string", "label" => "L", "value" => %{}})[
          "children"
        ]

      assert map_val["children"] == [""]

      [_label2, list_val] =
        Compose.compose_block(%{"type" => "field-string", "label" => "L", "value" => [1, 2]})[
          "children"
        ]

      assert list_val["children"] == [""]
    end

    test "field-image value as a map degrades to the No image placeholder (no 500)" do
      result = Compose.compose_block(%{"type" => "field-image", "label" => "Img", "value" => %{}})
      [_label, value_node] = result["children"]
      assert value_node["children"] == ["No image"]
    end

    test "field-datetime value as a list degrades to an empty value node (no 500)" do
      result =
        Compose.compose_block(%{"type" => "field-datetime", "label" => "When", "value" => [1, 2]})

      [_label, value_node] = result["children"]
      assert value_node["children"] == [""]
    end

    test "diagram with map source and list caption composes to _raw html without raising" do
      result =
        Compose.compose_block(
          %{"type" => "diagram", "source" => %{}, "caption" => [1, 2]},
          :article
        )

      assert result["kind"] == "_raw"
      assert is_binary(result["html"])
    end

    test "sheet snapshot head and row cells that are maps/lists degrade to empty strings" do
      b = %{
        "type" => "sheet",
        "snapshot" => %{"head" => [%{}, "ok"], "rows" => [[[1, 2], %{}]]}
      }

      result = Compose.compose_block(b)
      assert result["head"] == ["", "ok"]
      assert result["rows"] == [["", ""]]
    end

    test "a plain-integer field value still renders as its decimal string" do
      [_label, value_node] =
        Compose.compose_block(%{"type" => "field-string", "label" => "L", "value" => 42})[
          "children"
        ]

      assert value_node["children"] == ["42"]
    end

    test "byline integer items still stringify to their decimals" do
      result = Compose.compose_block(%{"type" => "byline", "items" => [1, 2]}, :email)
      assert result["children"] == ["1 · 2"]
    end
  end

  # The api-endpoint method badge derives its modifier class from the
  # user-controlled `method` field. The token MUST be a fail-closed [a-z0-9-]
  # slug — never the raw/escaped method — or a crafted method breaks out of the
  # class attribute into live markup (XSS). One HTML producer (compose_block for
  # :article, :email, and Studio/Edit all route here), so these render-boundary
  # assertions cover every Elixir surface. Mutation-check: revert the slug fix
  # in api_endpoint_method_class/1 and the breakout test below REDS.
  describe "compose_block api-endpoint method-class XSS fail-closed slug" do
    test "a quote+tag breakout method cannot escape the class attribute" do
      payload = ~s|"><img src=x onerror=alert(1)>|

      html =
        Compose.compose_block(
          %{"type" => "api-endpoint", "method" => payload, "path" => "/x"},
          :article
        )["html"]

      # No attribute breakout: the sanitized class token carries only inert
      # [a-z0-9-] chars, so no `"` closes the class= and no live tag appears.
      refute html =~ "<img"
      # No live event-handler attribute (the slug may contain the inert letters
      # "onerror" but never as an `onerror=` attribute — that needs a real break).
      refute html =~ "onerror="
      refute html =~ ~s(class="bp-api-endpoint__method bp-api-endpoint__method--"><)
      # The badge TEXT is still HTML-escaped (visible, inert). `method` is
      # upcased before escaping, so the escaped text is uppercase.
      assert html =~ "&quot;&gt;&lt;IMG SRC=X ONERROR=ALERT(1)&gt;"
      # The class token stripped everything but [a-z0-9-].
      assert html =~ "bp-api-endpoint__method--imgsrcxonerroralert1"
    end

    test "legit HTTP methods keep their byte-identical modifier class" do
      for {m, slug} <- [
            {"GET", "get"},
            {"POST", "post"},
            {"PUT", "put"},
            {"PATCH", "patch"},
            {"DELETE", "delete"}
          ] do
        html =
          Compose.compose_block(
            %{"type" => "api-endpoint", "method" => m, "path" => "/x"},
            :article
          )["html"]

        assert html =~
                 ~s(<span class="bp-api-endpoint__method bp-api-endpoint__method--#{slug}">#{m}</span>)
      end
    end

    test "hyphenated IANA methods survive as lowercase slugs" do
      html =
        Compose.compose_block(
          %{"type" => "api-endpoint", "method" => "VERSION-CONTROL", "path" => "/x"},
          :article
        )["html"]

      assert html =~ "bp-api-endpoint__method--version-control"
    end

    test "an all-stripped method omits the modifier class (base only)" do
      html =
        Compose.compose_block(
          %{"type" => "api-endpoint", "method" => "!!!", "path" => "/x"},
          :article
        )["html"]

      assert html =~ ~s(<span class="bp-api-endpoint__method">)
      refute html =~ "bp-api-endpoint__method--"
    end
  end

  # ── eyebrow content[] (task-993d136b0fbf2fd1) ──────────────────────────────
  #
  # The eyebrow clause read the flat `text` field ALONE
  # (`[stringish(Map.get(b, "text", ""))]`) while its three sibling prose
  # clauses (ingress / paragraph / pullquote) read `content` first through
  # `paragraph_inline/1`. An eyebrow persisted as an inline array — the canvas
  # node-view's own shape, and what `@barkpark/react` renders — composed to
  # `[""]` and served a BLANK kicker. 3 such blocks are live on guerrilla
  # (full-corpus census, 537 published papers, 2026-07-25).
  describe "compose_block/2 eyebrow reads content[] like its sibling prose clauses" do
    test "an eyebrow with an inline content array composes REAL text children" do
      b = %{
        "type" => "eyebrow",
        "content" => [%{"type" => "text", "value" => "OPS · LIVE"}]
      }

      result = Compose.compose_block(b, :article)
      assert result["kind"] == "PdParagraph"
      assert result["_role"] == "eyebrow"
      assert result["children"] == ["OPS · LIVE"]
    end

    test "an eyebrow's content[] survives to the rendered article HTML" do
      html =
        Render.render_blocks(
          [
            %{
              "id" => "e-1",
              "type" => "eyebrow",
              "content" => [%{"type" => "text", "value" => "FIELD NOTES"}]
            }
          ],
          %{style: :article}
        )

      assert html =~ ~s(class="bp-role-eyebrow")
      assert html =~ "FIELD NOTES"
    end

    test "content[] and the flat text spelling of the SAME eyebrow compose identically" do
      content_form = %{
        "type" => "eyebrow",
        "content" => [%{"type" => "text", "value" => "Week 35"}]
      }

      flat_form = %{"type" => "eyebrow", "text" => "Week 35"}

      assert Compose.compose_block(content_form, :article) ==
               Compose.compose_block(flat_form, :article)
    end

    test "content[] WINS over a stale flat text (the content ⟂ text law)" do
      b = %{
        "type" => "eyebrow",
        "text" => "stale",
        "content" => [%{"type" => "text", "value" => "fresh"}]
      }

      assert Compose.compose_block(b, :article)["children"] == ["fresh"]
    end

    test "an eyebrow's marked-up content[] keeps the mark (not flattened away)" do
      b = %{
        "type" => "eyebrow",
        "content" => [
          %{"type" => "text", "value" => "A "},
          %{"type" => "strong", "children" => [%{"type" => "text", "value" => "B"}]}
        ]
      }

      children = Compose.compose_block(b, :article)["children"]
      assert length(children) == 2
      assert Enum.at(children, 0) == "A "
      assert is_map(Enum.at(children, 1))
    end

    # The fail-soft the guarded form preserves: an EMPTY content array is not a
    # body, so the flat `text` still wins (and a numeric one still stringifies).
    test "an EMPTY content array falls through to the flat text, numbers included" do
      assert Compose.compose_block(
               %{"type" => "eyebrow", "content" => [], "text" => "Kicker"},
               :article
             )["children"] == ["Kicker"]

      assert Compose.compose_block(%{"type" => "eyebrow", "text" => 42}, :article)["children"] ==
               ["42"]
    end
  end
end
