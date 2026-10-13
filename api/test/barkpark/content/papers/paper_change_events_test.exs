defmodule Barkpark.Content.Papers.PaperChangeEventsTest do
  @moduledoc """
  Owner ruling #40 (task-bca599e1df6cca4b): paper edits emit change events on
  ingest and on settled edit bursts, never per keystroke batch.

  Before, `upsert_paper` and the block-op doors wrote no `mutation_events`
  row, so listen, Sync, the push Outbox and webhooks never saw a paper edit.
  """
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Content.Papers.ChangeEvents.SettleWorker

  defp para(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp patch_op(id, text),
    do: %{
      "op" => "patch-block",
      "id" => id,
      "patch" => %{"content" => [%{"type" => "text", "value" => text}]}
    }

  defp events(slug) do
    from(e in MutationEvent, where: e.type == "paper" and e.doc_id == ^slug, order_by: e.id)
    |> Repo.all()
  end

  defp seed!(slug, text \\ "a0") do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Events",
          "blocks" => [para("pa", text)]
        })
      )

    doc
  end

  test "an ingest emits one create event, and a re-ingest one update event with the old rev" do
    slug = "pce-ingest-#{System.unique_integer([:positive])}"
    first = seed!(slug)

    assert [%{mutation: "create", previous_rev: nil, rev: rev1}] = events(slug)
    assert rev1 == first.rev

    second = seed!(slug, "a1")
    assert [_, %{mutation: "update", previous_rev: ^rev1, rev: rev2}] = events(slug)
    assert rev2 == second.rev
  end

  test "a burst of canvas ops schedules ONE settle job and no event until it fires" do
    slug = "pce-burst-#{System.unique_integer([:positive])}"
    before = seed!(slug)
    [_ingest] = events(slug)

    for text <- ["b1", "b2", "b3"] do
      {:ok, _} = Content.apply_paper_block_op(slug, patch_op("pa", text))
    end

    assert length(events(slug)) == 1, "an op must not emit an event per keystroke batch"

    jobs = all_enqueued(worker: SettleWorker, args: %{"doc_id" => slug})
    assert [%Oban.Job{args: args, state: "scheduled"}] = jobs
    assert args["previous_rev"] == before.rev

    assert :ok = perform_job(SettleWorker, args)

    after_burst = Content.get_paper(slug)
    assert [_, %{mutation: "update", previous_rev: prev, rev: rev}] = events(slug)
    assert prev == before.rev
    assert rev == after_burst.rev
  end

  test "a settle job that finds nothing changed emits nothing" do
    slug = "pce-noop-#{System.unique_integer([:positive])}"
    doc = seed!(slug)

    assert :ok =
             perform_job(SettleWorker, %{
               "doc_id" => slug,
               "dataset" => doc.dataset,
               "workspace_id" => doc.workspace_id,
               "project_id" => doc.project_id,
               "previous_rev" => doc.rev
             })

    assert [_ingest_only] = events(slug)
  end
end
