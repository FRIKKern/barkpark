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
end
