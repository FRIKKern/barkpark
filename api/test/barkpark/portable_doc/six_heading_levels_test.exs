defmodule Barkpark.PortableDoc.SixHeadingLevelsTest do
  @moduledoc """
  Six heading levels end to end on the server side (owner ruling 2026-10-03
  #63, Barkdown FRIKKern/barkdown#22, reversing the earlier three-level
  decision). The canvas authors H1–H6, so the reader renders a stored level
  4..6 as a real `<h4>`..`<h6>` (it used to fold them to `<h2>`), BPML parses
  and prints `<h4>`..`<h6>`, and the markdown importer keeps the level.

  Out-of-range levels keep their old behaviour (render as `<h2>`, BPML
  refuses), and a Card title keeps its 1..3-else-2 level so existing cards
  read the same.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.{Bpml, FromMarkdown, Render}

  defp article(block), do: Render.render_block(block, %{style: :article})

  describe "reader" do
    for level <- 4..6 do
      test "a level-#{level} heading renders as a bare <h#{level}>" do
        html = article(%{"type" => "heading", "level" => unquote(level), "text" => "Deep"})
        assert html =~ "<h#{unquote(level)}>Deep</h#{unquote(level)}>"
      end

      test "a string level #{inspect(to_string(level))} renders as <h#{level}> too" do
        html =
          article(%{"type" => "heading", "level" => to_string(unquote(level)), "text" => "S"})

        assert html =~ "<h#{unquote(level)}>S</h#{unquote(level)}>"
      end
    end

    test "an out-of-range level still renders as <h2>" do
      assert article(%{"type" => "heading", "level" => 7, "text" => "X"}) =~ "<h2>X</h2>"
    end

    test "a Card title authored at level 4 keeps reading as an h2" do
      card = %{
        "id" => "c1",
        "type" => "card",
        "slots" => %{
          "title" => [%{"type" => "heading", "level" => 4, "text" => "Reader"}],
          "body" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "B"}]}]
        }
      }

      html = article(card)
      assert html =~ "<h2>Reader</h2>"
      refute html =~ "<h4>"
    end
  end

  describe "BPML" do
    test "<h4>..<h6> parse to levels 4..6 and print back byte-identically" do
      bpml = """
      <h4 id="a">Four</h4>
      <h5 id="b" align="center">Five</h5>
      <h6 id="c">Six</h6>
      """

      assert {:ok, blocks} = Bpml.parse_blocks(bpml)

      assert Enum.map(blocks, &{&1["level"], &1["text"]}) == [
               {4, "Four"},
               {5, "Five"},
               {6, "Six"}
             ]

      assert Enum.at(blocks, 1)["align"] == "center"
      assert Bpml.print_blocks(blocks) == bpml
    end
  end

  describe "markdown import" do
    test "#### / ##### / ###### keep levels 4..6" do
      blocks = FromMarkdown.blocks("#### Four\n\n##### Five\n\n###### Six")
      assert Enum.map(blocks, & &1["level"]) == [4, 5, 6]
    end
  end
end
