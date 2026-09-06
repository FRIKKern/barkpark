defmodule BarkparkWeb.Studio.PaperEditor.TypedLeafAuthoringTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "typed patches preserve configuration and reject malformed number values" do
    number = %{
      "id" => "number",
      "type" => "field-number",
      "value" => 3,
      "min" => 0,
      "max" => 10,
      "step" => 0.5,
      "unit" => "kg",
      "unknown" => "keep"
    }

    assert Blocks.build_block_patch(number, %{
             "label" => "Mass",
             "value" => "4.5",
             "min" => "1",
             "max" => "9.5",
             "step" => "0.25",
             "unit" => "kg"
           }) == %{
             "label" => "Mass",
             "value" => 4.5,
             "min" => 1,
             "max" => 9.5,
             "step" => 0.25,
             "unit" => "kg"
           }

    assert Blocks.build_block_patch(number, %{"value" => ""}) == %{"value" => nil}
    assert Blocks.build_block_patch(number, %{"value" => "4.5kg"}) == %{}
    assert Blocks.build_block_patch(number, %{"value" => "11"}) == %{}
    assert Blocks.build_block_patch(number, %{"min" => "10", "max" => "1"}) == %{}
    assert Blocks.build_block_patch(number, %{"step" => "0"}) == %{}

    assert Blocks.validate_block_patch(number, %{"value" => "4.5kg"}) ==
             {:error, :invalid_number}

    assert {:ok, %{"value" => 12, "min" => 10, "max" => 20}} =
             Blocks.validate_block_patch(number, %{
               "value" => "12",
               "min" => "10",
               "max" => "20"
             })

    blockquote = %{
      "type" => "blockquote",
      "content" => [%{"type" => "strong", "children" => []}],
      "attribution" => "Before",
      "unknown" => "keep"
    }

    assert Blocks.build_block_patch(blockquote, %{"cite" => "After"}) == %{
             "attribution" => "After"
           }

    assert Blocks.build_block_patch(blockquote, %{"cite" => "   "}) == %{
             "attribution" => nil
           }

    both_aliases = Map.put(blockquote, "cite", "Preferred")

    assert Blocks.build_block_patch(both_aliases, %{"cite" => "Replacement"}) == %{
             "cite" => "Replacement",
             "attribution" => nil
           }

    assert Blocks.build_block_patch(both_aliases, %{"cite" => ""}) == %{
             "cite" => nil,
             "attribution" => nil
           }

    assert Blocks.build_block_patch(%{"type" => "equation"}, %{
             "tex" => "E = mc^2",
             "display" => "true"
           }) == %{"tex" => "E = mc^2", "display" => true}
  end

  test "video caption rows merge unknown metadata and malformed actions cannot delete data" do
    first = %{"lang" => "en", "src" => "/captions/en.vtt", "kind" => "keep"}
    second = %{"lang" => "no", "src" => "/captions/no.vtt"}
    block = %{"type" => "video", "captions" => [first, second, "legacy"], "unknown" => "keep"}

    patch =
      Blocks.build_block_patch(block, %{
        "src" => "/media/demo.mp4",
        "poster" => "",
        "loop" => "true",
        "caption-count" => "3",
        "caption-0-lang" => "en-US",
        "caption-0-src" => "/captions/en-us.vtt",
        "caption-1-lang" => "no",
        "caption-1-src" => "/captions/no.vtt",
        "caption-action" => "remove:-1"
      })

    assert patch["src"] == "/media/demo.mp4"
    assert patch["poster"] == ""
    assert patch["loop"] == true

    assert patch["captions"] == [
             %{"lang" => "en-US", "src" => "/captions/en-us.vtt", "kind" => "keep"},
             second,
             "legacy"
           ]

    for malformed_count <- ["999999999", "2", "-1", "not-a-count"] do
      rejected =
        Blocks.build_block_patch(block, %{
          "caption-count" => malformed_count,
          "caption-0-lang" => "must-not-truncate"
        })

      refute Map.has_key?(rejected, "captions")
    end

    assert Blocks.build_block_patch(%{"type" => "video", "captions" => []}, %{
             "caption-count" => "0",
             "caption-action" => "add"
           })["captions"] == [%{"lang" => "", "src" => ""}]
  end

  test "all four blocks have canonical defaults and offered add-menu choices" do
    assert %{"type" => "field-number", "value" => nil} =
             Blocks.default_block("field-number", "number")

    assert %{"type" => "blockquote", "content" => []} =
             Blocks.default_block("blockquote", "quote")

    assert %{"type" => "equation", "tex" => "", "display" => true} =
             Blocks.default_block("equation", "equation")

    assert %{"type" => "video", "src" => "", "captions" => []} =
             Blocks.default_block("video", "video")

    html =
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "paper",
        blocks: [],
        canvas_eligible: true
      )

    for type <- ~w(field-number blockquote equation video) do
      assert html =~ ~s(value="#{type}")
    end
  end

  test "shared fields expose labelled native controls and blockquote keeps rich marks editable" do
    blocks = [
      %{
        "id" => "number",
        "type" => "field-number",
        "label" => "Weight",
        "value" => 4.5,
        "min" => 0,
        "max" => 10,
        "step" => 0.5,
        "unit" => "kg"
      },
      %{
        "id" => "quote",
        "type" => "blockquote",
        "content" => [
          %{"type" => "strong", "children" => [%{"type" => "text", "value" => "Marked"}]}
        ],
        "cite" => "Author"
      },
      %{"id" => "equation", "type" => "equation", "tex" => "x^2", "display" => true},
      %{
        "id" => "video",
        "type" => "video",
        "src" => "/media/demo.mp4",
        "poster" => "/media/poster.jpg",
        "captions" => [%{"lang" => "en", "src" => "/captions/en.vtt"}]
      }
    ]

    html =
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "paper",
        blocks: blocks,
        canvas_eligible: true
      )

    refute html =~ "blocks are not editable yet"
    assert html =~ ~s(id="field-number-form-number")
    assert html =~ ~s(phx-change="paper-edit-block")
    assert html =~ ~s(name="value")
    assert html =~ ~s(id="field-number-value-number")
    assert html =~ ~s(step="any")
    assert html =~ ~s(id="blockquote-form-quote")
    assert html =~ ~s(id="paper-ed-quote")

    encoded_quote =
      blocks
      |> Enum.at(1)
      |> Jason.encode!()
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    assert html =~ encoded_quote
    assert html =~ ~s(id="equation-form-equation")
    assert html =~ ~s(id="video-form-video")
    assert html =~ ~s(name="caption-0-src")
  end
end
