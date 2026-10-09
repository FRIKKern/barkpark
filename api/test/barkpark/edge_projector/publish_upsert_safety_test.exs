defmodule Barkpark.EdgeProjector.PublishUpsertSafetyTest do
  @moduledoc """
  task-3fd3c0c53d08a6bd follow-up — team-lead's two review checks on the
  synchronous publish-upsert fix (`Barkpark.EdgeProjector.Lifecycle`):

    1. **Failure isolation.** "A projection error must never fail or roll
       back the publish." Pinned here with the `edge_projector_upsert_fault`
       test seam (mirrors `Writer.inject_write_fault!/1`): both a raised
       exception and an ordinary `{:error, _}` from the projector still let
       `publish_document/4` return `{:ok, _}`.
    2. **Batch safety.** A publish inside someone else's open transaction (a
       batch `apply_mutations`) must NEVER attempt the inline upsert at all —
       proven elsewhere (scratch harness, not committed) that doing so can
       poison and roll back the WHOLE batch: a raise inside
       `Projector.upsert_record/2`'s own nested `Repo.transaction/1` survives
       a local `rescue`, but the connection is left in a
       `DBConnection.ConnectionError: transaction rolling back` state for
       every LATER statement on that same (shared) transaction. Ecto's
       `mode: :savepoint` does not apply here (it is not a
       `Repo.transaction/2` option outside `Ecto.Adapters.SQL.Sandbox`, and
       covers individual `Repo.insert/update/delete`, not an arbitrary
       block); running the upsert in a separate `Task` was tried and ruled
       out too — it deadlocks against a lock the open outer transaction
       already holds. So the fix takes the OLD debounced path whenever
       `Repo.in_transaction?/0` is true, and this file proves that branch
       actually fires rather than attempting (and risking) the inline call.
  """
  # sync: swaps node-global Application env (`:barkpark, :edge_projector_upsert_fault`)
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Repo

  @dataset "publish_upsert_safety_test"

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

  defp pending_upsert_job?(dataset, published_doc_id) do
    Repo.exists?(
      Ecto.Query.from(j in "oban_jobs",
        where:
          j.worker == "Barkpark.EdgeProjector.ProjectorWorker" and
            fragment("?->>'scope'", j.args) == ^dataset and
            fragment("?->>'op'", j.args) == "upsert" and
            fragment("?->>'_id'", j.args) == ^published_doc_id
      )
    )
  end

  describe "failure isolation — a projector error must not fail or roll back the publish" do
    test "a raised exception inside the synchronous upsert still lets the publish succeed, falling back to the debounced path" do
      publish!("author", "iso-author-1")

      Application.put_env(
        :barkpark,
        :edge_projector_upsert_fault,
        {:raise, RuntimeError, "synthetic projector failure"}
      )

      {:ok, _} =
        Content.create_document("post", %{"_id" => "iso-post-1", "title" => "p"}, @dataset)

      assert {:ok, published} = Content.publish_document("iso-post-1", "post", @dataset)
      assert published.status == "published"

      # The publish is NOT rolled back: the published row is really there,
      # readable in a FRESH read (not just the struct this call returned).
      assert {:ok, reread} = Content.get_document("iso-post-1", "post", @dataset)
      assert reread.id == published.id

      assert pending_upsert_job?(@dataset, "iso-post-1"),
             "the raised projector fault must fall back to the debounced upsert job"
    end

    test "an ordinary {:error, _} from the projector still lets the publish succeed, falling back to the debounced path" do
      Application.put_env(:barkpark, :edge_projector_upsert_fault, {:error, :synthetic})

      {:ok, _} =
        Content.create_document("post", %{"_id" => "iso-post-2", "title" => "p"}, @dataset)

      assert {:ok, published} = Content.publish_document("iso-post-2", "post", @dataset)
      assert {:ok, reread} = Content.get_document("iso-post-2", "post", @dataset)
      assert reread.id == published.id

      assert pending_upsert_job?(@dataset, "iso-post-2"),
             "the {:error, _} projector fault must fall back to the debounced upsert job"
    end
  end

  describe "batch safety — a publish inside someone else's open transaction never attempts the inline path" do
    test "a publish run inside an explicit Repo.transaction commits cleanly and falls back to the debounced job" do
      {:ok, _} =
        Content.create_document("post", %{"_id" => "batch-post-1", "title" => "p"}, @dataset)

      # Simulates what `Content.Mutations.apply_mutations/3` does for every
      # mutation in a batch: run the publish inside an ALREADY-OPEN
      # transaction this caller owns, not one `publish_document/4` opens and
      # commits itself.
      result =
        Repo.transaction(fn ->
          {:ok, doc} = Content.publish_document("batch-post-1", "post", @dataset)
          doc
        end)

      assert {:ok, published} = result
      assert published.status == "published"

      assert pending_upsert_job?(@dataset, "batch-post-1"),
             "a publish inside a shared transaction must take the debounced path, never the inline one"
    end

    test "the inline path is never even attempted inside a shared transaction, even with no fault injected" do
      {:ok, _} =
        Content.create_document("post", %{"_id" => "batch-post-2", "title" => "p"}, @dataset)

      # No fault seam set — if the code attempted the inline path here it
      # would SUCCEED (nothing injected), so the only way this test can tell
      # "debounced path taken" from "inline path taken, and it happened to
      # work" is the same job-queue assertion: the inline path NEVER enqueues
      # a job on success (see `upsert_now/3`'s `:ok` branch), so a pending
      # job existing proves the debounced branch ran instead.
      {:ok, _published} =
        Repo.transaction(fn ->
          Content.publish_document("batch-post-2", "post", @dataset)
        end)

      assert pending_upsert_job?(@dataset, "batch-post-2"),
             "Repo.in_transaction?/0 must route this publish to the debounced path"
    end
  end
end
