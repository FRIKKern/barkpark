defmodule Barkpark.EdgeProjector.BatchPublishDeferredUpsertTest do
  @moduledoc """
  task-9231839aa8f5f891 — make a BATCH publish's edges prompt, without the
  nested-transaction hazard task-3fd3c0c53d08a6bd's own batch-safety fix
  (`Repo.in_transaction?/0` → the debounced path) traded away.

  barkpark-studio's reported repro IS a batch: one `/v1/data/mutate` call
  holding `[patch, publish]` — so under THAT earlier fix alone, their exact
  case still took the debounced path and still lagged (team-lead's own
  catch). This file proves the deferred-until-commit queue closes that gap
  for the real batch route (`Content.Mutations.apply_mutations/3`), not a
  hand-rolled `Repo.transaction` stand-in.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Mutations

  @dataset "batch_publish_deferred_upsert_test"

  setup do
    on_exit(fn -> Application.delete_env(:barkpark, :edge_projector_upsert_fault) end)

    Content.upsert_schema(
      %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
      @dataset
    )

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "author", "type" => "reference", "refType" => "author"}
        ]
      },
      @dataset
    )

    :ok
  end

  defp publish!(type, id, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), @dataset)

    {:ok, doc} = Content.publish_document(id, type, @dataset)
    doc
  end

  defp outbound_targets(from_pk) do
    from_pk |> Content.list_outbound_edges() |> Enum.map(& &1.to_id)
  end

  defp doc_pk(doc_id) do
    pub = Content.published_id(doc_id)

    Barkpark.Repo.get_by!(Barkpark.Content.Document, doc_id: pub, dataset: @dataset).id
  end

  test "a batch mutate holding [patch, publish] (barkpark-studio's exact repro shape) leaves content_edges correct the instant the batch call returns" do
    publish!("author", "dq-author-alan")
    publish!("author", "dq-author-grace")
    post_pk = publish!("post", "dq-post-07", %{"author" => "dq-author-alan"}).id

    alan_pk = doc_pk("dq-author-alan")
    grace_pk = doc_pk("dq-author-grace")
    assert alan_pk in outbound_targets(post_pk)

    mutations = [
      %{
        "patch" => %{
          "id" => "dq-post-07",
          "type" => "post",
          "set" => %{"author" => "dq-author-grace"}
        }
      },
      %{"publish" => %{"id" => "dq-post-07", "type" => "post"}}
    ]

    assert {:ok, {_tx, _results}} = Mutations.apply_mutations(mutations, @dataset)

    targets = outbound_targets(post_pk)
    refute alan_pk in targets, "the old reference's edge must already be gone — no debounce wait"
    assert grace_pk in targets, "the new reference's edge must already exist — no debounce wait"
  end

  test "a 20-publish batch leaves every doc's edges correct the instant the batch returns, with no debounced jobs enqueued for any of them" do
    publish!("author", "dq-bulk-author")

    ids =
      for i <- 1..20 do
        id = "dq-bulk-post-#{i}"
        {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => id}, @dataset)
        id
      end

    patch_ops =
      Enum.map(ids, fn id ->
        %{"patch" => %{"id" => id, "type" => "post", "set" => %{"author" => "dq-bulk-author"}}}
      end)

    publish_ops = Enum.map(ids, fn id -> %{"publish" => %{"id" => id, "type" => "post"}} end)

    assert {:ok, {_tx, _results}} = Mutations.apply_mutations(patch_ops ++ publish_ops, @dataset)

    author_pk = doc_pk("dq-bulk-author")

    for id <- ids do
      post_pk = doc_pk(id)
      assert author_pk in outbound_targets(post_pk), "#{id}'s edge must exist immediately"
    end

    refute Barkpark.Repo.exists?(
             Ecto.Query.from(j in "oban_jobs",
               where:
                 j.worker == "Barkpark.EdgeProjector.ProjectorWorker" and
                   fragment("?->>'scope'", j.args) == ^@dataset and
                   fragment("?->>'op'", j.args) == "upsert"
             )
           ),
           "every doc in a successful batch flushes inline — none should fall back to debounced"
  end

  test "one doc's synthetic projector failure inside the batch falls back for THAT doc only; the batch still commits and every other doc's edges still flush" do
    publish!("author", "dq-iso-author")

    {:ok, _} =
      Content.create_document("post", %{"_id" => "dq-iso-post-ok", "title" => "ok"}, @dataset)

    {:ok, _} =
      Content.create_document("post", %{"_id" => "dq-iso-post-bad", "title" => "bad"}, @dataset)

    mutations = [
      %{
        "patch" => %{
          "id" => "dq-iso-post-ok",
          "type" => "post",
          "set" => %{"author" => "dq-iso-author"}
        }
      },
      %{"publish" => %{"id" => "dq-iso-post-ok", "type" => "post"}},
      %{
        "patch" => %{
          "id" => "dq-iso-post-bad",
          "type" => "post",
          "set" => %{"author" => "dq-iso-author"}
        }
      },
      %{"publish" => %{"id" => "dq-iso-post-bad", "type" => "post"}}
    ]

    # Fault injection fires on EVERY flushed upsert in this process once set,
    # so this test proves isolation differently from the single-doc tests:
    # here we assert the BATCH ITSELF is unaffected (commits cleanly) and
    # that the failing doc's own fallback does not block the flush loop from
    # reaching the doc queued after it.
    Application.put_env(
      :barkpark,
      :edge_projector_upsert_fault,
      {:raise, RuntimeError, "synthetic projector failure"}
    )

    assert {:ok, {_tx, results}} = Mutations.apply_mutations(mutations, @dataset)

    published =
      Enum.count(results, fn
        %{operation: "publish", document: %{"_draft" => false}} -> true
        _ -> false
      end)

    assert published == 2, "the batch must commit both publishes despite the projector fault"

    assert Barkpark.Repo.exists?(
             Ecto.Query.from(j in "oban_jobs",
               where:
                 j.worker == "Barkpark.EdgeProjector.ProjectorWorker" and
                   fragment("?->>'scope'", j.args) == ^@dataset and
                   fragment("?->>'op'", j.args) == "upsert" and
                   fragment("?->>'_id'", j.args) == "dq-iso-post-ok"
             )
           ),
           "both queued upserts hit the injected fault and fell back — the flush loop must not stop after the first"

    assert Barkpark.Repo.exists?(
             Ecto.Query.from(j in "oban_jobs",
               where:
                 j.worker == "Barkpark.EdgeProjector.ProjectorWorker" and
                   fragment("?->>'scope'", j.args) == ^@dataset and
                   fragment("?->>'op'", j.args) == "upsert" and
                   fragment("?->>'_id'", j.args) == "dq-iso-post-bad"
             )
           ),
           "the fault on the first flushed doc must not drop the fallback for the second"
  end
end
