defmodule Barkpark.Content.Papers.SpacingNormAdvisoryTest do
  @moduledoc """
  The `spacing_norm` advisory's two write-path defects
  (`AuthoringWall.emit_spacing_norm_advisory/3`) — pe-w1-write-path-normalizer:

    (a) FALSE POSITIVE — the old counter treated any paragraph whose `content`
        key is absent as an empty spacer, so every text-keyed non-empty
        paragraph (`%{"type" => "paragraph", "text" => "prose"}`) drew the
        advisory. The fix honors a non-blank `text` key, exactly like
        `EpicQuality.empty_paragraph?/1` does.
    (b) BLIND SPOT — the old counter never descended into nested blocks, while
        the tagged HARD gate (`EpicQuality`) walks the whole tree: an author
        passes the advisory then 422s the moment the paper is tagged. The fix
        walks `blocks`/`children` containers.

  RED-BEFORE EVIDENCE (this exact file against the pre-fix wall, commit
  20dd241ad9): both mutation tests below FAILED — "a text-keyed non-empty
  paragraph draws NO spacing_norm advisory" drained a spacing_norm warning
  counting 1 spacer, and "an empty paragraph nested inside an expandable IS
  counted" drained no warning at all — while the flat-spacer and blank-text
  pins stayed green (the pre-existing controller pair in
  bulldocs_ingest_wall_test.exs covers the flat case end-to-end; this file
  adds the unit-level pins so the fix is proven mutation-style in one place).
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Warnings

  @dataset "spacing_norm_advisory_test"

  @good_labels %{
    "description" => "A deliberately non-trivial description used by the spacing advisory tests.",
    "tags" => [
      %{
        "tag" => "publish-wall",
        "strength" => 90,
        "rationale" => "This document exists to exercise the spacing norm advisory."
      },
      %{
        "tag" => "lifecycle",
        "strength" => 40,
        "rationale" => "Publish lifecycle mechanics are the secondary axis here."
      }
    ]
  }

  setup do
    Content.upsert_schema(
      %{"name" => "paper", "title" => "Paper", "visibility" => "public", "fields" => []},
      @dataset
    )

    Barkpark.LabelFixtures.register_tags!(@dataset, ["publish-wall", "lifecycle"])
    :ok
  end

  defp publish_article!(id, blocks, title) do
    content =
      @good_labels
      |> Map.put("style", "article")
      |> Map.put("blocks", blocks)

    {:ok, _} =
      Content.create_document(
        "paper",
        %{"_id" => id, "title" => title, "content" => content},
        @dataset
      )

    Warnings.reset()
    assert {:ok, _} = Content.publish_document(id, "paper", @dataset)
    Warnings.drain()
  end

  defp spacing_warning(warnings),
    do: Enum.find(warnings, &(&1.code == "spacing_norm"))

  defp para(text),
    do: %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  test "a text-keyed non-empty paragraph draws NO spacing_norm advisory" do
    warnings =
      publish_article!(
        "spacing-text-keyed",
        [
          %{"type" => "heading", "level" => 1, "text" => "Text-keyed prose paper"},
          %{"type" => "paragraph", "text" => "Real prose carried in a text key, not content."},
          para("A canonical paragraph so the paper has value-keyed prose too.")
        ],
        "Spacing norm text-keyed false positive"
      )

    assert spacing_warning(warnings) == nil,
           "expected no spacing_norm advisory for text-keyed prose, got: #{inspect(warnings)}"
  end

  test "an empty paragraph nested inside an expandable IS counted (advisory matches the hard gate's walk)" do
    warnings =
      publish_article!(
        "spacing-nested",
        [
          %{"type" => "heading", "level" => 1, "text" => "Nested spacer paper"},
          para("Honest top-level prose."),
          %{
            "type" => "expandable",
            "summary" => "Appendix",
            "blocks" => [
              para("Appendix prose."),
              %{"type" => "paragraph", "content" => []}
            ]
          }
        ],
        "Spacing norm nested blind spot"
      )

    warning = spacing_warning(warnings)

    assert warning,
           "expected a spacing_norm advisory for the nested spacer, got: #{inspect(warnings)}"

    assert warning.message =~ "1 empty paragraph"
  end

  test "empty paragraphs inside columns and steps ARE counted — the walk descends every key the hard gate walks" do
    # The independent review of #11616 proved the two-key ["blocks","children"]
    # walk missed spacers under EpicQuality's other eight @nested_keys: an
    # author passed the advisory and 422'd at the tagged gate. The counter now
    # reads EpicQuality.nested_keys/0 — one owner — and this test plants
    # spacers under two of the previously-missed keys.
    warnings =
      publish_article!(
        "spacing-deep-nested",
        [
          %{"type" => "heading", "level" => 1, "text" => "Deep nested spacer paper"},
          para("Honest top-level prose."),
          %{
            "type" => "columns",
            "columns" => [
              %{"blocks" => [para("Left prose."), %{"type" => "paragraph", "content" => []}]}
            ]
          },
          %{
            "type" => "steps",
            "steps" => [
              %{
                "title" => "Step one",
                "blocks" => [para("Step prose."), %{"type" => "paragraph", "content" => []}]
              }
            ]
          }
        ],
        "Spacing norm deep blind spot"
      )

    warning = spacing_warning(warnings)

    assert warning,
           "expected a spacing_norm advisory for spacers under columns/steps, got: #{inspect(warnings)}"

    assert warning.message =~ "2 empty paragraph"
  end

  test "top-level flat spacers still draw the advisory with an exact count" do
    warnings =
      publish_article!(
        "spacing-flat",
        [
          %{"type" => "heading", "level" => 1, "text" => "Flat spacer paper"},
          para("Prose before the spacers."),
          %{"type" => "paragraph", "content" => []},
          %{"type" => "paragraph", "content" => []},
          para("Prose after the spacers.")
        ],
        "Spacing norm flat pin"
      )

    warning = spacing_warning(warnings)
    assert warning, "expected a spacing_norm advisory, got: #{inspect(warnings)}"
    assert warning.message =~ "2 empty paragraph"
  end

  test "a blank-text paragraph still counts as a spacer" do
    warnings =
      publish_article!(
        "spacing-blank-text",
        [
          %{"type" => "heading", "level" => 1, "text" => "Blank text spacer paper"},
          para("Honest prose."),
          %{"type" => "paragraph", "text" => "   "}
        ],
        "Spacing norm blank text pin"
      )

    warning = spacing_warning(warnings)
    assert warning, "expected a spacing_norm advisory for a blank-text paragraph"
    assert warning.message =~ "1 empty paragraph"
  end

  test "a value-keyed prose paragraph draws NO spacing_norm advisory (the mirror moved with the gate)" do
    warnings =
      publish_article!(
        "spacing-value-keyed",
        [
          %{"type" => "heading", "level" => 1, "text" => "Value-keyed prose paper"},
          para("Honest top-level prose."),
          %{
            "type" => "paragraph",
            "content" => [
              %{
                "type" => "paragraph",
                "value" => "Real prose carried under the documented value key."
              }
            ]
          }
        ],
        "Spacing norm value-keyed false positive"
      )

    assert spacing_warning(warnings) == nil,
           "expected no spacing_norm advisory for value-keyed prose, got: #{inspect(warnings)}"
  end

  test "a spacer spelled as an empty inline leaf IS counted - non-empty content is not proof of prose" do
    # `para("")` is this file's OWN helper: the laundering shape is exactly
    # what the canonical paragraph builder emits for empty text.
    warnings =
      publish_article!(
        "spacing-laundered",
        [
          %{"type" => "heading", "level" => 1, "text" => "Laundered spacer paper"},
          para("Honest prose."),
          para("")
        ],
        "Spacing norm laundered spacer"
      )

    warning = spacing_warning(warnings)
    assert warning, "expected a spacing_norm advisory for a blank inline leaf"
    assert warning.message =~ "1 empty paragraph"
  end

  test "a spacer nested inside a paragraph's OWN content is counted - the hard gate walks there too" do
    # `content` is one of EpicQuality's @nested_keys, so `walk_maps/1` descends
    # a paragraph's own content and refuses there. The mirror's paragraph
    # clause used to return 0 without descending, so an author cleared the
    # advisory and 422'd at the tagged gate - the exact drift the mirror exists
    # to prevent.
    warnings =
      publish_article!(
        "spacing-under-paragraph",
        [
          %{"type" => "heading", "level" => 1, "text" => "Spacer under a paragraph"},
          para("Honest top-level prose."),
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "value" => "Prose in the outer paragraph."},
              %{"type" => "paragraph", "content" => []}
            ]
          }
        ],
        "Spacing norm paragraph-descent blind spot"
      )

    warning = spacing_warning(warnings)
    assert warning, "expected a spacing_norm advisory for a spacer under a paragraph"
    assert warning.message =~ "1 empty paragraph"
  end
end
