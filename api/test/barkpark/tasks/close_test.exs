defmodule Barkpark.Tasks.CloseTest do
  @moduledoc """
  Unit + integration tests for `Barkpark.Tasks.Close`.

  Covers:
    1. Invalid lifecycle_status → {:error, {:invalid_lifecycle, status}} (pure guard, no DB).
    2. Not-found task_id → {:error, :not_found}.
    3. Close of a never-claimed task (no lease to fence) → {:ok, doc} with lifecycle flipped.
    4. Cancelled lifecycle_status is a valid terminal state.
    5. close_reason persisted when :reason opt is provided; blank reason is a no-op.
    6. Already-terminal guard: closing a task already in "done" → {:error, :stale_claim}.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.{Close, Internal}

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

  # A raw content edit that PRESERVES the claim (so its work_digest stays put)
  # but rewrites arbitrary content — the "someone edited the brief while I held
  # the claim" race the work-digest fence exists for. CAS on the observed rev.
  defp foreign_patch_content!(task_id, patch) do
    doc = Repo.get!(Document, task_id)
    new_content = Map.merge(doc.content, patch)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)
      |> Repo.update_all(set: [content: new_content, rev: Internal.generate_rev()])

    :ok
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # ─── (1) Invalid lifecycle_status guard ──────────────────────────────────

  describe "close/3 — invalid lifecycle_status" do
    test "rejects any status outside the closed set without hitting the DB" do
      # No real task_id needed — the guard fires before the DB call.
      assert {:error, {:invalid_lifecycle, "open"}} =
               Close.close("any-id", "worker", observed_epoch: 1, lifecycle_status: "open")

      assert {:error, {:invalid_lifecycle, "in_progress"}} =
               Close.close("any-id", "worker", observed_epoch: 1, lifecycle_status: "in_progress")

      assert {:error, {:invalid_lifecycle, "bogus"}} =
               Close.close("any-id", "worker", observed_epoch: 1, lifecycle_status: "bogus")
    end

    test "all three valid terminal statuses are accepted (guard passes, DB resolves)" do
      # For a non-existent doc (valid UUID format) the guard passes but the DB
      # returns :not_found. Confirms the guard does NOT block valid terminal statuses.
      nonexistent = "00000000-0000-0000-0000-000000000099"

      for status <- ~w(done cancelled blocked) do
        result = Close.close(nonexistent, "worker", observed_epoch: 1, lifecycle_status: status)

        assert match?({:error, :not_found}, result),
               "status #{inspect(status)} should pass the guard (got #{inspect(result)})"
      end
    end
  end

  # ─── (2) Not-found ────────────────────────────────────────────────────────

  describe "close/3 — not found" do
    test "returns {:error, :not_found} for an unknown task_id", %{scope: _scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      assert {:error, :not_found} =
               Close.close(
                 "00000000-0000-0000-0000-000000000099",
                 "worker",
                 observed_epoch: 1,
                 lifecycle_status: "done"
               )
    end
  end

  # ─── (3) Unclaimed task closes without a lease ───────────────────────────

  describe "close/3 — unclaimed task (no lease)" do
    test "a task with no claim record closes to 'done' regardless of observed_epoch", %{
      scope: scope
    } do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("no-claim"), scope)
      refute Map.has_key?(task.content, "claim"), "precondition: no claim on task"

      assert {:ok, closed} =
               Close.close(task.id, "ghost-worker",
                 observed_epoch: 42,
                 lifecycle_status: "done"
               )

      assert closed.content["lifecycle_status"] == "done"
      # No claim stamp expected — the module only stamps claim for claimed tasks.
      refute Map.has_key?(closed.content, "claim")

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "done"
    end
  end

  # ─── (4) Cancelled is a valid terminal status ─────────────────────────────

  describe "close/3 — cancelled lifecycle_status" do
    test "closing to 'cancelled' sets lifecycle_status correctly", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("cancel-me"), scope)

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "cancelled"
               )

      assert closed.content["lifecycle_status"] == "cancelled"
    end
  end

  # ─── (5) close_reason is persisted; blank is no-op ───────────────────────

  describe "close/3 — :reason option" do
    test "non-blank reason is written to content.close_reason", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("with-reason"), scope)

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 reason: "shipped in v2.3"
               )

      assert closed.content["close_reason"] == "shipped in v2.3"
    end

    test "blank reason does NOT overwrite an existing close_reason", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # Create a task that already has a close_reason in content via raw update.
      task = mk_task!(uniq("blank-reason"), scope)

      # First close stamps the reason.
      {:ok, _} =
        Close.close(task.id, "w",
          observed_epoch: 0,
          lifecycle_status: "done",
          reason: "original reason"
        )

      # Reload and verify the reason stuck (the already-terminal guard makes
      # a second close impossible in the normal path; we just verify the first
      # close stored it correctly with a non-blank reason vs the blank case).
      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["close_reason"] == "original reason"

      # A blank reason on a fresh task must leave close_reason absent.
      task2 = mk_task!(uniq("blank-reason-2"), scope)

      {:ok, closed2} =
        Close.close(task2.id, "w",
          observed_epoch: 0,
          lifecycle_status: "done",
          reason: ""
        )

      refute Map.has_key?(closed2.content, "close_reason"),
             "blank reason must not write close_reason key"
    end
  end

  describe "close/3 — :landed option (land digest, task-obsession L3)" do
    test "a landed map is written to content.landed atomically with the close", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("landed"), scope)

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 landed: %{
                   "prs" => [1210],
                   "files" => ["api/lib/barkpark/tasks/dedup.ex"],
                   "capability_slugs" => []
                 }
               )

      assert closed.content["lifecycle_status"] == "done"
      assert closed.content["landed"]["prs"] == [1210]
      assert closed.content["landed"]["files"] == ["api/lib/barkpark/tasks/dedup.ex"]
      # Empty lists are dropped, not stored as empty keys.
      refute Map.has_key?(closed.content["landed"], "capability_slugs")
    end

    test "a nil/absent landed digest does not write the key", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("no-landed"), scope)

      {:ok, closed} =
        Close.close(task.id, "w", observed_epoch: 0, lifecycle_status: "done")

      refute Map.has_key?(closed.content, "landed")
    end

    test "landed UNIONS into an existing digest (backfill accumulates)", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("landed-union"), scope)
      # Seed a prior digest on the still-open task (as a CI backfill might).
      foreign_patch_content!(task.id, %{"landed" => %{"files" => ["a.ex"], "prs" => [10]}})

      {:ok, closed} =
        Close.close(task.id, "w",
          observed_epoch: 0,
          lifecycle_status: "done",
          landed: %{"files" => ["a.ex", "b.ex"], "capability_slugs" => ["dedup"]}
        )

      assert Enum.sort(closed.content["landed"]["files"]) == ["a.ex", "b.ex"]
      assert closed.content["landed"]["prs"] == [10]
      assert closed.content["landed"]["capability_slugs"] == ["dedup"]
    end
  end

  # ─── (6) Already-terminal guard ──────────────────────────────────────────

  describe "close/3 — already-terminal guard" do
    test "closing a task already in 'done' without an explicit rev → {:error, :stale_claim}", %{
      scope: scope
    } do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("double-close"), scope)

      # First close succeeds.
      assert {:ok, _} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done"
               )

      # Second close (no observed_rev, so default-rev path) hits the
      # already-terminal guard.
      assert {:error, :stale_claim} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done"
               )
    end
  end

  # ─── (7) Acceptance-criteria close-out (:criteria option) ─────────────────
  #
  # Living-values §8/§9 close-time mechanics: met/evidence updates ride the
  # SAME rev-CAS write as the lifecycle flip. These tests pin the merge
  # semantics AND the race contract: a criteria update can never land without
  # its close (and vice versa) — one atomic UPDATE, so a lost CAS leaves
  # ZERO partial state, and a conflicting concurrent mutation is recovered by
  # re-read + retry, not by silently overwriting it.

  describe "close/3 — :criteria option (merge semantics)" do
    @two_criteria [
      %{"criterion" => "renders live value", "met" => false},
      %{"criterion" => "impact panel lists dependents"}
    ]

    test "sets met+evidence on the targeted row, leaves the rest untouched", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-happy"), scope, %{"acceptance_criteria" => @two_criteria})

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 0, "met" => true, "evidence" => "PR #123 + test run"}]
               )

      assert closed.content["lifecycle_status"] == "done"
      [first, second] = closed.content["acceptance_criteria"]
      assert first["met"] == true
      assert first["evidence"] == "PR #123 + test run"
      # Criterion text (the paper-claim citation) is NEVER rewritten.
      assert first["criterion"] == "renders live value"
      # The untargeted row is byte-identical.
      assert second == %{"criterion" => "impact panel lists dependents"}

      # One atomic write: the persisted row matches the returned struct.
      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["acceptance_criteria"] == closed.content["acceptance_criteria"]
      assert reloaded.rev == closed.rev
    end

    test "met defaults to true; explicit met: false is allowed (honest unmet close)", %{
      scope: scope
    } do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-default"), scope, %{"acceptance_criteria" => @two_criteria})

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [
                   %{"index" => 0, "evidence" => "close_test.exs"},
                   %{"index" => 1, "met" => false}
                 ]
               )

      [first, second] = closed.content["acceptance_criteria"]
      assert first["met"] == true
      assert second["met"] == false
    end

    test "explicit empty evidence clears stale evidence atomically with a cancelled close", %{
      scope: scope
    } do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("crit-clear-evidence"), scope, %{
          "acceptance_criteria" => [
            %{"criterion" => "report honest outcome", "met" => true, "evidence" => "stale proof"}
          ]
        })

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "cancelled",
                 criteria: [%{"index" => 0, "met" => false, "evidence" => ""}]
               )

      assert closed.content["lifecycle_status"] == "cancelled"

      assert [%{"met" => false, "evidence" => ""}] =
               closed.content["acceptance_criteria"]

      persisted = Repo.get!(Document, task.id)
      assert persisted.rev == closed.rev
      assert persisted.content["lifecycle_status"] == "cancelled"
      assert persisted.content["acceptance_criteria"] == closed.content["acceptance_criteria"]
    end

    test "omitted evidence preserves stale evidence while other close fields update", %{
      scope: scope
    } do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("crit-preserve-evidence"), scope, %{
          "acceptance_criteria" => [
            %{"criterion" => "report honest outcome", "met" => true, "evidence" => "keep me"}
          ]
        })

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "cancelled",
                 criteria: [%{"index" => 0, "met" => false}]
               )

      assert closed.content["lifecycle_status"] == "cancelled"

      assert [%{"met" => false, "evidence" => "keep me"}] =
               closed.content["acceptance_criteria"]
    end

    test "non-binary explicit evidence aborts the whole close without partial mutation", %{
      scope: scope
    } do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("crit-invalid-evidence"), scope, %{
          "acceptance_criteria" => [
            %{"criterion" => "report honest outcome", "met" => true, "evidence" => "keep me"}
          ]
        })

      assert {:error, :invalid_criteria} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "cancelled",
                 criteria: [%{"index" => 0, "met" => false, "evidence" => 123}]
               )

      persisted = Repo.get!(Document, task.id)
      assert persisted.rev == task.rev
      assert persisted.content["lifecycle_status"] == "open"
      assert persisted.content["acceptance_criteria"] == task.content["acceptance_criteria"]
    end

    test "index out of range aborts the WHOLE close — no partial state", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-oob"), scope, %{"acceptance_criteria" => @two_criteria})

      assert {:error, :criteria_index_out_of_range} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [
                   %{"index" => 0, "met" => true, "evidence" => "would have landed"},
                   %{"index" => 9}
                 ]
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open", "close must not land"
      assert reloaded.content["acceptance_criteria"] == @two_criteria, "no partial criteria write"
      assert reloaded.rev == task.rev, "rev untouched on abort"
    end

    test "criterion text guard mismatch aborts (criteria-grain CAS)", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-guard"), scope, %{"acceptance_criteria" => @two_criteria})

      assert {:error, :criteria_mismatch} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [
                   %{"index" => 0, "criterion" => "some stale remembered text", "met" => true}
                 ]
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open"
      assert reloaded.content["acceptance_criteria"] == @two_criteria

      # The matching guard passes.
      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [
                   %{"index" => 0, "criterion" => "renders live value", "evidence" => "guarded"}
                 ]
               )

      assert hd(closed.content["acceptance_criteria"])["met"] == true
    end
  end

  describe "close/3 — :criteria vs concurrent content mutation (rev-CAS race)" do
    test "a mutation between the caller's read and its close loses the CAS atomically, and the re-read retry recovers BOTH writes",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("crit-race"), scope, %{
          "acceptance_criteria" => [%{"criterion" => "close carries evidence", "met" => false}]
        })

      # The closing agent reads the doc and remembers its rev …
      observed_rev = task.rev

      # … then ANOTHER writer mutates content first (the exact race the spec
      # names: a separate acceptance_criteria/content mutation racing the
      # close's rev CAS). relabel_by_id is the in-repo advisory-lock + CAS
      # content writer.
      assert {:ok, mutated} = Tasks.relabel_by_id(task.id, ["raced-label"], [])
      assert mutated.rev != observed_rev

      # The close pinned to the STALE rev loses the CAS — and loses it
      # atomically: neither the lifecycle flip nor the criteria flip lands.
      assert {:error, :stale_claim} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 observed_rev: observed_rev,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 0, "met" => true, "evidence" => "PR #999"}]
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open"
      assert [%{"met" => false}] = reloaded.content["acceptance_criteria"]
      assert reloaded.content["labels"] == ["raced-label"], "the winner's write is intact"

      # Deliberate retry: re-read (fresh rev via the default-rev path, which
      # re-reads under the per-task advisory lock) and close again. The
      # criteria merge is applied to the FRESH content, so the concurrent
      # label write is preserved alongside the criteria + lifecycle flip.
      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 0, "met" => true, "evidence" => "PR #999"}]
               )

      assert closed.content["lifecycle_status"] == "done"
      assert [%{"met" => true, "evidence" => "PR #999"}] = closed.content["acceptance_criteria"]
      assert closed.content["labels"] == ["raced-label"], "concurrent write survives the close"
    end

    test "interleaved relabel + close-with-criteria from separate processes both land (no lost update)",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("crit-interleave"), scope, %{
          "acceptance_criteria" => [%{"criterion" => "survives interleaving", "met" => false}]
        })

      relabel =
        Task.async(fn ->
          Tasks.relabel_by_id(task.id, ["from-other-proc"], [])
        end)

      close =
        Task.async(fn ->
          Close.close(task.id, "w",
            observed_epoch: 0,
            lifecycle_status: "done",
            criteria: [%{"index" => 0, "met" => true, "evidence" => "interleaved"}]
          )
        end)

      assert {:ok, _} = Task.await(relabel)
      assert {:ok, _} = Task.await(close)

      # Both writers took the same per-task advisory lock + default-rev path,
      # so whichever ran second merged over the first — nothing lost.
      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "done"

      assert [%{"met" => true, "evidence" => "interleaved"}] =
               reloaded.content["acceptance_criteria"]

      assert reloaded.content["labels"] == ["from-other-proc"]
    end
  end

  # ─── (7) work-digest fence: "edited-under-you becomes a 409" ──────────────
  describe "close/3 — work-digest fence (default path)" do
    test "(a) a foreign description edit between claim and close → doc_changed_since_claim; re-read then closes",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      doc_id = uniq("fence-desc")
      task = mk_task!(doc_id, scope, %{"description" => "original brief"})

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", scope)
      epoch = claimed.content["claim"]["epoch"]

      # Someone rewrites the brief under the claim.
      :ok = foreign_patch_content!(task.id, %{"description" => "rewritten brief"})

      # The default close (no observed_rev) refuses — 409 material, not a silent
      # close against a stale brief. current_rev is the post-edit rev; the
      # changed set names exactly the field that drifted.
      assert {:error, {:doc_changed_since_claim, current_rev, changed}} =
               Close.close(task.id, "w", observed_epoch: epoch, lifecycle_status: "done")

      assert changed == ["description"]
      assert current_rev == Repo.get!(Document, task.id).rev
      assert Repo.get!(Document, task.id).content["lifecycle_status"] == "in_progress"

      # Re-read + close: pinning the current rev bypasses the digest fence
      # (strict rev CAS) and the close lands.
      fresh = Repo.get!(Document, task.id)

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: epoch,
                 observed_rev: fresh.rev,
                 lifecycle_status: "done"
               )

      assert closed.content["lifecycle_status"] == "done"
    end

    test "(b) editing content.code_refs / labels between claim and close → close still succeeds",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      doc_id = uniq("fence-selfedit")
      task = mk_task!(doc_id, scope, %{"description" => "steady brief"})

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", scope)
      epoch = claimed.content["claim"]["epoch"]

      # The documented self-edit workflow: labels + code_refs are NOT work-
      # defining, so re-digesting them yields the same stamp → clean close.
      assert {:ok, _} = Tasks.relabel_by_id(task.id, ["in-progress"], [])
      :ok = foreign_patch_content!(task.id, %{"code_refs" => ["lib/foo.ex"]})

      assert {:ok, closed} =
               Close.close(task.id, "w", observed_epoch: epoch, lifecycle_status: "done")

      assert closed.content["lifecycle_status"] == "done"
      assert closed.content["code_refs"] == ["lib/foo.ex"]
      assert closed.content["labels"] == ["in-progress"]
    end

    test "(c) a claim WITHOUT a work_digest (legacy lease) closes exactly as before",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("fence-legacy"), scope, %{"description" => "pre-digest brief"})

      # Hand-craft a pre-existing claim map with NO work_digest key (what a
      # lease stamped before this feature shipped looks like). Then rewrite the
      # brief — with no stamp to compare against, the fence is inert.
      legacy_claim = %{"worker" => "w", "ts_iso" => "2026-01-01T00:00:00Z", "epoch" => 7}

      :ok =
        foreign_patch_content!(task.id, %{
          "lifecycle_status" => "in_progress",
          "assignee" => "w",
          "claim" => legacy_claim,
          "description" => "brief rewritten after a legacy claim"
        })

      assert {:ok, closed} =
               Close.close(task.id, "w", observed_epoch: 7, lifecycle_status: "done")

      assert closed.content["lifecycle_status"] == "done"
    end

    test "(d) an explicit stale observed_rev still loses the rev CAS (behaviour unchanged)",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      doc_id = uniq("fence-explicit-rev")
      task = mk_task!(doc_id, scope, %{"description" => "brief"})

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", scope)
      epoch = claimed.content["claim"]["epoch"]
      stale_rev = claimed.rev

      # A concurrent write bumps the rev after the caller's read.
      :ok = foreign_patch_content!(task.id, %{"description" => "moved on"})

      # Explicit observed_rev bypasses the digest fence and takes the strict
      # full-rev CAS — which the stale rev loses, same as it always has.
      assert {:error, :stale_claim} =
               Close.close(task.id, "w",
                 observed_epoch: epoch,
                 observed_rev: stale_rev,
                 lifecycle_status: "done"
               )

      assert Repo.get!(Document, task.id).content["lifecycle_status"] == "in_progress"
    end
  end

  describe "close/3 — landed_under_you notice (task-obsession L4)" do
    defp events(doc_id, mutation) do
      Repo.all(
        from e in MutationEvent,
          where: e.doc_id == ^doc_id and e.mutation == ^mutation,
          order_by: e.id
      )
    end

    defp make_holder!(prefix, scope, resources) do
      holder = mk_task!(uniq(prefix), scope)

      foreign_patch_content!(holder.id, %{
        "lifecycle_status" => "in_progress",
        "claim" => %{"worker" => "holder-w", "resources" => resources, "epoch" => 1}
      })

      holder
    end

    test "an in-progress task whose claim scope overlaps the landed files is notified",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      holder = make_holder!("holder", scope, ["shared.ex"])
      lander = mk_task!(uniq("lander"), scope)

      {:ok, _} =
        Close.close(lander.id, "lander-w",
          observed_epoch: 0,
          lifecycle_status: "done",
          landed: %{"files" => ["shared.ex", "other.ex"]}
        )

      assert [ev] = events(holder.doc_id, "task.landed_under_you")
      meta = ev.document["landed_under_you"]
      assert meta["landed_task"] == lander.doc_id
      # Only the OVERLAPPING file is reported, not the whole digest.
      assert meta["files"] == ["shared.ex"]
      assert meta["by_worker"] == "lander-w"

      # Pure notification — the holder was never mutated.
      assert Repo.get!(Document, holder.id).content["claim"]["resources"] == ["shared.ex"]
    end

    test "no notice when the claimed scope does not overlap the landed files",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      holder = make_holder!("holder-disjoint", scope, ["unrelated.ex"])
      lander = mk_task!(uniq("lander-disjoint"), scope)

      {:ok, _} =
        Close.close(lander.id, "lander-w",
          observed_epoch: 0,
          lifecycle_status: "done",
          landed: %{"files" => ["shared.ex"]}
        )

      assert events(holder.doc_id, "task.landed_under_you") == []
    end

    test "a close with no land digest emits no notice", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      holder = make_holder!("holder-nolanded", scope, ["shared.ex"])
      lander = mk_task!(uniq("lander-nolanded"), scope)

      {:ok, _} = Close.close(lander.id, "lander-w", observed_epoch: 0, lifecycle_status: "done")

      assert events(holder.doc_id, "task.landed_under_you") == []
    end
  end

  # ─── (8) Merge-gate auto-stamp (Felix wave-9) ─────────────────────────────
  #
  # The LEAD's merge close auto-stamps the final "PR merged"/LEAD-CLOSED
  # acceptance criterion — the one the author explicitly marked
  # `"merge_gate" => true` — so no reviewer hand-patches it every wave. The
  # guards are the whole point: it fires ONLY on a terminal `done` close that
  # carries a land digest (the merge close), never on a builder's honest
  # pre-merge close, never on an unmarked criterion, and never over a caller's
  # explicit update.

  describe "close/3 — merge-gate auto-stamp" do
    @merge_gate_criteria [
      %{"criterion" => "feature built + tests green", "met" => true, "evidence" => "PR #123"},
      %{"criterion" => "MERGE GATE: PR merged to origin/main", "met" => false, "merge_gate" => true}
    ]

    test "(a) a done-close WITH a landed digest flips the merge_gate criterion met=true with composed evidence",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # A claimed task (epoch 5) so the composed evidence carries the epoch.
      task =
        mk_task!(uniq("mg-happy"), scope, %{
          "acceptance_criteria" => @merge_gate_criteria,
          "claim" => %{"worker" => "lead-w", "epoch" => 5}
        })

      assert {:ok, closed} =
               Close.close(task.id, "lead-w",
                 observed_epoch: 5,
                 lifecycle_status: "done",
                 landed: %{"prs" => [456], "files" => ["api/lib/barkpark/tasks/close.ex"]}
               )

      [built, gate] = closed.content["acceptance_criteria"]

      # The non-gate criterion is untouched.
      assert built["met"] == true
      assert built["evidence"] == "PR #123"

      # The gate flipped, carrying the auto evidence (worker + epoch + PR + ts).
      assert gate["met"] == true
      # Criterion text (the paper-claim citation) is NEVER rewritten.
      assert gate["criterion"] == "MERGE GATE: PR merged to origin/main"
      assert gate["merge_gate"] == true
      assert String.starts_with?(gate["evidence"], "auto: lead-closed on merge by lead-w (epoch 5)")
      assert gate["evidence"] =~ "landed PR #456"

      # One atomic write — persisted row matches the returned struct.
      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["acceptance_criteria"] == closed.content["acceptance_criteria"]
      assert reloaded.rev == closed.rev
    end

    test "(b) a done-close with NO landed digest does NOT auto-stamp (builder pre-merge close)",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("mg-nolanded"), scope, %{"acceptance_criteria" => @merge_gate_criteria})

      assert {:ok, closed} =
               Close.close(task.id, "builder-w",
                 observed_epoch: 0,
                 lifecycle_status: "done"
               )

      [_built, gate] = closed.content["acceptance_criteria"]
      assert gate["met"] == false, "no landed digest → the gate is left for the lead"
      assert gate["evidence"] in [nil, ""]
    end

    test "(c) a criterion WITHOUT the merge_gate marker is NOT auto-stamped even on a merge close",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # Same shape but the last entry is unmarked — the text 'MERGE GATE'
      # convention alone must NOT trigger the stamp.
      unmarked = [
        %{"criterion" => "feature built", "met" => true, "evidence" => "PR #1"},
        %{"criterion" => "MERGE GATE: PR merged to origin/main", "met" => false}
      ]

      task = mk_task!(uniq("mg-unmarked"), scope, %{"acceptance_criteria" => unmarked})

      assert {:ok, closed} =
               Close.close(task.id, "lead-w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 landed: %{"prs" => [789]}
               )

      [_built, last] = closed.content["acceptance_criteria"]
      assert last["met"] == false, "no explicit marker → never auto-stamped"
      refute Map.has_key?(last, "evidence")
    end

    test "(d) a caller-supplied explicit update for the gate index WINS (no auto overwrite)",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("mg-caller-wins"), scope, %{"acceptance_criteria" => @merge_gate_criteria})

      assert {:ok, closed} =
               Close.close(task.id, "lead-w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 landed: %{"prs" => [456]},
                 criteria: [%{"index" => 1, "met" => true, "evidence" => "hand-written proof"}]
               )

      gate = Enum.at(closed.content["acceptance_criteria"], 1)
      assert gate["met"] == true
      assert gate["evidence"] == "hand-written proof",
             "the caller's explicit evidence must not be clobbered by the auto-stamp"
    end

    test "an already-met merge_gate criterion is left untouched (idempotent, no re-evidence)",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      already = [
        %{
          "criterion" => "MERGE GATE",
          "met" => true,
          "merge_gate" => true,
          "evidence" => "prior proof"
        }
      ]

      task = mk_task!(uniq("mg-idempotent"), scope, %{"acceptance_criteria" => already})

      assert {:ok, closed} =
               Close.close(task.id, "lead-w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 landed: %{"prs" => [999]}
               )

      [gate] = closed.content["acceptance_criteria"]
      assert gate["evidence"] == "prior proof", "already-met gate keeps its evidence"
    end

    test "a cancelled close (non-'done' terminal) with landed does NOT auto-stamp the gate",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("mg-cancelled"), scope, %{"acceptance_criteria" => @merge_gate_criteria})

      assert {:ok, closed} =
               Close.close(task.id, "lead-w",
                 observed_epoch: 0,
                 lifecycle_status: "cancelled",
                 landed: %{"prs" => [456]}
               )

      gate = Enum.at(closed.content["acceptance_criteria"], 1)
      assert gate["met"] == false, "cancel is not a merge — the gate stays open"
    end
  end
end
