defmodule Barkpark.Content.Papers.UnknownBlockChildrenAdvisoryTest do
  @moduledoc """
  The `unknown_block_children` advisory
  (`AuthoringWall.emit_unknown_block_children_advisory/3`) —
  pe-bl-container-child-guard.

  ## The defect this pins

  A block whose `"type"` no reader has a clause for falls to
  `PortableDoc.Render.Compose.compose_block/2`'s degrade arm, which emits the
  `Unsupported block: <type>` placeholder and NOTHING ELSE: the block's nested
  `blocks`/`children` reach no surface. Proven on the pre-fix base
  (c1ab8b0a9a1c0c7d2e6ad927ef0bb5c6f9a0dba7) by `mix run`, both publish-wall
  arms passing the shape and the render dropping both children:

      classified?("container") = false
      validate_render_shapes  = :ok
      validate_block_elements = :ok
      html = "<div class=\\"bp-unknown-block\\">Unsupported block: container</div>"
      CHILD ONE present in html? false
      CHILD TWO present in html? false

  So a `container` carrying two prose children publishes 200 and serves a
  reader NEITHER child — silent content loss.

  ## Advisory, not refusal

  The degrade arm is deliberate forward-compat (compose.ex: "Papers are
  schemaless, so any raw API/SDK/CLI mutate can persist a block type this
  engine has no clause for"). A hard 422 would refuse exactly the writes that
  arm was built to survive — a newer TUI/SDK/plugin writing a type an older API
  release does not know — and its live-corpus blast radius is unmeasured. The
  warnings channel reaches the author on the mutate success envelope without
  taking the write away. See the emitter's comment for the full argument.

  ## RED-BEFORE / MUTATION EVIDENCE (the durable venue this merge carries)

  Mutating the emitter's predicate so the guard never fires — `if
  Tiers.classified?(type) do` replaced by `if true or Tiers.classified?(type)
  do` in `dropped_children/1` — and running this file:

      6 tests, 3 failures

  The three that red are the three that assert the advisory FIRES:
  "an unknown block type carrying children draws the advisory, naming the block
  path", "the advisory names a NESTED unknown container's full path", and
  "children is guarded as well as blocks". The three passthrough pins
  ("a classified container draws NO advisory", "an unknown block type with NO
  children draws NO advisory", "a paper of ordinary prose draws no advisory")
  stay green under the mutation — they are the controls, not the subject.

  THE TEST THAT FAILS IF THE GUARD IS MISSING: "an unknown block type carrying
  children draws the advisory, naming the block path".
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Warnings

  @dataset "unknown_block_children_advisory_test"

  @good_labels %{
    "description" =>
      "A deliberately non-trivial description used by the unknown-block-children advisory tests.",
    "tags" => [
      %{
        "tag" => "publish-wall",
        "strength" => 90,
        "rationale" => "This document exists to exercise the unrendered-container advisory."
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

  defp unknown_warning(warnings),
    do: Enum.find(warnings, &(&1.code == "unknown_block_children"))

  defp para(text),
    do: %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp opening,
    do: [
      %{"type" => "heading", "level" => 1, "text" => "Unrendered container paper"},
      para("Honest top-level prose so the paper is not hollow.")
    ]

  test "an unknown block type carrying children draws the advisory, naming the block path" do
    warnings =
      publish_article!(
        "unknown-container-flat",
        opening() ++
          [
            %{
              "type" => "container",
              "id" => "b12",
              "blocks" => [
                para("CHILD ONE SENTINEL"),
                %{"type" => "heading", "level" => 2, "text" => "CHILD TWO SENTINEL"}
              ]
            }
          ],
        "Unknown container drops its children"
      )

    warning = unknown_warning(warnings)

    assert warning,
           "expected an unknown_block_children advisory, got: #{inspect(warnings)}"

    # The BLOCK PATH the criterion demands, positional AND by authored id.
    assert warning.message =~ "blocks[2].blocks"
    assert warning.message =~ ~s(unrendered type "container")
    assert warning.message =~ "(id b12)"
    assert warning.message =~ "2 block(s)"
    # Advisory, never blocking: the publish above already asserted {:ok, _}.
    assert warning.severity == "advisory"
  end

  test "the advisory names a NESTED unknown container's full path" do
    warnings =
      publish_article!(
        "unknown-container-nested",
        opening() ++
          [
            %{
              "type" => "section",
              "blocks" => [
                para("Section prose."),
                %{"type" => "wrapper-thing", "blocks" => [para("Buried child.")]}
              ]
            }
          ],
        "Nested unknown container drops its children"
      )

    warning = unknown_warning(warnings)

    assert warning,
           "expected an unknown_block_children advisory for the nested case, got: #{inspect(warnings)}"

    assert warning.message =~ "blocks[2].blocks[1].blocks"
    assert warning.message =~ ~s(unrendered type "wrapper-thing")
  end

  test "children is guarded as well as blocks" do
    warnings =
      publish_article!(
        "unknown-container-children-key",
        opening() ++
          [%{"type" => "box", "children" => [para("Only child.")]}],
        "Unknown container using the children key"
      )

    warning = unknown_warning(warnings)

    assert warning,
           "expected an unknown_block_children advisory for a children-keyed container, got: #{inspect(warnings)}"

    assert warning.message =~ "blocks[2].children carries 1 block(s)"
  end

  test "a CLASSIFIED container carrying children draws NO advisory (the passthrough control)" do
    warnings =
      publish_article!(
        "unknown-container-classified",
        opening() ++
          [
            %{"type" => "section", "blocks" => [para("Section prose.")]},
            %{"type" => "expandable", "summary" => "Appendix", "blocks" => [para("Appendix.")]},
            %{"type" => "columns", "columns" => [[para("Left.")], [para("Right.")]]}
          ],
        "Classified containers pass through"
      )

    assert unknown_warning(warnings) == nil,
           "expected no advisory for section/expandable/columns, got: #{inspect(warnings)}"
  end

  test "an unknown block type with NO children draws NO advisory" do
    warnings =
      publish_article!(
        "unknown-leaf-no-children",
        opening() ++ [%{"type" => "sparkline-thing", "data" => [1, 2, 3]}],
        "Unknown leaf publishes quietly"
      )

    assert unknown_warning(warnings) == nil,
           "expected no advisory for a childless unknown block, got: #{inspect(warnings)}"
  end

  test "an ordinary prose paper draws no advisory (inline leaves are not blocks)" do
    warnings =
      publish_article!(
        "unknown-ordinary-prose",
        opening() ++
          [
            para("More prose."),
            %{"type" => "list", "items" => [[%{"type" => "text", "value" => "one"}]]},
            %{
              "type" => "table",
              "rows" => [[[%{"type" => "text", "value" => "cell"}]]]
            }
          ],
        "Ordinary prose paper"
      )

    assert unknown_warning(warnings) == nil,
           "expected no advisory for ordinary prose/list/table, got: #{inspect(warnings)}"
  end
end
