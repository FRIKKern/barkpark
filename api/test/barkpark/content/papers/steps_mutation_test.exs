defmodule Barkpark.Content.Papers.StepsMutationTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.Repo

  test "a revision-fenced single edit resolves projected legacy child identities" do
    {slug, paper} = legacy_paper!()
    {child_id, _projected} = projected_child(paper)

    assert {:ok, receipt} =
             Content.apply_paper_block_op(slug, patch(child_id), "production",
               if_rev: paper.content["rev"]
             )

    assert receipt.block["id"] == child_id
    assert receipt.block["text"] == "After"
    stored = Content.get_paper(slug)

    assert hd(hd(stored.content["blocks"])["steps"])["children"] |> hd() |> Map.get("text") ==
             "After"

    assert stored.content["rev"] == paper.content["rev"] + 1
  end

  test "a revision-fenced batch resolves the same projected child identity" do
    {slug, paper} = legacy_paper!()
    {child_id, _projected} = projected_child(paper)
    request_id = Ecto.UUID.generate()
    args = [slug, [patch(child_id)], "production", request_id, "steps-test"]
    opts = [if_rev: paper.content["rev"]]

    assert {:ok, receipt, :applied} = apply(Content, :apply_paper_block_ops_once, args ++ [opts])
    stored = Content.get_paper(slug)
    assert receipt.block_ids == [child_id]

    assert {:ok, ^receipt, :replayed} =
             apply(Content, :apply_paper_block_ops_once, args ++ [opts])

    assert Content.get_paper(slug).content == stored.content
    assert Content.get_paper(slug).rev == stored.rev
  end

  test "read projection and an empty batch do not persist identities or advance either revision" do
    {slug, paper} = legacy_paper!()
    {_child_id, projected} = projected_child(paper)
    refute projected == paper.content["blocks"]

    assert {:ok, _receipt} =
             Content.apply_paper_block_ops(slug, [], "production", if_rev: paper.content["rev"])

    assert Content.get_paper(slug).content == paper.content
    assert Content.get_paper(slug).rev == paper.rev
  end

  test "row-scoped saves use projected identities and bind retries to that row" do
    {slug, paper} = legacy_paper!()
    {child_id, projected} = projected_child(paper)
    row_id = projected |> hd() |> Map.fetch!("steps") |> hd() |> Map.fetch!("id")

    context = %{
      container_kind: "steps",
      container_id: "procedure",
      container_row_id: row_id,
      container_run_ids: [child_id]
    }

    opts = [if_rev: paper.content["rev"], canvas_run_context: context]
    request_id = Ecto.UUID.generate()

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch(child_id)],
               "production",
               request_id,
               "steps-scoped-test",
               opts
             )

    stored = Content.get_paper(slug)

    assert {:ok, ^receipt, :replayed} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch(child_id)],
               "production",
               request_id,
               "steps-scoped-test",
               opts
             )

    wrong_row =
      Keyword.put(opts, :canvas_run_context, %{context | container_row_id: "another-row"})

    assert {:error, :idempotency_payload_mismatch} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch(child_id)],
               "production",
               request_id,
               "steps-scoped-test",
               wrong_row
             )

    assert Content.get_paper(slug).content == stored.content
    assert Content.get_paper(slug).rev == stored.rev
  end

  test "an invalid row scope refuses before persisting projected identities" do
    {slug, paper} = legacy_paper!()
    {child_id, _projected} = projected_child(paper)

    context = %{
      container_kind: "steps",
      container_id: "procedure",
      container_row_id: "wrong-row",
      container_run_ids: [child_id]
    }

    assert {:error, _} =
             Content.apply_paper_block_ops(slug, [patch(child_id)], "production",
               if_rev: paper.content["rev"],
               canvas_run_context: context
             )

    assert Content.get_paper(slug).content == paper.content
    assert Content.get_paper(slug).rev == paper.rev
  end

  test "a stale edit cannot persist projected identities" do
    {slug, paper} = legacy_paper!()
    {child_id, _projected} = projected_child(paper)

    assert {:error, _} =
             Content.apply_paper_block_op(slug, patch(child_id), "production",
               if_rev: paper.content["rev"] - 1
             )

    assert {:error, _} =
             Content.apply_paper_block_ops(slug, [patch(child_id)], "production",
               if_rev: paper.content["rev"] - 1
             )

    assert Content.get_paper(slug).content == paper.content
    assert Content.get_paper(slug).rev == paper.rev
  end

  test "accepted string revision fences resolve the same projected legacy identities" do
    for mode <- [:single, :batch] do
      {slug, paper} = legacy_paper!()
      {child_id, _projected} = projected_child(paper)
      opts = [if_rev: Integer.to_string(paper.content["rev"])]

      result =
        case mode do
          :single -> Content.apply_paper_block_op(slug, patch(child_id), "production", opts)
          :batch -> Content.apply_paper_block_ops(slug, [patch(child_id)], "production", opts)
        end

      assert {:ok, _receipt} = result
      assert Content.get_paper(slug).content["rev"] == paper.content["rev"] + 1
    end
  end

  defp patch(id), do: %{"op" => "patch-block", "id" => id, "patch" => %{"text" => "After"}}

  defp projected_child(paper) do
    projected = BlockOps.ensure_block_ids(paper.content["blocks"])
    child = projected |> hd() |> Map.fetch!("steps") |> hd() |> Map.fetch!("children") |> hd()
    {child["id"], projected}
  end

  defp legacy_paper! do
    slug = "steps-mutation-#{System.unique_integer([:positive])}"

    blocks = [
      %{
        "id" => "procedure",
        "type" => "steps",
        "steps" => [
          %{
            "title" => "Prepare",
            "children" => [%{"type" => "paragraph", "text" => "Before"}],
            "unknown" => %{"keep" => true}
          }
        ]
      }
    ]

    attrs = Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks})
    {:ok, paper} = Content.upsert_paper(attrs)
    # Model a pre-editor stored document without going through current ingest
    # normalization; projection must stay in memory until an accepted edit.
    paper =
      paper
      |> Ecto.Changeset.change(content: Map.put(paper.content, "blocks", blocks))
      |> Repo.update!()

    {slug, paper}
  end
end
