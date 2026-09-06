defmodule BarkparkWeb.Studio.PaperEditor.StepsEditorTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas

  test "steps retain reader structure and provide scoped rich bodies" do
    html =
      render_component(&PaperEditor.paper_block_fields/1,
        block: steps(),
        root_slug: "paper",
        canvas_enabled: true,
        paper_rev: 3
      )

    assert html =~ ~s(class="bp-steps")
    assert html =~ ~s(class="bp-steps__title")
    assert html =~ "First step"
    assert html =~ ~s(data-paper-container-kind="steps")
    assert html =~ ~s(data-paper-container-row-id="row-one")
    assert html =~ ~s(data-paper-container-id="steps")
    assert html =~ ~s(data-paper-container-run="0")

    assert html =~
             "paper-canvas-" <>
               PaperCanvas.run_id(PaperCanvas.steps_run_slug("paper", "steps", "row-one"), 0)

    refute html =~ "blocks are not editable yet"
  end

  test "Beta uses per-block rich editing without paper canvas dispatch" do
    html =
      render_component(&PaperEditor.paper_block_fields/1,
        block: steps(),
        root_slug: "paper",
        canvas_enabled: false
      )

    assert html =~ ~s(id="paper-ed-body")
    refute html =~ ~s(phx-hook="BarkparkPaperCanvas")
    refute html =~ "blocks are not editable yet"
  end

  test "top-level canvas does not acquire a partial container marker" do
    html =
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "paper",
        blocks: [%{"id" => "body", "type" => "paragraph", "content" => []}],
        canvas_eligible: true,
        paper_rev: 3
      )

    refute html =~ "data-paper-container-run="
  end

  test "unpopulated steps can be initialized without exposing malformed values" do
    for block <- [
          %{"id" => "steps", "type" => "steps"},
          %{"id" => "steps", "type" => "steps", "steps" => nil}
        ] do
      html = render_component(&PaperEditor.paper_block_fields/1, block: block)
      assert html =~ "steps-form-steps"
      assert html =~ ~s(name="step-count" value="0")
    end
  end

  test "row controls submit ordered identities and stable-ID actions outside body editors" do
    html = render_component(&PaperEditor.paper_block_fields/1, block: steps(), root_slug: "paper")
    tree = LazyHTML.from_fragment(html)
    assert Enum.empty?(LazyHTML.query(tree, "form form"))

    assert tree |> LazyHTML.query("input[name='step-count']") |> LazyHTML.attribute("value") == [
             "1"
           ]

    assert tree |> LazyHTML.query("input[name='step-0-id']") |> LazyHTML.attribute("value") == [
             "row-one"
           ]

    assert tree |> LazyHTML.query("input[name='step-0-title']") |> LazyHTML.attribute("value") ==
             ["First step"]

    assert tree |> LazyHTML.query("button[name='step-action']") |> LazyHTML.attribute("value") ==
             ["up:row-one", "down:row-one", "remove:row-one", "add"]
  end

  test "malformed and missing identities preserve reader content instead of dropping rows" do
    for row <- [
          %{"title" => "Keep this", "children" => []},
          %{"id" => "row", "title" => %{"legacy" => true}, "children" => []}
        ] do
      html =
        render_component(&PaperEditor.paper_block_fields/1,
          block: %{"id" => "steps", "type" => "steps", "steps" => [row]}
        )

      assert html =~ "original content is preserved"
      refute html =~ "steps-form-steps"
      if is_binary(row["title"]), do: assert(html =~ "Keep this")
    end
  end

  test "Paper hosts project legacy identities consistently without changing the input" do
    blocks = [
      %{
        "type" => "steps",
        "steps" => [
          %{"title" => "Legacy", "children" => [%{"type" => "paragraph", "content" => []}]}
        ]
      }
    ]

    html =
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "paper",
        blocks: blocks,
        canvas_eligible: true,
        paper_rev: 3
      )

    projected = Barkpark.Content.ensure_block_ids(blocks)
    [parent] = projected
    [row] = parent["steps"]
    run_id = PaperCanvas.run_id(PaperCanvas.steps_run_slug("paper", parent["id"], row["id"]), 0)
    assert html =~ "paper-canvas-" <> run_id

    assert Enum.any?(
             BarkparkWeb.Studio.StudioLive.Shared.Paper.canvas_echo_runs("paper", blocks),
             &(&1.run_id == run_id)
           )

    assert hd(blocks)["id"] == nil
  end

  defp steps do
    %{
      "id" => "steps",
      "type" => "steps",
      "steps" => [
        %{
          "id" => "row-one",
          "title" => "First step",
          "children" => [
            %{"id" => "body", "type" => "paragraph", "content" => [%{"text" => "Do this"}]}
          ]
        }
      ]
    }
  end
end
