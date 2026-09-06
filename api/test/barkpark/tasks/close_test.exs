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

  # PDS-D291 (the close-artifact gate): the base fixture carries ONE MET
  # acceptance criterion. Not decoration — without it every `done` close in this
  # file would trip the new gate, which refuses a `done` close of a kind:task row
  # with ZERO criteria whose reason names no PR+sha and pastes no run. These
  # tests are about the fencing epoch, the holder gate, the work digest, the land
  # digest and the reason field; a met criterion keeps each of them measuring
  # THAT and nothing else. Every criteria-specific test below already passes its
  # own `acceptance_criteria` through `content_extra`, which wins the merge, so
  # this default is invisible to them — and the two tests that genuinely need a
  # criteria-less row opt out with `"acceptance_criteria" => []` and say why.
  @fixture_criterion [%{"criterion" => "the fixture is closeable", "met" => true}]

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => @fixture_criterion
        },
        content_extra
      )

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
                 lifecycle_status: "cancelled",
                 # task-650d7844d8fe7199: a cancel needs a reason — every
                 # other close gate exempts `cancelled` by name, so the
                 # reason is its whole record.
                 reason: "cancelled by the close test fixture"
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
                 # The closer flips its own criteria in the closing command, so
                 # the D289 gate measures the doc AS READ (both unmet) and this
                 # close only lands with a recorded reason.
                 criteria_override: "merge semantics under test, not criteria proof",
                 criteria: [
                   %{
                     "index" => 0,
                     "met" => true,
                     "evidence" => "PR #123 + test run",
                     "criterion" => "renders live value"
                   }
                 ]
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
                 criteria_override: "met-default semantics under test",
                 criteria: [
                   %{
                     "index" => 0,
                     "evidence" => "close_test.exs",
                     "criterion" => "renders live value"
                   },
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
                 # task-650d7844d8fe7199: a cancel needs a reason — every
                 # other close gate exempts `cancelled` by name, so the
                 # reason is its whole record.
                 reason: "cancelled by the close test fixture",
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
                 # task-650d7844d8fe7199: a cancel needs a reason — every
                 # other close gate exempts `cancelled` by name, so the
                 # reason is its whole record.
                 reason: "cancelled by the close test fixture",
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
                 # task-650d7844d8fe7199: a cancel needs a reason — every
                 # other close gate exempts `cancelled` by name, so the
                 # reason is its whole record.
                 reason: "cancelled by the close test fixture",
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
                   %{
                     "index" => 0,
                     "met" => true,
                     "evidence" => "would have landed",
                     "criterion" => "renders live value"
                   },
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
                 criteria_override: "guard semantics under test",
                 criteria: [
                   %{"index" => 0, "criterion" => "renders live value", "evidence" => "guarded"}
                 ]
               )

      assert hd(closed.content["acceptance_criteria"])["met"] == true
    end
  end

  # ─── (7b) The close path fails CLOSED on an unguarded met-flip (D56) ───────
  #
  # merge_criteria is SHARED by close and stamp, so the false-done vector the
  # stamp guard closes exists identically here: `--set 'criteria:=[{"index":1,
  # "met":true,…}]'` with a 1-based-by-habit index flips a NEIGHBOUR criterion
  # and the close reports success. A met-flip must NAME its criterion.

  describe "close/3 — :criteria met-flip requires the criterion text" do
    @guard_criteria [
      %{"criterion" => "criterion A: built", "met" => false},
      %{"criterion" => "criterion B: proven", "met" => false},
      %{"criterion" => "criterion C: PR merged", "met" => false}
    ]

    test "an index-only met:true entry is REJECTED and the whole close aborts", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-noguard"), scope, %{"acceptance_criteria" => @guard_criteria})

      # Intent was criterion B (index 1); a 1-based "2" lands on index 2 — the
      # merge-gated criterion the closer cannot possibly have proven.
      assert {:error, :criterion_text_required} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 2, "met" => true, "evidence" => "proof for B"}]
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open", "the close must not land"
      assert reloaded.content["acceptance_criteria"] == @guard_criteria, "nothing flipped"
      assert reloaded.rev == task.rev, "rev untouched on abort"
    end

    test "an index-only entry with NO met key (the met→true default) is REJECTED too", %{
      scope: scope
    } do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("crit-default-met"), scope, %{"acceptance_criteria" => @guard_criteria})

      # The close body's back-compat default is met→true — the guard must see
      # through it, or the whole fix is bypassed by omitting one key.
      assert {:error, :criterion_text_required} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 0, "evidence" => "implicitly met"}]
               )

      assert Repo.get!(Document, task.id).content["acceptance_criteria"] == @guard_criteria
    end

    test "an honest met:false entry still needs no text (it flips no lock)", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-unmet-ok"), scope, %{"acceptance_criteria" => @guard_criteria})

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "cancelled",
                 # task-650d7844d8fe7199: a cancel needs a reason — every
                 # other close gate exempts `cancelled` by name, so the
                 # reason is its whole record.
                 reason: "cancelled by the close test fixture",
                 criteria: [%{"index" => 2, "met" => false, "evidence" => "never got there"}]
               )

      assert Enum.at(closed.content["acceptance_criteria"], 2) == %{
               "criterion" => "criterion C: PR merged",
               "met" => false,
               "evidence" => "never got there"
             }
    end

    test "a guarded met:true entry lands exactly where it says", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-guarded-ok"), scope, %{"acceptance_criteria" => @guard_criteria})

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria_override: "guarded met-flip under test; A and C stay unmet",
                 criteria: [
                   %{
                     "index" => 1,
                     "met" => true,
                     "evidence" => "close_test.exs",
                     "criterion" => "criterion B: proven"
                   }
                 ]
               )

      [a, b, c] = closed.content["acceptance_criteria"]
      assert b["met"] == true and b["evidence"] == "close_test.exs"
      assert a["met"] == false and c["met"] == false, "neighbours untouched"
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
                 criteria_override: "rev-CAS race under test",
                 criteria: [
                   %{
                     "index" => 0,
                     "met" => true,
                     "evidence" => "PR #999",
                     "criterion" => "close carries evidence"
                   }
                 ]
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
                 criteria_override: "rev-CAS race under test",
                 criteria: [
                   %{
                     "index" => 0,
                     "met" => true,
                     "evidence" => "PR #999",
                     "criterion" => "close carries evidence"
                   }
                 ]
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
            criteria_override: "interleaving under test",
            criteria: [
              %{
                "index" => 0,
                "met" => true,
                "evidence" => "interleaved",
                "criterion" => "survives interleaving"
              }
            ]
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
      %{
        "criterion" => "MERGE GATE: PR merged to origin/main",
        "met" => false,
        "merge_gate" => true
      }
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

      # cch-w66-s2: the sentence names what was SUPPLIED (a caller-asserted land
      # digest), never a lead or a merge — nothing on this path observed either.
      assert String.starts_with?(
               gate["evidence"],
               "auto: UNVERIFIED merge-gate autostamp — no merge observed; " <>
                 "caller-asserted land digest from worker \"lead-w\" (epoch 5)"
             )

      assert gate["evidence"] =~ "naming PR #456"

      # One atomic write — persisted row matches the returned struct.
      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["acceptance_criteria"] == closed.content["acceptance_criteria"]
      assert reloaded.rev == closed.rev
    end

    # D56 COMPANION — the guard's mandatory blast-radius test. merge_criteria now
    # REFUSES any met-flip that carries no criterion text, and the autostamp used
    # to build exactly that (`%{"index" => i, "met" => true, "evidence" => …}`).
    # If it did not thread the stored text in, THIS is where the fix would have
    # silently broken #3039 the day it shipped: every lead merge-close would 409
    # criterion_text_required instead of stamping the gate.
    test "(a2) the auto-stamp survives the fail-closed guard — it threads the stored text",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("mg-guarded"), scope, %{
          "acceptance_criteria" => @merge_gate_criteria,
          "claim" => %{"worker" => "lead-w", "epoch" => 2}
        })

      # No caller `criteria` payload at all — the synthetic update is the ONLY
      # criteria write, so a missing guard would abort the whole close.
      assert {:ok, closed} =
               Close.close(task.id, "lead-w",
                 observed_epoch: 2,
                 lifecycle_status: "done",
                 landed: %{"prs" => [3157]}
               )

      assert closed.content["lifecycle_status"] == "done", "the close still lands"

      gate = Enum.at(closed.content["acceptance_criteria"], 1)
      assert gate["met"] == true, "the merge gate is still auto-stamped"
      assert gate["criterion"] == "MERGE GATE: PR merged to origin/main"
      assert gate["evidence"] =~ "naming PR #3157"
    end

    # A merge_gate criterion with no wording is UNGUARDABLE: rather than stamp it
    # through a hole (the exact exemption that made the guard fail open), the
    # auto-stamp skips it — and the close still succeeds.
    test "(a3) a merge_gate criterion with NO text is skipped, not stamped through a hole",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      textless = [
        %{"criterion" => "feature built", "met" => true, "evidence" => "PR #1"},
        %{"criterion" => "", "met" => false, "merge_gate" => true}
      ]

      task = mk_task!(uniq("mg-textless"), scope, %{"acceptance_criteria" => textless})

      # A text-less gate is NOT auto-stampable, so the D289 gate still counts it
      # unmet — the lead's seal close names why it is closing over it.
      assert {:ok, closed} =
               Close.close(task.id, "lead-w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria_override: "merge-gate criterion carries no wording; left for a human",
                 landed: %{"prs" => [999]}
               )

      assert closed.content["lifecycle_status"] == "done", "the close is never blocked by this"

      gate = Enum.at(closed.content["acceptance_criteria"], 1)
      assert gate["met"] == false, "a text-less gate is left for a human, never auto-flipped"
    end

    test "(b) a done-close with NO landed digest does NOT auto-stamp (builder pre-merge close)",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("mg-nolanded"), scope, %{"acceptance_criteria" => @merge_gate_criteria})

      # No land digest -> nothing is auto-stampable -> the merge gate reads unmet
      # to the D289 gate, and this pre-merge close has to say so.
      assert {:ok, closed} =
               Close.close(task.id, "builder-w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria_override: "pre-merge close; the merge gate is the lead's to stamp"
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
                 criteria_override: "unmarked criterion is not auto-stampable",
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
                 criteria: [
                   %{
                     "index" => 1,
                     "met" => true,
                     "evidence" => "hand-written proof",
                     "criterion" => "MERGE GATE: PR merged to origin/main"
                   }
                 ]
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
                 # task-650d7844d8fe7199: a cancel needs a reason — every
                 # other close gate exempts `cancelled` by name, so the
                 # reason is its whole record.
                 reason: "cancelled by the close test fixture",
                 landed: %{"prs" => [456]}
               )

      gate = Enum.at(closed.content["acceptance_criteria"], 1)
      assert gate["met"] == false, "cancel is not a merge — the gate stays open"
    end
  end

  # ─── (8b) The autostamp records what it ACTUALLY observed (cch-w66-s2) ────
  #
  # THE FABRICATION, reproduced before it was fixed: `landed` reaches close/3 as
  # a RAW, unvalidated client body field (tasks_controller close/2,
  # `Params.put_opt(:landed, params["landed"])` on the ordinary :token_root
  # tier). `autostamp_merge_gate` guards ONLY on status=="done" plus a non-empty
  # map — no lead check, no PR verification, no check that the PR belongs to this
  # task — and the evidence was composed entirely from those caller bytes as
  # "auto: lead-closed on merge by <worker>". Meanwhile `unmet_after_autostamp/2`
  # deducts the stamped index from the D289 unmet set, so `check_criteria_proven`
  # returns {:ok, nil} and NO close_override is minted: the deduction erased its
  # own trace. A scratch worker paid a merge gate citing PR #11435 — a foreign
  # epic's PR it never touched — and the ledger read exactly like an honest lead
  # seal.
  #
  # Neither refused shape is built here: an authority check keyed on `worker_id`
  # is VACUOUS (it is a client-supplied body param — close.ex:26-31), and a
  # GitHub round-trip cannot run under `pg_advisory_xact_lock`. What is built is
  # PROVENANCE: the sentence stops asserting a lead and a merge, and the
  # deduction leaves a durable, machine-readable receipt.
  describe "close/3 — the merge-gate autostamp records what it actually observed" do
    @fabrication_criteria [
      %{"criterion" => "work built", "met" => true, "evidence" => "local run"},
      %{
        "criterion" => "MERGE GATE: PR merged to origin/main",
        "met" => false,
        "merge_gate" => true
      }
    ]

    test "a scratch worker citing a FOREIGN PR still stamps the gate — but the ledger no longer claims a lead or a merge, and the deduction leaves a trace",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("fabrication"), scope, %{
          "acceptance_criteria" => @fabrication_criteria,
          "claim" => %{"worker" => "scratch-w", "epoch" => 1}
        })

      # PR #11435 belongs to a DIFFERENT epic; this task never touched it.
      assert {:ok, closed} =
               Close.close(task.id, "scratch-w",
                 observed_epoch: 1,
                 lifecycle_status: "done",
                 landed: %{"prs" => [11_435]},
                 caller_token_id: "tok-42"
               )

      gate = Enum.at(closed.content["acceptance_criteria"], 1)

      # The stamp itself is UNCHANGED — 76 of 2,064 recorded closes are foreign
      # lead seals (D288/D289) and deleting close-time autostamp would break the
      # seal ritual. What changed is what the ledger SAYS about it.
      assert gate["met"] == true

      refute gate["evidence"] =~ "lead-closed",
             "the evidence must not assert a LEAD nothing authenticated"

      refute gate["evidence"] =~ "on merge",
             "the evidence must not assert a MERGE nothing observed"

      assert gate["evidence"] =~ "UNVERIFIED merge-gate autostamp"
      assert gate["evidence"] =~ "caller-asserted land digest"
      assert gate["evidence"] =~ "naming PR #11435"

      # THE TRACE. A reviewer tells an autostamped criterion from a proven one by
      # READING ONE KEY — never by parsing the evidence prose.
      record = closed.content["merge_gate_autostamp"]["close"]

      assert record["verified"] == false
      assert record["source"] == "close_landed_digest"
      assert record["indices"] == [1], "the trace names the exact rows it deducted"
      assert record["landed"] == "PR #11435"
      assert is_binary(record["ts"])

      # Both actors, labelled for what they are: the name the caller CLAIMED and
      # the token the server actually AUTHENTICATED.
      assert record["asserted_worker"] == "scratch-w"
      assert record["authenticated_token_id"] == "tok-42"

      # One atomic write — the stamp and its confession land together.
      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["merge_gate_autostamp"] == closed.content["merge_gate_autostamp"]
      assert reloaded.rev == closed.rev
    end

    test "an internal caller (no api_token) records a NULL authenticated actor rather than borrowing the asserted one",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("autostamp-internal"), scope, %{
          "acceptance_criteria" => @fabrication_criteria
        })

      assert {:ok, closed} =
               Close.close(task.id, "lead-w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 landed: %{"prs" => [7]}
               )

      record = closed.content["merge_gate_autostamp"]["close"]
      assert Map.has_key?(record, "authenticated_token_id")
      assert record["authenticated_token_id"] == nil
      assert record["asserted_worker"] == "lead-w"
    end

    test "a close that autostamps NOTHING writes no trace (an honest close has nothing to confess)",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("autostamp-none"), scope, %{
          "acceptance_criteria" => @fabrication_criteria
        })

      # No land digest → nothing autostampable → nothing deducted → no receipt.
      assert {:ok, closed} =
               Close.close(task.id, "builder-w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria_override: "pre-merge close; the merge gate is the lead's to stamp"
               )

      refute Map.has_key?(closed.content, "merge_gate_autostamp")
    end

    test "SIDE BY SIDE: the unverified close-time sentence and the webhook-verified one are distinguishable, and so are their traces",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # (1) The webhook-verified path — a real merge event was observed.
      verified_task =
        mk_task!(uniq("autostamp-verified"), scope, %{
          "acceptance_criteria" => @fabrication_criteria
        })

      assert {:ok, :stamped, [1]} =
               Close.reconcile_merge_gate(
                 verified_task.id,
                 %{"prs" => [456], "commit" => "abc123"}
               )

      verified = Repo.get!(Document, verified_task.id)
      verified_evidence = Enum.at(verified.content["acceptance_criteria"], 1)["evidence"]

      # (2) The close-time path — only caller bytes.
      asserted_task =
        mk_task!(uniq("autostamp-asserted"), scope, %{
          "acceptance_criteria" => @fabrication_criteria
        })

      assert {:ok, closed} =
               Close.close(asserted_task.id, "lead-w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 landed: %{"prs" => [456], "commit" => "abc123"}
               )

      asserted_evidence = Enum.at(closed.content["acceptance_criteria"], 1)["evidence"]

      # Same land digest, two sentences that cannot be mistaken for each other.
      assert asserted_evidence != verified_evidence
      assert verified_evidence =~ "auto: merge-reconciled by github-merge"
      refute verified_evidence =~ "UNVERIFIED"
      assert asserted_evidence =~ "auto: UNVERIFIED merge-gate autostamp"
      refute asserted_evidence =~ "merge-reconciled"

      # And the traces carry the same distinction as a boolean, not as prose.
      assert verified.content["merge_gate_autostamp"]["merge_event"]["verified"] == true

      assert verified.content["merge_gate_autostamp"]["merge_event"]["source"] ==
               "github_merge_event"

      assert closed.content["merge_gate_autostamp"]["close"]["verified"] == false
      refute Map.has_key?(closed.content["merge_gate_autostamp"], "merge_event")
    end

    test "a later verified merge event does NOT erase the earlier unverified assertion",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      unstamped = [
        %{"criterion" => "work built", "met" => true, "evidence" => "local run"},
        %{"criterion" => "MERGE GATE: PR merged", "met" => false, "merge_gate" => true},
        %{"criterion" => "MERGE GATE: release tagged", "met" => false, "merge_gate" => true}
      ]

      task = mk_task!(uniq("autostamp-both"), scope, %{"acceptance_criteria" => unstamped})

      # A close asserts gate #1 only (the caller's own explicit update wins #2's
      # index, so the autostamp leaves it for the merge event).
      assert {:ok, _} =
               Close.close(task.id, "lead-w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 landed: %{"prs" => [11_435]},
                 criteria_override: "sealing over the untouched second gate",
                 criteria: [
                   %{
                     "index" => 2,
                     "met" => false,
                     "evidence" => "",
                     "criterion" => "MERGE GATE: release tagged"
                   }
                 ]
               )

      # Later, the real merge lands and reconciles the remaining gate.
      assert {:ok, :stamped, [2]} =
               Close.reconcile_merge_gate(task.id, %{"prs" => [999], "commit" => "deadbee"})

      record = Repo.get!(Document, task.id).content["merge_gate_autostamp"]

      assert record["close"]["verified"] == false
      assert record["close"]["indices"] == [1]
      assert record["close"]["landed"] == "PR #11435"
      assert record["merge_event"]["verified"] == true
      assert record["merge_event"]["indices"] == [2]
    end
  end

  # ─── (9) HOLDER GATE (PDS-D288) ───────────────────────────────────────────
  #
  # Before this gate, `check_fencing/2` compared the EPOCH and nothing else, so
  # worker-B closing worker-A's task on A's epoch returned {:ok, doc} carrying
  # `claim.worker = "worker-A", claim.closed_by = "worker-B"` — a row that reads
  # like A finished the work. Three allow-arms (unclaimed / holder / self-resume)
  # and a LOUD RECORDED OVERRIDE for everything else. It is an HONESTY gate:
  # worker_id is client-supplied, so this stops accidents and makes deliberate
  # foreign closes auditable — it is not authorization.

  describe "close/3 — holder gate" do
    test "worker-B closing worker-A's claimed task is REFUSED (was silently {:ok, doc})",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      doc_id = uniq("holder-foreign")
      task = mk_task!(doc_id, scope)

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "worker-A", scope)
      epoch = claimed.content["claim"]["epoch"]

      assert {:error, {:not_holder, "worker-A"}} =
               Close.close(task.id, "worker-B", observed_epoch: epoch, lifecycle_status: "done")

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "in_progress", "nothing was written"
      refute Map.has_key?(reloaded.content["claim"], "closed_by")
      assert reloaded.rev == claimed.rev, "rev untouched on refusal"
    end

    test "arm 2 — the holder closes its own claim", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      doc_id = uniq("holder-self")
      task = mk_task!(doc_id, scope)
      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "worker-A", scope)

      assert {:ok, closed} =
               Close.close(task.id, "worker-A",
                 observed_epoch: claimed.content["claim"]["epoch"],
                 lifecycle_status: "done"
               )

      assert closed.content["lifecycle_status"] == "done"
      assert closed.content["claim"]["closed_by"] == "worker-A"
      refute Map.has_key?(closed.content, "close_override"), "an honest close confesses nothing"
    end

    test "arm 1 — a never-claimed container task still closes for anyone", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("holder-container"), scope)
      refute Map.has_key?(task.content, "claim"), "precondition: no claim map"

      assert {:ok, closed} =
               Close.close(task.id, "some-lead", observed_epoch: 0, lifecycle_status: "done")

      assert closed.content["lifecycle_status"] == "done"
      refute Map.has_key?(closed.content, "close_override")
    end

    test "arm 3a — a TTL-reaped lease self-resumes on previous_worker", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("holder-reaped"), scope)

      # What TtlSweeper leaves behind: worker nil'd, epoch bumped, the reaped
      # holder recorded as previous_worker (ttl_sweeper.ex:355,366).
      :ok =
        foreign_patch_content!(task.id, %{
          "lifecycle_status" => "open",
          "claim" => %{
            "worker" => nil,
            "previous_worker" => "worker-A",
            "epoch" => 3,
            "expired_at" => "2026-07-27T00:00:00Z"
          }
        })

      assert {:ok, closed} =
               Close.close(task.id, "worker-A", observed_epoch: 3, lifecycle_status: "done")

      assert closed.content["lifecycle_status"] == "done"
      refute Map.has_key?(closed.content, "close_override")
    end

    test "arm 3b — a VOLUNTARILY released lease self-resumes on released_by", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      doc_id = uniq("holder-released")
      task = mk_task!(doc_id, scope)

      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "worker-A", scope)

      assert {:ok, released} =
               Tasks.release(task.id, "worker-A",
                 observed_epoch: claimed.content["claim"]["epoch"]
               )

      # The release path writes released_by, NOT previous_worker — a gate keyed
      # on only one of the two keys silently refuses this whole path.
      assert released.content["claim"]["worker"] == nil
      assert released.content["claim"]["released_by"] == "worker-A"
      refute Map.has_key?(released.content["claim"], "previous_worker")

      assert {:ok, closed} =
               Close.close(task.id, "worker-A",
                 observed_epoch: released.content["claim"]["epoch"],
                 lifecycle_status: "done"
               )

      assert closed.content["lifecycle_status"] == "done"
      refute Map.has_key?(closed.content, "close_override")
    end

    test "arm 3 does not admit a DIFFERENT worker over a released lease", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("holder-released-foreign"), scope)

      :ok =
        foreign_patch_content!(task.id, %{
          "claim" => %{"worker" => nil, "released_by" => "worker-A", "epoch" => 2}
        })

      assert {:error, {:not_holder, "worker-A"}} =
               Close.close(task.id, "worker-B", observed_epoch: 2, lifecycle_status: "done")

      assert Repo.get!(Document, task.id).content["lifecycle_status"] == "open"
    end

    test "the override lands the foreign close AND records actor + held_by + reason",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      doc_id = uniq("holder-override")
      task = mk_task!(doc_id, scope)
      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "worker-A", scope)

      assert {:ok, closed} =
               Close.close(task.id, "oc-lead",
                 observed_epoch: claimed.content["claim"]["epoch"],
                 lifecycle_status: "done",
                 holder_override: "lead seal on merge of PR #6378"
               )

      assert closed.content["lifecycle_status"] == "done"

      # Re-read the persisted row — the confession is durable, not just echoed.
      record = Repo.get!(Document, task.id).content["close_override"]["holder"]
      assert record["actor"] == "oc-lead"
      assert record["held_by"] == "worker-A"
      assert record["reason"] == "lead seal on merge of PR #6378"
      assert is_binary(record["ts"])
      # And the ordinary close stamp still names who actually closed it.
      assert Repo.get!(Document, task.id).content["claim"]["closed_by"] == "oc-lead"
    end

    test "a blank/whitespace override reason is NOT an override", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      doc_id = uniq("holder-blank-override")
      task = mk_task!(doc_id, scope)
      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "worker-A", scope)
      epoch = claimed.content["claim"]["epoch"]

      for blank <- ["", "   ", nil] do
        assert {:error, {:not_holder, "worker-A"}} =
                 Close.close(task.id, "worker-B",
                   observed_epoch: epoch,
                   lifecycle_status: "done",
                   holder_override: blank
                 )
      end

      assert Repo.get!(Document, task.id).content["lifecycle_status"] == "in_progress"
    end

    test "the holder gate is independent of the epoch fence (a stale epoch still loses)",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      doc_id = uniq("holder-vs-fence")
      task = mk_task!(doc_id, scope)
      assert {:ok, _} = Tasks.claim_by_id(doc_id, "worker-A", scope)

      # Wrong epoch → fenced_off wins, holder_override cannot buy past it.
      assert {:error, :fenced_off} =
               Close.close(task.id, "oc-lead",
                 observed_epoch: 999,
                 lifecycle_status: "done",
                 holder_override: "lead seal"
               )
    end
  end

  # ─── (10) CRITERIA GATE (PDS-D289) ────────────────────────────────────────
  #
  # Measured on the doc AS READ, under the same advisory lock, BEFORE
  # `merge_criteria` runs inside the close's own write — the only seat where the
  # pre-close truth is visible. A gate placed after that merge is decorative by
  # construction: the closing command's own met-flips would satisfy it.

  describe "close/3 — criteria gate" do
    @unproven [
      %{"criterion" => "A: built", "met" => true, "evidence" => "PR #1"},
      %{"criterion" => "B: proven", "met" => false}
    ]

    test "a done close over an unmet criterion is REFUSED, naming the index", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-gate-refuse"), scope, %{"acceptance_criteria" => @unproven})

      assert {:error, {:criteria_unmet, [1]}} =
               Close.close(task.id, "w", observed_epoch: 0, lifecycle_status: "done")

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open", "the close must not land"
      assert reloaded.rev == task.rev, "rev untouched on refusal"
    end

    test "a closer that flips its OWN criteria in the closing command still hits the gate",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-gate-selfflip"), scope, %{"acceptance_criteria" => @unproven})

      # This is the whole point of the seat (close.ex, `check_criteria_proven/6`
      # in do_close_txn's `with` chain, on the doc read under the advisory lock):
      # a payload that flips every criterion met=true is measured against the
      # PRE-merge state, so it cannot satisfy the gate it is being judged by.
      assert {:error, {:criteria_unmet, [1]}} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [
                   %{
                     "index" => 0,
                     "met" => true,
                     "evidence" => "self-issued",
                     "criterion" => "A: built"
                   },
                   %{
                     "index" => 1,
                     "met" => true,
                     "evidence" => "self-issued",
                     "criterion" => "B: proven"
                   }
                 ]
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open"
      assert reloaded.content["acceptance_criteria"] == @unproven, "no partial criteria write"
    end

    # ─── BOTH DIRECTIONS OF THE FLIP (task-c652c3ba8129c607) ───────────────
    #
    # The test ABOVE is the false->true arm: the closer may not prove its own
    # homework. The two below are the mirror, which sailed straight through
    # until this row — the gate read only the BEFORE snapshot, so a criterion
    # stamped `met: true` and LOWERED to false by the closing write left the
    # row `done` with an unmet criterion and NO `close_override` at all.
    # Reproduced on prod row task-8e3942fa840b8bf3 before the fix: close rc=0,
    # lifecycle `done`, criterion `met: false`, `close_override` absent from the
    # raw read-back, one advisory warning and nothing else.
    #
    # The two fixtures below are DISTINCT by construction and asserted so: the
    # false->true fixture stores index 1 UNMET, the true->false fixture stores
    # every criterion MET. If they were ever the same list neither test would
    # be measuring the direction it names.

    @all_met [
      %{"criterion" => "A: built", "met" => true, "evidence" => "PR #1"},
      %{"criterion" => "B: proven", "met" => true, "evidence" => "PR #2"}
    ]

    test "the two direction fixtures are distinct — @unproven stores an unmet row, @all_met does not",
         %{scope: _scope} do
      refute @unproven == @all_met

      assert Enum.any?(@unproven, &(Map.get(&1, "met") != true)),
             "@unproven must store an unmet row"

      assert Enum.all?(@all_met, &(Map.get(&1, "met") == true)),
             "@all_met must store no unmet row"
    end

    test "a closer that LOWERS a met criterion to false in the closing command hits the gate",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-gate-lower"), scope, %{"acceptance_criteria" => @all_met})

      # The mirror of the test above. Pre-write the row is fully proven, so the
      # BEFORE snapshot alone says "nothing unmet, pass" — and the same write
      # then lowers index 1. The gate must measure the union of both snapshots,
      # so this is refused naming the index the close is about to un-prove.
      assert {:error, {:criteria_unmet, [1]}} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 1, "met" => false, "criterion" => "B: proven"}]
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open", "the close must not land"
      assert reloaded.content["acceptance_criteria"] == @all_met, "no partial criteria write"
      assert reloaded.rev == task.rev, "rev untouched on refusal"
    end

    test "the lowering close is APPEALABLE — criteria_override lands it and records the unmet row",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-gate-lower-ovr"), scope, %{"acceptance_criteria" => @all_met})

      # The refusal above is a refusal, not a wall. This is the whole reason the
      # union arm gates a REFUSAL rather than forbidding the flip outright: the
      # closer with a real reason to lower a lock and close anyway says so ON
      # THE RECORD, and `close_override.criteria` is that record — the exact key
      # whose absence was the defect.
      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 1, "met" => false, "criterion" => "B: proven"}],
                 criteria_override: "review refuted the proof; closing done anyway"
               )

      assert closed.content["lifecycle_status"] == "done"
      record = get_in(closed.content, ["close_override", "criteria"])
      assert record, "closing over an unmet criterion must mint close_override.criteria"
      assert record["reason"] == "review refuted the proof; closing done anyway"
      assert Enum.map(record["unmet"], & &1["index"]) == [1]
      assert Enum.at(closed.content["acceptance_criteria"], 1)["met"] == false
    end

    test "a fully-proven task closes with no override and no record", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      proven = [%{"criterion" => "A: built", "met" => true, "evidence" => "PR #1"}]
      task = mk_task!(uniq("crit-gate-proven"), scope, %{"acceptance_criteria" => proven})

      assert {:ok, closed} =
               Close.close(task.id, "w", observed_epoch: 0, lifecycle_status: "done")

      assert closed.content["lifecycle_status"] == "done"
      refute Map.has_key?(closed.content, "close_override")
    end

    # D289 has nothing to measure here, and that is the whole point: it answers
    # `{:ok, nil}` VACUOUSLY. PDS-D291 is what now stands in that gap, so the
    # close needs an artifact in its reason — the row is closed by naming the PR
    # and sha, not by saying "done". Opts out of the fixture criterion on purpose.
    test "a task with NO acceptance criteria is unaffected", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-gate-none"), scope, %{"acceptance_criteria" => []})

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 reason: "landed #14383 @ 63b89bef30"
               )

      assert closed.content["lifecycle_status"] == "done"
    end

    test "cancelled is EXEMPT by name — unmet criteria close unchanged", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-gate-cancelled"), scope, %{"acceptance_criteria" => @unproven})

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "cancelled",
                 reason: "cancelled by the close test fixture"
               )

      assert closed.content["lifecycle_status"] == "cancelled"
      assert closed.content["acceptance_criteria"] == @unproven, "criteria untouched"
      refute Map.has_key?(closed.content, "close_override"), "an exemption is not an override"
    end

    test "blocked is EXEMPT by name — unmet criteria close unchanged", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-gate-blocked"), scope, %{"acceptance_criteria" => @unproven})

      assert {:ok, closed} =
               Close.close(task.id, "w", observed_epoch: 0, lifecycle_status: "blocked")

      assert closed.content["lifecycle_status"] == "blocked"
      refute Map.has_key?(closed.content, "close_override")
    end

    test "the override lands the unproven close AND records actor + unmet + reason",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-gate-override"), scope, %{"acceptance_criteria" => @unproven})

      assert {:ok, _closed} =
               Close.close(task.id, "oc-lead",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria_override: "B is proven by the wave paper, not by this repo"
               )

      record = Repo.get!(Document, task.id).content["close_override"]["criteria"]
      assert record["actor"] == "oc-lead"
      assert record["reason"] == "B is proven by the wave paper, not by this repo"
      assert record["unmet"] == [%{"index" => 1, "criterion" => "B: proven"}]
      assert is_binary(record["ts"])
    end

    test "a blank criteria_override reason is NOT an override", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-gate-blank"), scope, %{"acceptance_criteria" => @unproven})

      assert {:error, {:criteria_unmet, [1]}} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria_override: "   "
               )
    end

    test "a malformed criteria payload keeps its OWN error ahead of the unmet gate",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-gate-precedence"), scope, %{"acceptance_criteria" => @unproven})

      # Out of range, stale text guard, and an unguarded met-flip each keep the
      # precise error the D56 guards ship — the unmet gate never masks them.
      assert {:error, :criteria_index_out_of_range} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 9, "met" => false}]
               )

      assert {:error, :criteria_mismatch} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 1, "criterion" => "stale text", "met" => true}]
               )

      assert {:error, :criterion_text_required} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 1, "met" => true, "evidence" => "no text"}]
               )

      assert Repo.get!(Document, task.id).rev == task.rev, "nothing written on any of them"
    end

    test "BOTH overrides on one close write BOTH records", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      doc_id = uniq("crit-gate-both")
      task = mk_task!(doc_id, scope, %{"acceptance_criteria" => @unproven})
      assert {:ok, claimed} = Tasks.claim_by_id(doc_id, "worker-A", scope)

      assert {:ok, _} =
               Close.close(task.id, "oc-lead",
                 observed_epoch: claimed.content["claim"]["epoch"],
                 lifecycle_status: "done",
                 holder_override: "lead seal",
                 criteria_override: "proven in the wave paper"
               )

      override = Repo.get!(Document, task.id).content["close_override"]
      assert override["holder"]["held_by"] == "worker-A"
      assert override["criteria"]["unmet"] == [%{"index" => 1, "criterion" => "B: proven"}]
    end
  end

  # ─── (11) SENTINEL WORKER IDS (PDS-D290) ──────────────────────────────────
  #
  # 21 recorded closes carry the literal string "None" as closed_by — a
  # stringified null that reads as a real closer to every downstream gate,
  # accepted because nothing validated the SHAPE of a non-empty binary.

  describe "close/3 — sentinel worker ids" do
    test "empty-after-trim and None|null|nil|- are refused before the DB is touched",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("sentinel"), scope)

      for sentinel <- ["", "   ", "None", "none", "NULL", "null", "nil", "-", " None "] do
        result = Close.close(task.id, sentinel, observed_epoch: 0, lifecycle_status: "done")

        assert match?({:error, {:sentinel_worker_id, ^sentinel}}, result),
               "#{inspect(sentinel)} must never be recorded as a closer, got #{inspect(result)}"
      end

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open"
      assert reloaded.rev == task.rev
    end

    test "a worker id that merely CONTAINS a sentinel is fine", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("sentinel-ok"), scope)

      assert {:ok, closed} =
               Close.close(task.id, "none-of-your-business",
                 observed_epoch: 0,
                 lifecycle_status: "done"
               )

      assert closed.content["lifecycle_status"] == "done"
    end
  end

  # ─── TEXT-KEYED CRITERIA — the authoring rubric shape (gh-2314) ──────────
  #
  # The defect this closes: `bp task get` prints acceptance criteria as
  # `{"criterion": …, "met": …, "evidence": …}`, and until now a close could
  # only address them as `{"index": N, …}`. An agent had to translate the rubric
  # it had just read into 0-based indices by hand — and when it got that wrong,
  # its only recourse was to mutate the published document directly.
  #
  # These tests pin the resolution law: exactly one exact-text match resolves;
  # zero and many are NAMED refusals that write nothing. Resolution happens
  # inside the close's own transaction, so a text-keyed close is atomic in the
  # same sense an indexed one is.
  describe "close/3 — :criteria option (text-keyed rubric rows)" do
    @rubric [
      %{"criterion" => "the reader survives a nil workspace", "met" => false},
      %{"criterion" => "the 500 is gone", "met" => false}
    ]

    test "a rubric row with no index resolves by exact text and flips that row only",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-text-happy"), scope, %{"acceptance_criteria" => @rubric})

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 # D289 measures the doc AS READ, so this close still needs a
                 # recorded reason — unchanged by the new shape.
                 criteria_override: "text-keyed merge under test, not criteria proof",
                 criteria: [
                   %{
                     "criterion" => "the 500 is gone",
                     "met" => true,
                     "evidence" => "PR #14349 + controller test"
                   }
                 ]
               )

      [first, second] = closed.content["acceptance_criteria"]

      # The SECOND row is the one that carried that wording — resolution is by
      # text, not by position, and a 0-based-by-habit reader would have hit the
      # first.
      assert second["met"] == true
      assert second["evidence"] == "PR #14349 + controller test"
      assert second["criterion"] == "the 500 is gone"
      # The untargeted row is byte-identical: no reordering, no rewriting.
      assert first == %{"criterion" => "the reader survives a nil workspace", "met" => false}
    end

    test "the whole rubric can be pasted back — mixed met values, one write", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-text-whole"), scope, %{"acceptance_criteria" => @rubric})

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "blocked",
                 criteria: [
                   %{
                     "criterion" => "the reader survives a nil workspace",
                     "met" => true,
                     "evidence" => "close_test: nil-workspace read"
                   },
                   %{"criterion" => "the 500 is gone", "met" => false}
                 ]
               )

      assert [
               %{"met" => true, "evidence" => "close_test: nil-workspace read"},
               %{"met" => false}
             ] = closed.content["acceptance_criteria"]

      assert closed.content["lifecycle_status"] == "blocked"
    end

    test "a text that matches NO stored row is refused and writes nothing", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-text-missing"), scope, %{"acceptance_criteria" => @rubric})

      assert {:error, :criterion_not_found} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [
                   %{
                     # One character off — the match is EXACT on purpose.
                     "criterion" => "the 500 is gone.",
                     "met" => true,
                     "evidence" => "close-time proof"
                   }
                 ]
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.rev == task.rev, "a refused resolution is not a partial write"
      assert reloaded.content["lifecycle_status"] == "open"
      assert reloaded.content["acceptance_criteria"] == @rubric
    end

    test "two rows sharing one wording are AMBIGUOUS — refused, never guessed",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      dupes = [
        %{"criterion" => "ships with a test", "met" => false},
        %{"criterion" => "ships with a test", "met" => false}
      ]

      task = mk_task!(uniq("crit-text-dupe"), scope, %{"acceptance_criteria" => dupes})

      assert {:error, :criterion_ambiguous} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [
                   %{"criterion" => "ships with a test", "met" => true, "evidence" => "proof"}
                 ]
               )

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.rev == task.rev
      assert reloaded.content["acceptance_criteria"] == dupes

      # The indexed shape is the documented way through an ambiguity: it says
      # WHICH row, and its text guard still has to match.
      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria_override: "disambiguation under test",
                 criteria: [
                   %{
                     "index" => 1,
                     "criterion" => "ships with a test",
                     "met" => true,
                     "evidence" => "proof"
                   }
                 ]
               )

      assert [%{"met" => false}, %{"met" => true, "evidence" => "proof"}] =
               closed.content["acceptance_criteria"]
    end

    test "a text-keyed met-flip is guarded BY CONSTRUCTION — the text is the CAS",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("crit-text-guard"), scope, %{"acceptance_criteria" => @rubric})

      # The D56 refusal (:criterion_text_required) exists for an index with no
      # text. A text-keyed entry can never be in that state — it resolved BY the
      # text — so the same flip that 409s as `{"index":1,"met":true}` lands here.
      assert {:error, :criterion_text_required} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria: [%{"index" => 1, "met" => true, "evidence" => "no text"}]
               )

      assert {:ok, closed} =
               Close.close(task.id, "w",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 criteria_override: "guard-by-construction under test",
                 criteria: [
                   %{"criterion" => "the 500 is gone", "met" => true, "evidence" => "no index"}
                 ]
               )

      assert [_, %{"met" => true, "evidence" => "no index"}] =
               closed.content["acceptance_criteria"]
    end
  end

  # ── THE CLAIMLESS CLOSE RECORDED NOBODY (pds-bl-close-audit-gaps) ───────────
  #
  # `apply_close_update/9` stamps `closed_by` only inside its
  # `%{"claim" => claim} when is_map(claim)` arm. A row that was NEVER claimed
  # falls to `_ ->`, which writes `lifecycle_status` and nothing else — so the
  # close, and the `task.closed` event it emits, named no closer at all.
  #
  # MEASURED on the guerrilla ledger 2026-09-06, whole population: of 8,606
  # `type:task` rows, 6,617 are terminal and 139 of those carry no claim map at
  # all (84 done, 53 cancelled, 2 blocked). NON-VACUITY for that count: 6,332
  # rows DO carry `claim.closed_by` and 6,803 carry a claim map, so the probe
  # can see the field and the 139 is a real absence. Three of the 139 were
  # closed in the trailing 14 days — the hole is live, not historical.
  #
  # EVERY ONE OF THE 139 IS LEGITIMATELY CLAIMLESS. Container/root rows (13 of
  # them carry children) and killed backlog rows nobody ever picked up are
  # supposed to close without a lease; `cancelled` and `blocked` are exempt
  # from the criteria gate BY NAME for exactly that reason. A LEAD sealing
  # somebody else's row is NOT in this set — that row HAS a claim, so it takes
  # the claim arm and `closed_by` is already stamped there.
  #
  # SO THE FIX RECORDS THE CLOSER WITHOUT INVENTING A HOLDER. "Never claimed"
  # and "closed by nobody" are two different facts and the ledger has to keep
  # telling them apart, so the identity goes where an audit actually reads
  # it — onto the `task.closed` mutation event, beside the `caller_token_id`
  # stamp already there — and the DOCUMENT keeps saying, truthfully, that this
  # row was never held. Synthesising a claim map instead would also silently
  # convert `idempotent_replay?/3` — which deliberately refuses to answer a
  # replay on a claimless row, because an unidentifiable second caller must not
  # be handed a success receipt — into exactly that receipt.
  describe "close/3 — every close names its closer on the task.closed event" do
    test "a NEVER-CLAIMED task's close names the closer on its event", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("claimless"), scope)
      refute Map.has_key?(task.content, "claim"), "fixture must reach the `_ ->` arm"

      assert {:ok, closed} =
               Close.close(task.id, "w-claimless",
                 observed_epoch: 0,
                 lifecycle_status: "done",
                 caller_token_id: "tok-claimless"
               )

      assert [ev] = events(task.doc_id, "task.closed")

      assert ev.document["closed_by"] == "w-claimless",
             "a claimless close must still name a closer on the event"

      # The token stamp that was already there is untouched — the two actors
      # stay distinguishable (asserted worker vs authenticated bearer).
      assert ev.document["caller_token_id"] == "tok-claimless"

      # AND THE ROW IS STILL HONESTLY CLAIMLESS. No holder was invented.
      refute Map.has_key?(closed.content, "claim")
      assert Repo.get!(Document, task.id).content["claim"] == nil
    end

    test "a claimless close with NO api_token names the worker and omits the token", %{
      scope: scope
    } do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("claimless-anon"), scope)

      assert {:ok, _} =
               Close.close(task.id, "w-anon",
                 observed_epoch: 0,
                 lifecycle_status: "cancelled",
                 reason: "cancelled by the close test fixture"
               )

      assert [ev] = events(task.doc_id, "task.closed")
      assert ev.document["closed_by"] == "w-anon"
      refute Map.has_key?(ev.document, "caller_token_id")
    end

    test "a CLAIMED close carries the same event stamp beside claim.closed_by", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("claimed"), scope, %{
          "lifecycle_status" => "in_progress",
          "claim" => %{"worker" => "w-held", "epoch" => 1}
        })

      assert {:ok, closed} =
               Close.close(task.id, "w-held", observed_epoch: 1, lifecycle_status: "done")

      assert closed.content["claim"]["closed_by"] == "w-held"
      assert [ev] = events(task.doc_id, "task.closed")
      assert ev.document["closed_by"] == "w-held"
    end
  end
end
