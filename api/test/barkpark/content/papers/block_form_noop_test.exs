defmodule Barkpark.Content.Papers.BlockFormNoopTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.Blocks

  @dataset "production"

  test "trusted Action no-op resolves once, preserves the paper row, and replays its receipt" do
    action = %{
      "id" => "action",
      "type" => "action",
      "label" => nil,
      "href" => nil,
      "priority" => nil,
      "unknown" => %{"keep" => true}
    }

    paper = seed_paper!("action-noop", [action])
    source = action_source("action")
    request_id = Ecto.UUID.generate()
    parent = self()

    resolver = fn blocks ->
      send(parent, :resolved_action_noop)
      resolve_form(blocks, source)
    end

    assert {:ok, receipt, :applied} =
             apply_form(paper, source, request_id, resolver)

    assert receipt == %{
             slug: paper.doc_id,
             op_count: 0,
             rev: paper.content["rev"],
             block_ids: []
           }

    assert_receive :resolved_action_noop
    assert_same_paper_row(paper)

    assert {:ok, ^receipt, :replayed} =
             apply_form(paper, source, request_id, fn _blocks ->
               flunk("resolver ran during exact replay")
             end)

    refute_receive :resolved_action_noop
    assert_same_paper_row(paper)
  end

  test "trusted Card no-op preserves content, cached HTML, and both revisions" do
    card = %{
      "id" => "card",
      "type" => "card",
      "tone" => "info",
      "slots" => %{
        "title" => [%{"type" => "heading", "text" => "Title", "level" => 3}],
        "body" => [
          %{
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Body"}],
            "meta" => %{"keep" => true}
          }
        ],
        "action" => [
          %{
            "type" => "action",
            "label" => "Read",
            "href" => "/read",
            "priority" => "primary"
          }
        ],
        "custom" => [%{"opaque" => true}]
      }
    }

    paper = seed_paper!("card-noop", [card])

    source = %{
      "block_id" => "card",
      "card-tone" => "info",
      "card-title" => "Title",
      "card-media-src" => "",
      "card-media-alt" => "",
      "card-action-label" => "Read",
      "card-action-href" => "/read",
      "card-action-priority" => "primary"
    }

    assert {:ok, %{op_count: 0, block_ids: []}, :applied} =
             apply_form(paper, source, Ecto.UUID.generate(), fn blocks ->
               resolve_form(blocks, source)
             end)

    assert_same_paper_row(paper)
  end

  test "stale trusted no-op does not resolve, write, or consume the request identity" do
    paper =
      seed_paper!("stale-noop", [
        %{"id" => "action", "type" => "action", "label" => "Keep"}
      ])

    source = action_source("action", "Keep")
    request_id = Ecto.UUID.generate()

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_form_once(
               paper.doc_id,
               "block_form:v1",
               source,
               @dataset,
               request_id,
               "user:block-form-noop",
               fn _ -> flunk("stale form must not resolve") end,
               if_rev: paper.content["rev"] - 1
             )

    assert_same_paper_row(paper)

    assert {:ok, %{op_count: 0}, :applied} =
             apply_form(paper, source, request_id, fn blocks -> resolve_form(blocks, source) end)

    assert_same_paper_row(paper)
  end

  test "ordinary canonical empty patch keeps its existing write semantics" do
    once_paper =
      seed_paper!("canonical-empty-patch", [
        %{"id" => "action", "type" => "action", "label" => "Keep"}
      ])

    assert {:ok, %{op_count: 1, rev: saved_rev}, :applied} =
             Content.apply_paper_block_ops_once(
               once_paper.doc_id,
               [%{"op" => "patch-block", "id" => "action", "patch" => %{}}],
               @dataset,
               Ecto.UUID.generate(),
               "user:canonical-empty-patch",
               if_rev: once_paper.content["rev"]
             )

    assert saved_rev == once_paper.content["rev"] + 1
    assert Content.get_paper(once_paper.doc_id).content["rev"] == saved_rev

    direct_paper =
      seed_paper!("canonical-direct-empty-patch", [
        %{"id" => "action", "type" => "action", "label" => "Keep"}
      ])

    assert {:ok, %{op_count: 1, rev: direct_saved_rev}} =
             Content.apply_paper_block_ops(
               direct_paper.doc_id,
               [%{"op" => "patch-block", "id" => "action", "patch" => %{}}],
               @dataset,
               if_rev: direct_paper.content["rev"]
             )

    assert direct_saved_rev == direct_paper.content["rev"] + 1
    assert Content.get_paper(direct_paper.doc_id).content["rev"] == direct_saved_rev
  end

  test "trusted empty patch still passes through the scoped Patch boundary" do
    paper =
      seed_paper!("scoped-noop", [
        %{
          "id" => "details",
          "type" => "expandable",
          "summary" => "Details",
          "children" => [
            %{"id" => "inside", "type" => "action", "label" => "Inside"}
          ]
        },
        %{"id" => "outside", "type" => "action", "label" => "Outside"}
      ])

    source = action_source("outside", "Outside")

    assert {:error, {:block_not_found, "outside", "patch-block"}} =
             Content.apply_paper_block_form_once(
               paper.doc_id,
               "block_form:v1",
               source,
               @dataset,
               Ecto.UUID.generate(),
               "user:scoped-block-form-noop",
               fn blocks -> resolve_form(blocks, source) end,
               if_rev: paper.content["rev"],
               canvas_run_context: %{
                 container_id: "details",
                 container_run_ids: ["inside"]
               }
             )

    assert_same_paper_row(paper)
  end

  defp resolve_form(blocks, source) do
    case Blocks.resolve_block_form(blocks, source) do
      {:ok, op} -> {:ok, [op]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_form(paper, source, request_id, resolver) do
    Content.apply_paper_block_form_once(
      paper.doc_id,
      "block_form:v1",
      source,
      @dataset,
      request_id,
      "user:block-form-noop",
      resolver,
      if_rev: paper.content["rev"]
    )
  end

  defp assert_same_paper_row(before) do
    after_paper = Content.get_paper(before.doc_id)
    assert after_paper.rev == before.rev
    assert after_paper.content == before.content
  end

  defp action_source(id, label \\ "") do
    %{
      "block_id" => id,
      "action-label" => label,
      "action-href" => "",
      "action-priority" => "secondary"
    }
  end

  defp seed_paper!(prefix, blocks) do
    slug = "#{prefix}-#{System.unique_integer([:positive])}"

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks, style: "article"})
      )

    paper
  end
end
