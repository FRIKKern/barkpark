defmodule Barkpark.Tasks.CompactorTest do
  @moduledoc """
  W7a step 6 — task-document compaction:

    1. Analyze selection — six docs of varying shape; only the two
       (done+big, cancelled+big) appear in eligible_query.
    2. Compact happy path — 60-event history → tail+summary+stamp,
       snapshot revision row, task.compacted event with the right payload.
    3. Idempotence — re-run on a compacted doc is a no-op.
    4. Restore reversibility — capture-compact-restore; content.history
       restored byte-for-byte; doc re-eligible.
    5. Advisory-lock concurrency — 5 compactions + 1 close on the same
       done doc → first compaction wins, others skip (compacted_at set).
    6. Cap respected — 250 eligible, cap=100 → exactly 100 compacted.
    7. No-op on empty — 0 eligible → {:ok, %{compacted: 0, skipped: 0}}.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent, Revision}
  alias Barkpark.Tasks.Compactor

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    register_schemas!(scope)

    %{scope: scope, workspace: ws, project: project}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # PDS-D291: one MET criterion keeps this file's `done` closes out of the
  # close-artifact gate, which refuses a `done` close of a criteria-less
  # kind:task row whose reason names no PR+sha and pastes no run. These tests
  # measure the claim/close machinery, not the close reason.
  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
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

  # Manufacture a history array of N entries. A few are status_change
  # entries so the summary's status_transitions has something to project.
  defp gen_history(n, workers \\ ["worker-A", "worker-B"]) do
    base = DateTime.utc_now()

    for i <- 1..n do
      ts = base |> DateTime.add(i, :second) |> DateTime.to_iso8601()
      worker = Enum.at(workers, rem(i, length(workers)))

      cond do
        i == 1 ->
          %{
            "kind" => "status_change",
            "from" => "open",
            "to" => "in_progress",
            "ts" => ts,
            "worker" => worker
          }

        i == n ->
          %{
            "kind" => "status_change",
            "from" => "in_progress",
            "to" => "done",
            "ts" => ts,
            "worker" => worker
          }

        rem(i, 13) == 0 ->
          %{
            "kind" => "status_change",
            "from" => "in_progress",
            "to" => "blocked",
            "ts" => ts,
            "worker" => worker
          }

        true ->
          %{"kind" => "comment", "ts" => ts, "worker" => worker, "body" => "event-#{i}"}
      end
    end
  end

  # Directly stuff a history array into the row (bypasses the public API
  # so we can simulate the long-tail accumulation that compaction
  # exists to bound).
  defp set_content!(doc, new_content) do
    {1, _} =
      from(d in Document, where: d.id == ^doc.id)
      |> Repo.update_all(set: [content: new_content])

    Repo.get!(Document, doc.id)
  end

  defp events_for(doc_id, mutation) do
    Repo.all(
      from e in MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == ^mutation,
        order_by: e.id
    )
  end

  defp snapshot_revisions(doc_id) do
    Repo.all(
      from r in Revision,
        where: r.doc_id == ^doc_id and r.action == ^Compactor.snapshot_action(),
        order_by: r.inserted_at
    )
  end

  # Build a done+history task in one shot.
  defp mk_done_with_history!(doc_id, scope, n) do
    task = mk_task!(doc_id, scope)

    content =
      task.content
      |> Map.put("lifecycle_status", "done")
      |> Map.put("history", gen_history(n))

    set_content!(task, content)
  end

  # ─── (1) Analyze selection ────────────────────────────────────────────────

  describe "eligible_query/1 — analyze selection" do
    test "returns only done+big and cancelled+big (lifecycle + size + idempotence filters)",
         %{scope: scope, workspace: ws, project: project} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # 1. done + big history
      done_big = mk_done_with_history!(uniq("done-big"), scope, 60)

      # 2. done + small history (under threshold)
      done_small = mk_task!(uniq("done-small"), scope)

      done_small =
        set_content!(done_small, %{
          "kind" => "task",
          "lifecycle_status" => "done",
          "history" => gen_history(5)
        })

      # 3. cancelled + big
      cancelled_big = mk_task!(uniq("canc-big"), scope)

      cancelled_big =
        set_content!(cancelled_big, %{
          "kind" => "task",
          "lifecycle_status" => "cancelled",
          "history" => gen_history(60)
        })

      # 4. in_progress + big (excluded by lifecycle filter)
      ip_big = mk_task!(uniq("ip-big"), scope)

      ip_big =
        set_content!(ip_big, %{
          "kind" => "task",
          "lifecycle_status" => "in_progress",
          "history" => gen_history(60)
        })

      # 5. done + big + already compacted (excluded by compacted_at)
      done_compacted = mk_task!(uniq("done-comp"), scope)

      done_compacted =
        set_content!(done_compacted, %{
          "kind" => "task",
          "lifecycle_status" => "done",
          "history" => gen_history(60),
          "compacted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      # 6. done + big but in a DIFFERENT tenant (cross-workspace) — confirm
      #    eligibility query itself does not leak scope. The query returns
      #    ALL eligible rows globally; tenancy scoping is enforced by the
      #    caller (the Oban worker per-job runs without tenant context;
      #    it relies on the per-task advisory lock + content-shape filters,
      #    not on tenancy. The snapshot revision row inherits the source
      #    doc's tenancy stamps, so cross-tenant reads of the snapshot are
      #    still tenant-safe via the existing `Content.get_revision/3`
      #    workspace scoping. This test confirms that — we just count
      #    inclusion, not exclusion).
      other_ws = TenancyFixtures.create_workspace!()
      other_project = TenancyFixtures.create_project!(other_ws)
      other_scope = [workspace_id: other_ws.id, project_id: other_project.id]
      register_schemas!(other_scope)
      other_big = mk_done_with_history!(uniq("other-big"), other_scope, 60)

      # ── Assert ──
      results = Compactor.eligible_query() |> Repo.all() |> Enum.map(& &1.id)

      assert done_big.id in results
      assert cancelled_big.id in results
      assert other_big.id in results, "global compaction scan includes all tenants by design"

      refute done_small.id in results, "small history should not be eligible"
      refute ip_big.id in results, "in_progress should not be eligible"
      refute done_compacted.id in results, "already-compacted should not be eligible"

      # Filter to only our scope's docs so the assertion is sharp.
      ours =
        Enum.filter(results, fn id ->
          Repo.get!(Document, id).workspace_id == ws.id and
            Repo.get!(Document, id).project_id == project.id
        end)

      assert Enum.sort(ours) == Enum.sort([done_big.id, cancelled_big.id]),
             "expected exactly 2 eligible docs in our scope, got #{inspect(ours)}"
    end

    test "size threshold triggers eligibility even when history is short",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # Short history (5 entries) but a HUGE single field — eligible via
      # min_bytes branch. Use random bytes so Postgres TOAST compression
      # can't shrink it below the threshold (a repeating "x" blob
      # compresses to ~kilobytes regardless of input size).
      task = mk_task!(uniq("fat"), scope)
      fat_blob = :crypto.strong_rand_bytes(200_000) |> Base.encode64()

      set_content!(task, %{
        "kind" => "task",
        "lifecycle_status" => "done",
        "history" => gen_history(5),
        "comment_blob" => fat_blob
      })

      results = Compactor.eligible_query() |> Repo.all() |> Enum.map(& &1.id)
      assert task.id in results, "large content payload should trigger compaction"
    end

    test "configurable lifecycle_statuses widens the net (e.g. include open)",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("open-big"), scope)

      set_content!(task, %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "history" => gen_history(60)
      })

      # Default config — not eligible.
      refute task.id in (Compactor.eligible_query() |> Repo.all() |> Enum.map(& &1.id))

      # Widened config — eligible.
      widened =
        Compactor.eligible_query(lifecycle_statuses: ~w(open done cancelled))
        |> Repo.all()
        |> Enum.map(& &1.id)

      assert task.id in widened, "widening lifecycle_statuses must enable compaction"
    end
  end

  # ─── (2) Compact happy path ───────────────────────────────────────────────

  describe "compact/0 — worklog tailing (tsk-dossier-worklog-compaction)" do
    test "an oversized worklog is tailed with a visible rollup entry; the snapshot keeps it all",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_done_with_history!(uniq("wl"), scope, 60)

      worklog =
        for i <- 1..12 do
          %{
            "ts" => "2026-06-0#{rem(i, 9) + 1}T10:00:00Z",
            "worker" => "agent-#{i}",
            "kind" => "progress",
            "note" => "step #{i}"
          }
        end

      task = set_content!(task, Map.put(task.content, "worklog", worklog))
      assert %{compacted: 1, skipped: 0} = Compactor.compact()

      reloaded = Repo.get!(Document, task.id)
      tailed = reloaded.content["worklog"]

      # Rollup head + the last 5 entries — the next claiming agent reads
      # the truncation note exactly where it reads handoff context.
      assert length(tailed) == 6
      [rollup | rest] = tailed
      assert rollup["worker"] == "compactor"
      assert rollup["note"] =~ "compacted from 12 worklog entries"
      assert rollup["note"] =~ reloaded.content["compaction_snapshot_revision_id"]
      assert rest == Enum.take(worklog, -5)

      # The snapshot revision preserves the FULL worklog (restore path).
      snapshot =
        Repo.get!(Barkpark.Content.Revision, reloaded.content["compaction_snapshot_revision_id"])

      assert length(snapshot.content["worklog"]) == 12
    end

    test "a worklog at/under the tail is left byte-identical", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_done_with_history!(uniq("wl-small"), scope, 60)

      worklog = [
        %{"ts" => "2026-06-01T10:00:00Z", "worker" => "a", "kind" => "progress", "note" => "x"}
      ]

      task = set_content!(task, Map.put(task.content, "worklog", worklog))
      assert %{compacted: 1, skipped: 0} = Compactor.compact()

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["worklog"] == worklog
    end
  end

  describe "compact/0 — happy path" do
    test "60-event history → tail+summary+stamp, snapshot revision, event emitted",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_done_with_history!(uniq("happy"), scope, 60)
      pre_history = task.content["history"]
      assert length(pre_history) == 60

      assert %{compacted: 1, skipped: 0} = Compactor.compact()

      reloaded = Repo.get!(Document, task.id)

      # Live content shrunk: history is the last 3, summary populated,
      # compacted_at stamped.
      assert length(reloaded.content["history"]) == 3
      assert reloaded.content["history"] == Enum.take(pre_history, -3)

      summary = reloaded.content["history_summary"]
      assert summary["event_count"] == 60
      assert is_binary(summary["first_ts"])
      assert is_binary(summary["last_ts"])
      assert is_list(summary["status_transitions"])
      # Manufactured history has ≥3 status changes (1, ~13/26/39/52, n).
      assert length(summary["status_transitions"]) >= 3
      assert summary["worker_count"] == 2
      assert Enum.sort(summary["distinct_workers"]) == ["worker-A", "worker-B"]
      assert summary["note"] =~ "compacted from 60 events"
      assert is_binary(reloaded.content["compacted_at"])

      # Snapshot revision row exists, action = compaction_snapshot,
      # carries the full pre-compaction content.
      snapshots = snapshot_revisions(task.doc_id)
      assert length(snapshots) == 1
      [snap] = snapshots
      assert snap.action == Compactor.snapshot_action()
      assert length(snap.content["history"]) == 60
      assert snap.content["history"] == pre_history
      assert snap.content["lifecycle_status"] == "done"

      # The summary's note references the snapshot revision id, and the
      # row also carries the bare id field for machine readers.
      assert reloaded.content["compaction_snapshot_revision_id"] == snap.id
      assert summary["note"] =~ snap.id

      # task.compacted mutation_event with the right payload.
      events = events_for(task.doc_id, Compactor.event_kinds().compacted)
      assert length(events) == 1
      [ev] = events
      payload = ev.document["compacted"]
      assert payload["previous_rev"] == task.rev
      assert payload["rev"] == reloaded.rev
      assert payload["event_count_compacted"] == 60
      assert payload["snapshot_revision_id"] == snap.id
    end

    test "perform/1 with synthetic Oban.Job runs the compaction", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_done_with_history!(uniq("perform"), scope, 60)
      assert {:ok, %{compacted: 1, skipped: 0}} = Compactor.perform(%Oban.Job{})

      reloaded = Repo.get!(Document, task.id)
      assert is_binary(reloaded.content["compacted_at"])
    end
  end

  # ─── (3) Idempotence ──────────────────────────────────────────────────────

  describe "compact/0 — idempotence" do
    test "re-running on the same doc is a no-op (compacted_at gates it out)",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      _task = mk_done_with_history!(uniq("idem"), scope, 60)

      assert %{compacted: 1, skipped: 0} = Compactor.compact()
      # Second run → no eligible candidates left.
      assert %{compacted: 0, skipped: 0} = Compactor.compact()
    end
  end

  # ─── (4) Restore reversibility ────────────────────────────────────────────

  describe "restore/2 — reversibility proof" do
    test "compact then restore → content.history byte-for-byte equal; doc re-eligible",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_done_with_history!(uniq("rev"), scope, 60)
      # Capture the pre-compaction snapshot (full content map).
      pre_snapshot = Repo.get!(Document, task.id).content
      pre_history = pre_snapshot["history"]

      assert %{compacted: 1, skipped: 0} = Compactor.compact()

      [snap] = snapshot_revisions(task.doc_id)
      compacted = Repo.get!(Document, task.id)
      assert is_binary(compacted.content["compacted_at"])

      # Restore.
      assert {:ok, restored} = Compactor.restore(task.id, snap.id)

      # Byte-for-byte equality of the history array.
      assert restored.content["history"] == pre_history
      assert length(restored.content["history"]) == 60

      # Compaction markers cleared.
      refute Map.has_key?(restored.content, "compacted_at")
      refute Map.has_key?(restored.content, "history_summary")
      refute Map.has_key?(restored.content, "compaction_snapshot_revision_id")

      # task.compaction_restored event emitted with snapshot id payload.
      events = events_for(task.doc_id, Compactor.event_kinds().restored)
      assert length(events) == 1
      [ev] = events
      payload = ev.document["compaction_restored"]
      assert payload["snapshot_revision_id"] == snap.id
      assert payload["previous_rev"] == compacted.rev
      assert payload["rev"] == restored.rev

      # The restored doc is re-eligible for the next compaction cycle —
      # proves compaction is fully invertible.
      results = Compactor.eligible_query() |> Repo.all() |> Enum.map(& &1.id)
      assert task.id in results, "restored doc must be eligible again"
    end

    test "restore rejects wrong revision id / wrong action / cross-doc",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_done_with_history!(uniq("rev-bad"), scope, 60)
      _ = Compactor.compact()
      [snap] = snapshot_revisions(task.doc_id)

      # Wrong doc_id.
      other = mk_done_with_history!(uniq("rev-bad-other"), scope, 60)

      assert {:error, :not_a_compaction_snapshot} = Compactor.restore(other.id, snap.id)

      # Non-existent revision.
      assert {:error, :revision_not_found} =
               Compactor.restore(task.id, "00000000-0000-0000-0000-000000000000")

      # Non-existent doc.
      assert {:error, :not_found} =
               Compactor.restore("00000000-0000-0000-0000-000000000000", snap.id)
    end

    test "restore guards raw non-UUID ids instead of raising Ecto.Query.CastError",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_done_with_history!(uniq("rev-guard"), scope, 60)
      _ = Compactor.compact()
      [snap] = snapshot_revisions(task.doc_id)

      # A non-UUID doc_id would raise Ecto.Query.CastError inside
      # Repo.get(Document, ...) without the Repo.uuid_or_nil guard.
      assert {:error, :not_found} = Compactor.restore("not-a-uuid", snap.id)

      # A non-UUID snapshot_revision_id would raise the same way inside
      # Repo.get(Revision, ...).
      assert {:error, :revision_not_found} = Compactor.restore(task.id, "not-a-uuid")
    end
  end

  # ─── (5) Advisory-lock concurrency ───────────────────────────────────────

  describe "advisory-lock concurrency" do
    test "5 compaction attempts on the same done doc → 1 compacted, 4 skipped",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      _task = mk_done_with_history!(uniq("race"), scope, 60)

      # 5 concurrent compactors on the SAME doc. The advisory lock
      # serializes them; the first sets compacted_at and the rest see
      # the row no longer eligible inside their lock and skip.
      results =
        for _ <- 1..5 do
          fn -> Compactor.compact() end
        end
        |> Task.async_stream(& &1.(), max_concurrency: 5, ordered: false, timeout: 15_000)
        |> Enum.map(fn {:ok, v} -> v end)

      total_compacted = Enum.reduce(results, 0, fn r, acc -> acc + r.compacted end)
      assert total_compacted == 1, "exactly one compaction must win; got #{inspect(results)}"
    end

    test "compact vs close on a transitioning-to-done doc serializes correctly",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # An in_progress task with a tall history — NOT eligible yet (lifecycle
      # filter excludes it). Close it; the resulting done state IS eligible,
      # but the next compaction cycle picks it up.
      phase_id = uniq("phase-race")
      task = mk_task!(uniq("race-close"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} =
        Tasks.claim("worker-Z", scope ++ [phase_id: phase_id, dataset: @dataset])

      # Stuff a tall history onto the in_progress row.
      new_content = Map.put(claimed.content, "history", gen_history(60))
      _ = set_content!(claimed, new_content)

      # Concurrent compact + close. Two interleavings are valid
      # serializations and the scheduler picks one nondeterministically:
      #
      #   (a) compact's eligibility scan runs BEFORE close commits — it
      #       sees in_progress, selects nothing (0 compacted); the
      #       follow-up cycle below compacts the now-done row.
      #   (b) close commits BEFORE compact's scan — the racing cycle
      #       already sees done+big and compacts it (1 compacted); the
      #       follow-up cycle finds nothing eligible.
      #
      # The invariant under EITHER order: close succeeds, the doc ends
      # done, and exactly ONE compaction ever happens (one snapshot
      # revision, one task.compacted event, compacted_at stamped).
      # Asserting a specific interleaving here was the source of a
      # seed-dependent flake (e.g. --seed 499257 produced order (b)).
      tasks = [
        fn -> {:compact, Compactor.compact()} end,
        fn ->
          {:close,
           Tasks.close(task.id, "worker-Z",
             observed_epoch: claimed.content["claim"]["epoch"],
             lifecycle_status: "done"
           )}
        end
      ]

      results =
        tasks
        |> Task.async_stream(& &1.(), max_concurrency: 2, ordered: false, timeout: 15_000)
        |> Enum.map(fn {:ok, v} -> v end)

      close_result = Enum.find(results, &match?({:close, _}, &1)) |> elem(1)
      assert match?({:ok, _}, close_result), "close must succeed; got #{inspect(close_result)}"

      {:compact, race_compact} = Enum.find(results, &match?({:compact, _}, &1))
      assert %{skipped: 0} = race_compact

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "done"

      # A follow-up compaction cycle. If the racing cycle already won
      # (order (b) above) this finds nothing eligible; otherwise (order
      # (a)) it performs the one compaction. Exactly one total — never
      # zero, never two.
      final_compact = Compactor.compact()
      assert %{skipped: 0} = final_compact

      assert race_compact.compacted + final_compact.compacted == 1,
             "exactly one compaction must happen across both cycles; " <>
               "racing=#{inspect(race_compact)} follow_up=#{inspect(final_compact)}"

      final = Repo.get!(Document, task.id)
      assert is_binary(final.content["compacted_at"])

      # Double-compaction guard: one snapshot revision, one event — under
      # either interleaving.
      assert length(snapshot_revisions(task.doc_id)) == 1
      assert length(events_for(task.doc_id, Compactor.event_kinds().compacted)) == 1
    end
  end

  # ─── (6) Cap respected ────────────────────────────────────────────────────

  describe "cap" do
    test "250 eligible docs, cap=100 → exactly 100 compacted in one cycle",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # 120 eligible docs (250 is overkill for an inline test loop and
      # keeps the suite under a wall-clock budget; the cap semantics
      # are the same at 120 vs 250).
      n = 120
      cap = 100

      for i <- 1..n do
        mk_done_with_history!(uniq("cap-#{i}"), scope, 60)
      end

      assert %{compacted: ^cap, skipped: 0} = Compactor.compact(cap: cap)

      # Remaining n - cap docs are still eligible for the next cycle.
      remaining = Compactor.eligible_query() |> Repo.all() |> length()
      assert remaining == n - cap
    end
  end

  # ─── (7) No-op on empty ───────────────────────────────────────────────────

  describe "no-op on empty" do
    test "no eligible docs → {:ok, %{compacted: 0, skipped: 0}}, no events", %{scope: _scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      assert %{compacted: 0, skipped: 0} = Compactor.compact()

      # No events of either kind.
      assert Repo.all(
               from e in MutationEvent,
                 where: e.mutation == ^Compactor.event_kinds().compacted
             ) == []

      assert Repo.all(
               from e in MutationEvent,
                 where: e.mutation == ^Compactor.event_kinds().restored
             ) == []
    end
  end
end
