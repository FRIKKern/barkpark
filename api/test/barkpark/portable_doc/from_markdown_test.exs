defmodule Barkpark.PortableDoc.FromMarkdownTest do
  @moduledoc """
  GFM → PortableDoc block mapping for the chat surface, including the two
  upgrade fences (mermaid → diagram, portabledoc → validated native blocks)
  and every fail-soft path (malformed JSON, disallowed types, parser crash).
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.PortableDoc.Render

  describe "block mapping" do
    test "headings clamp to level 3" do
      assert [%{"type" => "heading", "level" => 2, "text" => "Title"}] =
               FromMarkdown.blocks("## Title")

      assert [%{"type" => "heading", "level" => 3}] = FromMarkdown.blocks("##### Deep")
    end

    test "paragraph with bold, italic, inline code, and link" do
      [%{"type" => "paragraph", "content" => content}] =
        FromMarkdown.blocks("plain **bold** *it* `code` [go](https://x.example)")

      assert %{"type" => "text", "value" => "plain "} in content
      assert Enum.any?(content, &match?(%{"type" => "strong"}, &1))
      assert Enum.any?(content, &match?(%{"type" => "em"}, &1))
      assert Enum.any?(content, &match?(%{"type" => "code", "value" => "code"}, &1))

      assert Enum.any?(
               content,
               &match?(%{"type" => "link", "href" => "https://x.example"}, &1)
             )
    end

    test "lists keep order flag and flatten nested items inline" do
      md = """
      1. first
      2. second
         - nested
      """

      [%{"type" => "list", "ordered" => true, "items" => [first, second]}] =
        FromMarkdown.blocks(md)

      assert [%{"type" => "text", "value" => "first"}] = first
      assert Enum.any?(second, &match?(%{"value" => " — "}, &1))
    end

    test "code fence becomes a code block" do
      assert [%{"type" => "code", "value" => "IO.puts(:hi)"}] =
               FromMarkdown.blocks("```elixir\nIO.puts(:hi)\n```")
    end

    # bl-frommarkdown-fence-language. The info string is the ONLY place a
    # markdown author can say what language a fence is, and the converter used
    # to read it (to dispatch mermaid/portabledoc) and then throw it away — so
    # ```python arrived at every surface indistinguishable from ```.
    test "the fence info string is carried onto the code block as `lang`" do
      assert [%{"type" => "code", "value" => "print(1)", "lang" => "python"}] =
               FromMarkdown.blocks("```python\nprint(1)\n```")

      # `lang`, not `language`: that is the field `Blocks.default_block/1`
      # writes, `build_block_patch/2` patches and the Studio code editor reads.
      # A `language` key would be a decoy nothing consumes.
      [block] = FromMarkdown.blocks("```elixir\nIO.puts(:hi)\n```")
      assert block["lang"] == "elixir"
      refute Map.has_key?(block, "language")

      # the tilde fence spells its info string the same way
      assert [%{"lang" => "js"}] = FromMarkdown.blocks("~~~js\nlet a = 1\n~~~")
    end

    # THE BYTE-COMPAT HALF (criterion 0). A language-less fence must emit the
    # map it has always emitted — EXACTLY two keys, no `"lang" => ""` — because
    # `put_if_present/3` drops a blank lang on the write path, the pd-parity
    # golden `code.golden.json` freezes this input, and the JS emitter mirrors
    # it byte-for-byte. Asserting the KEY SET is what makes this non-vacuous: a
    # pattern match would pass with an extra key present.
    test "a language-less fence emits the IDENTICAL shape it does today" do
      for markdown <- [
            "```\nplain\n```",
            "~~~\nplain\n~~~",
            "    plain\n"
          ] do
        assert [block] = FromMarkdown.blocks(markdown)

        assert Map.keys(block) |> Enum.sort() == ["type", "value"],
               "a fence with no info string must keep the two-key shape, got #{inspect(block)}"

        assert block["type"] == "code"
      end
    end

    # The two reserved info strings still DISPATCH rather than becoming a lang.
    test "mermaid and portabledoc fences are unaffected by the lang carry" do
      assert [%{"type" => "diagram"}] = FromMarkdown.blocks("```mermaid\ngraph TD\n  A-->B\n```")

      fence = ~s([{"type":"callout","tone":"info","content":[]}])
      assert [%{"type" => "callout"}] = FromMarkdown.blocks("```portabledoc\n#{fence}\n```")

      # …and the degrade path stays a bare code block, with no `lang` invented
      # out of the reserved word.
      assert [degraded] = FromMarkdown.blocks("```portabledoc\n[{oops\n```")
      assert Map.keys(degraded) |> Enum.sort() == ["type", "value"]
    end

    test "mermaid fence becomes a diagram block" do
      assert [%{"type" => "diagram", "source" => "graph TD\n  A-->B"}] =
               FromMarkdown.blocks("```mermaid\ngraph TD\n  A-->B\n```")
    end

    test "blockquote becomes an info callout" do
      [%{"type" => "callout", "tone" => "info", "content" => content}] =
        FromMarkdown.blocks("> heads up")

      assert [%{"type" => "text", "value" => "heads up"}] = content
    end

    test "gfm table maps head and rows" do
      md = """
      | Name | N |
      | ---- | - |
      | a    | 1 |
      """

      # `head` is ONE row (a list of cells) — the same shape compose_block
      # feeds to compose_row; `rows` is a list of such rows.
      [%{"type" => "table", "head" => head_row, "rows" => [row]}] = FromMarkdown.blocks(md)
      assert [[%{"value" => "Name"}], [%{"value" => "N"}]] = head_row
      assert [[%{"value" => "a"}], [%{"value" => "1"}]] = row
    end

    test "hr becomes a divider" do
      assert [%{"type" => "divider"}] = FromMarkdown.blocks("---")
    end
  end

  describe "portabledoc fence" do
    test "valid native blocks are spliced in verbatim" do
      fence =
        ~s([{"type":"callout","tone":"success","content":[{"type":"text","value":"ok"}]},{"type":"divider"}])

      assert [%{"type" => "callout", "tone" => "success"}, %{"type" => "divider"}] =
               FromMarkdown.blocks("```portabledoc\n#{fence}\n```")
    end

    test "chart and stats block types are allowed" do
      fence = ~s([{"type":"chart","kind":"bars","series":[{"label":"s","points":[1,2]}]}])
      assert [%{"type" => "chart"}] = FromMarkdown.blocks("```portabledoc\n#{fence}\n```")
    end

    test "malformed JSON degrades to a code block" do
      assert [%{"type" => "code", "value" => "[{oops"}] =
               FromMarkdown.blocks("```portabledoc\n[{oops\n```")
    end

    test "disallowed block types reject the whole fence" do
      fence = ~s([{"type":"field-string","label":"x","value":"y"}])
      assert [%{"type" => "code"}] = FromMarkdown.blocks("```portabledoc\n#{fence}\n```")
    end

    test "a non-array payload degrades to a code block" do
      assert [%{"type" => "code"}] =
               FromMarkdown.blocks(~s(```portabledoc\n{"type":"divider"}\n```))
    end
  end

  describe "fail-soft" do
    test "model-supplied HTML never reaches the rendered output unescaped" do
      html =
        "<script>alert(1)</script>hi **there**"
        |> FromMarkdown.blocks()
        |> Render.render_blocks(%{style: :article})

      refute html =~ "<script>"
    end

    test "whole pipeline renders through the article walker without raising" do
      md = """
      ## Report

      Some **bold** and a [link](https://example.com).

      ```mermaid
      graph TD
        A-->B
      ```

      ```portabledoc
      [{"type":"stats","items":[{"type":"stat","label":"Tests","value":"28"}]}]
      ```

      | a | b |
      | - | - |
      | 1 | 2 |
      """

      html = md |> FromMarkdown.blocks() |> Render.render_blocks(%{style: :article})
      assert html =~ "Report"
      assert html =~ "mermaid"
      assert html =~ "bp-stat"
      assert html =~ "example.com"
    end
  end

  # bl-frommarkdown-fence-language, criterion 1. Carrying the field is only
  # half a fix — the row's complaint is that "a code fence gets its chrome and
  # language label" is unreachable on EVERY surface. This is the end-to-end
  # proof on a server-rendered one: markdown in, the language visible in the
  # DOM, no stub in between.
  describe "the fence language reaches a render surface" do
    import Phoenix.LiveViewTest

    alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

    test "the Studio code-block editor shows the imported fence's language" do
      [block] = FromMarkdown.blocks("```python\nprint(1)\n```")
      block = Map.put(block, "id", "b1")

      html = render_component(&PaperEditor.paper_block_fields/1, %{block: block})

      assert html =~ ~s(name="lang")

      assert html =~ ~s(value="python"),
             "the lang control must carry the imported fence's language, got: #{html}"
    end

    test "a language-less fence leaves that control empty, exactly as before" do
      [block] = FromMarkdown.blocks("```\nprint(1)\n```")
      block = Map.put(block, "id", "b1")

      html = render_component(&PaperEditor.paper_block_fields/1, %{block: block})

      assert html =~ ~s(name="lang")
      assert html =~ ~s(value="")
      refute html =~ ~s(value="python")
    end

    # THE GOLDENS DO NOT MOVE, and this is the assertion that says so at the
    # emitter rather than by trusting the fixture list. `Figures.code_block_html/1`
    # is mirrored byte-for-byte by `codeBlockHtml` in
    # js/packages/react/src/blocks/core.ts and frozen in
    # test/support/fixtures/pd-parity/code.golden.json, so the article reader's
    # `<pre>` must be identical with and without a lang — adding a label there
    # would be a cross-surface divergence, not a fix.
    test "the article reader's <pre> is byte-identical with and without a lang" do
      with_lang = FromMarkdown.blocks("```python\nprint(1)\n```")
      without = FromMarkdown.blocks("```\nprint(1)\n```")

      assert Render.render_blocks(with_lang, %{style: :article}) ==
               Render.render_blocks(without, %{style: :article})
    end
  end
end
