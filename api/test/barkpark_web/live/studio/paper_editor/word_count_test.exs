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

  test "footer counts only reader-visible authored form copy" do
    blocks = [
      %{
        "id" => "survey-id-must-not-count",
        "type" => "form",
        "kind" => "questionnaire-kind-must-not-count",
        "unknown" => "unknown metadata must not count",
        "questions" => [
          %{
            "id" => "answer-id-must-not-count",
            "prompt" => "Pick one",
            "type" => "single",
            "rationale" => "Helpful context",
            "recommendation" => "Choose wisely",
            "options" => ["Alpha choice", "Beta"],
            "unknown" => "ignored question metadata"
          },
          %{
            "id" => "explanation",
            "prompt" => "Explain now",
            "type" => "text",
            "options" => ["Dormant choices stay hidden"],
            "scale" => %{"min" => "hidden", "max" => "metadata"}
          },
          %{
            "id" => "legacy",
            "prompt" => "Legacy prompt",
            "type" => "unknown-type",
            "options" => ["Also dormant"]
          }
        ]
      }
    ]

    assert footer_text(blocks) =~ "13 words"
    assert footer_text(blocks) =~ "1 block"
  end

  test "footer safely ignores malformed form structures and inactive choice metadata" do
    blocks = [
      %{
        "id" => "malformed",
        "type" => "questionnaire",
        "questions" => [
          %{
            "id" => %{"not" => "visible"},
            "prompt" => %{"not" => "visible"},
            "type" => "single",
            "rationale" => ["not visible"],
            "recommendation" => %{"not" => "visible"},
            "options" => %{"not" => "visible"}
          },
          "not a question"
        ]
      },
      %{"id" => "scalar", "type" => "form", "questions" => "not visible"}
    ]

    assert footer_text(blocks) =~ "0 words"
    assert footer_text(blocks) =~ "2 blocks"
  end

  test "footer counts only a standalone Action's visible label" do
    blocks = [
      %{
        "id" => "action-id-must-not-count",
        "type" => "action",
        "label" => "Read verified report",
        "href" => "Destination metadata must not count",
        "priority" => "Priority metadata must not count",
        "unknown" => "Unknown action metadata must not count"
      }
    ]

    assert footer_text(blocks) =~ "3 words"
    assert footer_text(blocks) =~ "1 block"
  end

  test "footer counts a nested Action label and ignores malformed labels and metadata" do
    blocks = [
      %{
        "id" => "grid",
        "type" => "section",
        "layout" => %{"mode" => "grid", "tracks" => 2},
        "blocks" => [
          %{
            "id" => "nested-action",
            "type" => "action",
            "label" => "Open nested proof",
            "href" => "Nested destination metadata must not count",
            "priority" => "Nested priority metadata must not count",
            "unknown" => "Nested unknown metadata must not count"
          },
          %{
            "id" => "malformed-action",
            "type" => "action",
            "label" => %{"not" => "visible"},
            "href" => "Malformed destination metadata must not count"
          }
        ]
      }
    ]

    assert footer_text(blocks) =~ "3 words"
    assert footer_text(blocks) =~ "1 block"
  end

  test "footer counts reader-visible Card copy inside a grid and follows chrome edits" do
    card = %{
      "id" => "card-id-must-not-count",
      "type" => "card",
      "tone" => "info-must-not-count",
      "card-meta" => "unknown card metadata must not count",
      "slots" => %{
        "title" => [
          %{
            "type" => "heading",
            "text" => "Card title before editing",
            "level" => 3,
            "unknown" => "unknown title metadata must not count"
          }
        ],
        "body" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Card body before editing."}],
            "unknown" => "unknown body metadata must not count"
          }
        ],
        "media" => [
          %{
            "type" => "image",
            "src" => "/media/source-must-not-count.png",
            "alt" => "media description must not count"
          }
        ],
        "action" => [
          %{
            "type" => "action",
            "label" => "Read more",
            "href" => "/destination-must-not-count",
            "priority" => "primary-must-not-count"
          }
        ],
        "future" => [paragraph("hidden", "unknown slot words must not count")]
      }
    }

    nested = [
      %{
        "id" => "grid",
        "type" => "section",
        "layout" => %{"mode" => "grid", "tracks" => 3},
        "blocks" => [card]
      }
    ]

    assert footer_text(nested) =~ "10 words"

    edited =
      nested
      |> put_in(
        [Access.at(0), "blocks", Access.at(0), "slots", "title", Access.at(0), "text"],
        "Public Card title survives rapid editing"
      )
      |> put_in(
        [Access.at(0), "blocks", Access.at(0), "slots", "body", Access.at(0), "content"],
        [%{"type" => "text", "value" => "Public Card body survives rapid editing."}]
      )

    assert footer_text(edited) =~ "14 words"
  end

  test "footer safely ignores malformed Card slot shapes" do
    blocks = [
      %{"id" => "scalar-slots", "type" => "card", "slots" => "not visible"},
      %{
        "id" => "malformed-known-slots",
        "type" => "card",
        "slots" => %{
          "title" => "not a slot list",
          "body" => [%{"type" => "paragraph", "content" => %{"not" => "visible"}}],
          "action" => [%{"type" => "action", "label" => %{"not" => "visible"}}],
          "future" => [paragraph("hidden", "unknown slot words")]
        }
      }
    ]

    assert footer_text(blocks) =~ "0 words"
    assert footer_text(blocks) =~ "2 blocks"
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
