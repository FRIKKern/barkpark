defmodule Barkpark.Tasks.ReleaseTest do
  @moduledoc """
  Unit tests for `Barkpark.Tasks.Release` — the voluntary unclaim (the
  on-demand twin of the TTL sweeper's reap).

  Covers:
    1. Happy path: the holder releases → lifecycle open, claim.worker nil,
       epoch bumped, released_by/released_at stamped, assignee CLEARED,
       a `task.released` mutation_event emitted.
    2. Holder-only: a non-holder (even with the right epoch) → :not_holder.
    3. Epoch fence: a stale epoch → :fenced_off.
    4. Only in-flight releases: an open task → {:not_in_progress, "open"}.
    5. Not-found id → :not_found.
    6. Release-then-reclaim keeps the epoch monotonic.
    7. Regression: a MISSING observed_epoch raises loudly (KeyError) and a
       blank (nil) one is fenced off — never a silent exit-0 no-op.
    8. Ruling-pin: release ALWAYS lands "open", even for a blocked-born
       task (deterministic landing, NOT a pre-claim restore).
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.Release

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp claimed_task!(scope, worker) do
    doc_id = uniq("rel")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(doc.doc_id, worker, scope)
    claimed
  end

  defp epoch_of(doc), do: get_in(Repo.get!(Document, doc.id).content, ["claim", "epoch"])

  describe "release/3" do
    test "the holder releases: open, worker cleared, epoch bumped, assignee gone, event emitted",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = epoch_of(doc)

      assert {:ok, released} = Release.release(doc.id, "w-hold", observed_epoch: epoch)

      content = Repo.get!(Document, doc.id).content
      assert content["lifecycle_status"] == "open"
      assert get_in(content, ["claim", "worker"]) == nil
      assert get_in(content, ["claim", "epoch"]) == epoch + 1
      assert get_in(content, ["claim", "released_by"]) == "w-hold"
      assert is_binary(get_in(content, ["claim", "released_at"]))
      refute Map.has_key?(content, "assignee")
      assert released.rev != doc.rev

      assert Repo.exists?(
               from(e in MutationEvent,
                 where: e.doc_id == ^doc.doc_id and e.mutation == "task.released"
               )
             )
    end

    test "a non-holder is refused even with the right epoch", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = epoch_of(doc)

      assert {:error, :not_holder} = Release.release(doc.id, "w-thief", observed_epoch: epoch)
      assert get_in(Repo.get!(Document, doc.id).content, ["claim", "worker"]) == "w-hold"
    end

    test "a stale epoch is fenced off", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = epoch_of(doc)

      assert {:error, :fenced_off} = Release.release(doc.id, "w-hold", observed_epoch: epoch - 1)
    end

    test "only an in-flight task can be released", %{scope: scope} do
      doc_id = uniq("rel-open")

      {:ok, doc} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => doc_id,
            "content" => %{"kind" => "task", "lifecycle_status" => "open"}
          },
          @dataset,
          scope
        )

      assert {:error, {:not_in_progress, "open"}} =
               Release.release(doc.id, "anyone", observed_epoch: 1)
    end

    test "an unknown id is :not_found" do
      assert {:error, :not_found} =
               Release.release("00000000-0000-0000-0000-000000000099", "w", observed_epoch: 1)
    end

    # REGRESSION GUARD: the epoch fence must fail LOUDLY when the caller
    # forgets (or blanks) observed_epoch. `Keyword.fetch!/2` raising here is
    # the contract — a silent exit-0 no-op would let a walk-away skip the
    # fence entirely. If this test starts failing, someone softened the
    # fetch; do not "fix" it by defaulting the epoch.
    test "a missing observed_epoch raises loudly and leaves the claim intact", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      assert_raise KeyError, fn -> Release.release(doc.id, "w-hold") end
      assert_raise KeyError, fn -> Release.release(doc.id, "w-hold", []) end

      content = Repo.get!(Document, doc.id).content
      assert content["lifecycle_status"] == "in_progress"
      assert get_in(content, ["claim", "worker"]) == "w-hold"
    end

    test "a blank (nil) observed_epoch is fenced off, never a silent no-op", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      assert {:error, :fenced_off} = Release.release(doc.id, "w-hold", observed_epoch: nil)

      content = Repo.get!(Document, doc.id).content
      assert content["lifecycle_status"] == "in_progress"
      assert get_in(content, ["claim", "worker"]) == "w-hold"
    end

    # RULING PIN (task-lifecycle-visibility wave, 2026-07-21): release lands
    # "open" DETERMINISTICALLY — it is not a restore of the pre-claim status.
    # This is the RED probe inverted: a blocked-born task that is claimed and
    # then released must land "open", because no pre-claim snapshot exists
    # anywhere (claim.ex keeps none) and the TtlSweeper reap twin makes the
    # same landing. See the doctrine comment in release.ex.
    test "a blocked-born task claims then releases to open — the always-open ruling",
         %{scope: scope} do
      doc_id = uniq("rel-blocked")

      {:ok, doc} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => doc_id,
            "content" => %{"kind" => "task", "lifecycle_status" => "blocked"}
          },
          @dataset,
          scope
        )

      {:ok, _claimed} = Tasks.claim_by_id(doc.doc_id, "w-hold", scope)
      epoch = epoch_of(doc)

      assert {:ok, _} = Release.release(doc.id, "w-hold", observed_epoch: epoch)

      content = Repo.get!(Document, doc.id).content
      assert content["lifecycle_status"] == "open"
      assert get_in(content, ["claim", "worker"]) == nil
    end

    test "release-then-reclaim keeps the epoch monotonic", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = epoch_of(doc)

      {:ok, _} = Release.release(doc.id, "w-hold", observed_epoch: epoch)
      {:ok, _} = Tasks.claim_by_id(doc.doc_id, "w-next", scope)

      assert epoch_of(doc) > epoch + 1 or epoch_of(doc) == epoch + 2
      assert get_in(Repo.get!(Document, doc.id).content, ["claim", "worker"]) == "w-next"
    end
  end
end
