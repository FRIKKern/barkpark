defmodule Barkpark.Content.Papers.ContextualHistoryReceiptTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Papers.ContextualHistory
  alias Barkpark.Repo
  alias Barkpark.Repo.IdempotencyStore

  @dataset "production"
  @principal "user:contextual-history"

  test "opted-in image change stores and replays the same authoritative continuation" do
    {slug, paper} = seed_paper!()
    request_id = Ecto.UUID.generate()
    ops = [patch("image", "src", "/after.png")]
    opts = [if_rev: paper.content["rev"] || 0, contextual_history: true]

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_ops_once(slug, ops, @dataset, request_id, @principal, opts)

    assert %{contextual_history: history} = receipt
    assert history["action"] == "undo"
    assert history["expect"] == %{"present" => true, "value" => "/after.png"}
    assert history["replace"] == %{"present" => true, "value" => "/before.png"}
    saved = Content.get_paper(slug)

    assert {:ok, original_blocks, _redo} =
             ContextualHistory.apply(saved.content["blocks"], history)

    assert original_blocks == paper.content["blocks"]

    assert {:ok, ^receipt, :replayed} =
             Content.apply_paper_block_ops_once(slug, ops, @dataset, request_id, @principal, opts)

    assert Content.get_paper(slug).rev == saved.rev
  end

  test "legacy receipts replay unchanged when a later server opts into history" do
    {slug, paper} = seed_paper!()
    request_id = Ecto.UUID.generate()
    ops = [patch("image", "src", "/after.png")]
    opts = [if_rev: paper.content["rev"] || 0]

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_ops_once(slug, ops, @dataset, request_id, @principal, opts)

    refute Map.has_key?(receipt, :contextual_history)

    assert {:ok, ^receipt, :replayed} =
             Content.apply_paper_block_ops_once(
               slug,
               ops,
               @dataset,
               request_id,
               @principal,
               Keyword.put(opts, :contextual_history, true)
             )
  end

  test "unsupported edits and source no-ops keep ordinary save receipts" do
    for op <- [
          patch("intro", "text", "A changed introduction"),
          patch("image", "src", "/before.png")
        ] do
      {slug, paper} = seed_paper!()

      assert {:ok, receipt, :applied} =
               Content.apply_paper_block_ops_once(
                 slug,
                 [op],
                 @dataset,
                 Ecto.UUID.generate(),
                 @principal,
                 if_rev: paper.content["rev"] || 0,
                 contextual_history: true
               )

      refute Map.has_key?(receipt, :contextual_history)
    end
  end

  test "trusted caption form receipt captures absence without inventing a null" do
    {slug, paper} = seed_paper!()
    request_id = Ecto.UUID.generate()
    opts = [if_rev: paper.content["rev"] || 0, contextual_history: true]
    resolver = fn _blocks -> {:ok, [patch("figure", "caption", "A caption")]} end

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_form_once(
               slug,
               "block_form:v1",
               %{"block_id" => "figure", "caption" => "A caption"},
               @dataset,
               request_id,
               @principal,
               resolver,
               opts
             )

    assert receipt.contextual_history["replace"] == %{"present" => false}
    saved = Content.get_paper(slug)

    assert {:ok, restored, _redo} =
             ContextualHistory.apply(saved.content["blocks"], receipt.contextual_history)

    assert restored == paper.content["blocks"]

    assert {:ok, ^receipt, :replayed} =
             Content.apply_paper_block_form_once(
               slug,
               "block_form:v1",
               %{"block_id" => "figure", "caption" => "A caption"},
               @dataset,
               request_id,
               @principal,
               fn _ -> flunk("replay resolved form again") end,
               opts
             )
  end

  test "receipt completion failure rolls back the source and its history together" do
    {slug, paper} = seed_paper!()
    request_id = Ecto.UUID.generate()
    ops = [patch("image", "src", "/after.png")]
    opts = [if_rev: paper.content["rev"] || 0, contextual_history: true]

    assert {:error, :idempotency_completion_failed} =
             Content.apply_paper_block_ops_once(
               slug,
               ops,
               @dataset,
               request_id,
               @principal,
               Keyword.put(opts, :before_idempotency_complete, fn ->
                 Repo.delete_all(IdempotencyStore.Key)
               end)
             )

    assert Content.get_paper(slug).content["blocks"] === paper.content["blocks"]
    assert Content.get_paper(slug).rev == paper.rev
    assert Repo.aggregate(IdempotencyStore.Key, :count) == 0

    assert {:ok, %{contextual_history: history}, :applied} =
             Content.apply_paper_block_ops_once(slug, ops, @dataset, request_id, @principal, opts)

    assert history["replace"] === %{"present" => true, "value" => "/before.png"}
  end

  test "a malformed stored continuation fails replay without another write" do
    {slug, paper} = seed_paper!()
    request_id = Ecto.UUID.generate()
    ops = [patch("image", "src", "/after.png")]
    opts = [if_rev: paper.content["rev"] || 0, contextual_history: true]

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_ops_once(slug, ops, @dataset, request_id, @principal, opts)

    saved = Content.get_paper(slug)

    hash =
      {"paper_ops:v1", paper.id, paper.workspace_id, paper.project_id, paper.dataset_id,
       paper.dataset, @principal, request_id}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    row = Repo.get!(IdempotencyStore.Key, hash)
    invalid = put_in(receipt, [:contextual_history, "field"], "locked")
    row |> Ecto.Changeset.change(response_body: Jason.encode!(invalid)) |> Repo.update!()

    assert {:error, :idempotency_receipt_invalid} =
             Content.apply_paper_block_ops_once(slug, ops, @dataset, request_id, @principal, opts)

    assert Content.get_paper(slug).rev == saved.rev
    assert Content.get_paper(slug).content["blocks"] == saved.content["blocks"]
  end

  defp seed_paper! do
    slug = "contextual-history-#{System.unique_integer([:positive])}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        slug: slug,
        blocks: [
          %{
            "id" => "intro",
            "type" => "paragraph",
            "text" => "History preserves the whole Paper."
          },
          %{
            "id" => "figure",
            "type" => "figure",
            "child" => %{
              "id" => "image",
              "type" => "image",
              "src" => "/before.png",
              "alt" => "Authored image description",
              "title" => "Keep title"
            }
          }
        ]
      })

    assert {:ok, paper} = Content.upsert_paper(attrs)
    {slug, paper}
  end

  defp patch(id, field, value),
    do: %{"op" => "patch-block", "id" => id, "patch" => %{field => value}}
end
