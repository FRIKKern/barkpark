defmodule BarkparkWeb.Studio.PaperEditor.WordCountTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "footer recursively counts visible Steps bodies but excludes row titles" do
    blocks = [
      paragraph("outside", "one two three four five six seven eight nine ten"),
      %{
        "id" => "steps",
        "type" => "steps",
        "steps" => [
          %{
            "id" => "row",
            "title" => "Excluded title words stay excluded",
            "children" => [
              paragraph(
                "body",
                "eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three twenty-four twenty-five"
              )
            ]
          }
        ]
      }
    ]

    assert footer_text(blocks) =~ "25 words"
    assert footer_text(blocks) =~ "2 blocks"
  end

  test "footer uses Steps children as the visible body and blocks only as its fallback" do
    blocks = [
      %{
        "id" => "steps",
        "type" => "steps",
        "steps" => [
          %{
            "id" => "children-row",
            "title" => "Excluded row title",
            "children" => [paragraph("visible", "one two three")],
            "blocks" => [paragraph("shadow", "shadow words must not count")]
          },
          %{
            "id" => "blocks-row",
            "title" => "Another excluded title",
            "blocks" => [paragraph("fallback", "four five")]
          }
        ]
      }
    ]

    assert footer_text(blocks) =~ "5 words"
  end

  defp footer_text(blocks) do
    render_component(&PaperEditor.paper_block_editor/1, slug: "word-count", blocks: blocks)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-test-id="bp-paper-footer"]))
    |> LazyHTML.text()
  end

  defp paragraph(id, words) do
    %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => words}]
    }
  end
end
