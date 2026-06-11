defmodule Barkpark.Tasks.TtlSweeperTest do
  @moduledoc """
  W7a step 5 — TTL sweep: reap crashed-agent claims, bump fencing epoch,
  flip lifecycle_status back to `open`, emit `task.lease_expired`.

  Seven test categories, mapping 1:1 to the brief:

    1. Happy path — stale ts_iso (10 min ago) → reap; epoch bumps n→n+1,
       worker nil, lifecycle_status open, event written with full payload.
    2. Not-expired — fresh ts_iso → sweep is a no-op, no event.
    3. Fencing kick — the end-to-end W7-05↔W7-04 proof: claim, sweep,
       worker A's late close with the old epoch → `{:error, :fenced_off}`.
       This is the integration test that proves the sweeper is the real
       epoch bumper the W7-04 fencing test simulated.
    4. Re-claimable — after a sweep, the row appears in `Tasks.ready/1`
       again and a fresh claim by worker B succeeds with epoch=N+2.
    5. Advisory-lock contention — 5 sweeps + 1 close on the same expired
       task. Either close wins (status→done, epoch bumps normally) or
       sweep wins (status→open, epoch bumps, worker nil). No interleaving,
       no double-bump, no orphan events.
    6. No-op on closed tasks — a `done` task with a stale ts_iso is NOT
       swept (lifecycle_status filter excludes terminal states).
    7. Multi-task — 3 expired + 2 fresh → swept=3, skipped=0; fresh
       untouched, no spurious events.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.TtlSweeper

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

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{"kind" => "task", "lifecycle_status" => "open"},
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp events_for(doc_id, mutation) do
    import Ecto.Query

    Repo.all(
      from e in MutationEvent,
        where: e.doc_id == ^doc_id and e.mutation == ^mutation,
        order_by: e.id
    )
  end

  # Force a task's claim.ts_iso to `seconds_ago` seconds in the past.
  # Bypasses the public API to simulate "this worker claimed N seconds
  # ago and then crashed" without sleeping.
  defp age_claim!(doc, seconds_ago) do
    import Ecto.Query

    iso = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.to_iso8601()
    new_claim = Map.put(doc.content["claim"], "ts_iso", iso)
    new_content = Map.put(doc.content, "claim", new_claim)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id)
      |> Repo.update_all(set: [content: new_content])

    Repo.get!(Document, doc.id)
  end

  # ─── (1) Happy path ────────────────────────────────────────────────────────

  describe "sweep/1 — happy path" do
    test "claim with stale ts_iso → reaped, epoch bumped, worker nil, event emitted",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-happy")
      task = mk_task!(uniq("happy"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} =
        Tasks.claim("worker-A", scope ++ [phase_id: phase_id, dataset: @dataset])

      assert claimed.content["claim"]["epoch"] == 1
      assert claimed.content["claim"]["worker"] == "worker-A"
      assert claimed.content["lifecycle_status"] == "in_progress"

      _ = age_claim!(claimed, 600)

      # ttl=300 → 10 min ago is well past.
      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open"
      assert reloaded.content["claim"]["epoch"] == 2
      assert reloaded.content["claim"]["worker"] == nil
      assert reloaded.content["assignee"] == nil
      # The previous worker is preserved on the claim map for audit.
      assert reloaded.content["claim"]["previous_worker"] == "worker-A"
      assert is_binary(reloaded.content["claim"]["expired_at"])

      events = events_for(task.doc_id, TtlSweeper.event_kind())
      assert length(events) == 1
      [ev] = events
      payload = ev.document["lease_expired"]
      assert payload["previous_worker"] == "worker-A"
      assert payload["expired_epoch"] == 1
      assert payload["new_epoch"] == 2
      assert payload["rev"] == reloaded.rev
      assert payload["previous_rev"] == claimed.rev
      assert ev.workspace_id == task.workspace_id
    end

    test "sweep drops the dead worker's resource fences from the claim map",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("res-sweep"), scope)

      {:ok, claimed} =
        Tasks.claim_by_id(task.doc_id, "worker-R", scope ++ [resources: ["lib/x.ex"]])

      assert claimed.content["claim"]["resources"] == ["lib/x.ex"]

      _ = age_claim!(claimed, 600)
      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open"
      # No stale "holds lib/x.ex" on an open task — the fences died with
      # the lease (conflict scans filter in_progress, so this is pure
      # representation; Studio/TUI render the claim map verbatim).
      refute Map.has_key?(reloaded.content["claim"], "resources")
    end

    test "perform/1 with synthetic Oban.Job runs the sweep", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-perform")
      task = mk_task!(uniq("perform"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} =
        Tasks.claim("worker-perf", scope ++ [phase_id: phase_id, dataset: @dataset])

      _ = age_claim!(claimed, 600)

      Application.put_env(:barkpark, :task_lease_ttl_seconds, 1)
      on_exit(fn -> Application.put_env(:barkpark, :task_lease_ttl_seconds, 300) end)

      assert {:ok, %{swept: 1, skipped: 0}} = TtlSweeper.perform(%Oban.Job{})

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open"
      assert reloaded.content["claim"]["epoch"] == 2
    end

    test "claim with NULL ts_iso (malformed) is also reaped", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-null")
      task = mk_task!(uniq("null"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} =
        Tasks.claim("worker-N", scope ++ [phase_id: phase_id, dataset: @dataset])

      # Strip ts_iso from the claim — simulate a malformed in_progress row.
      import Ecto.Query

      claim_without_ts = Map.delete(claimed.content["claim"], "ts_iso")
      new_content = Map.put(claimed.content, "claim", claim_without_ts)

      {1, _} =
        from(d in Document, where: d.id == ^task.id)
        |> Repo.update_all(set: [content: new_content])

      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open"
      assert reloaded.content["claim"]["epoch"] == 2
    end
  end

  # ─── (2) Not expired ───────────────────────────────────────────────────────

  describe "sweep/1 — not expired" do
    test "claim with fresh ts_iso (now) → not swept, no event", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-fresh")
      task = mk_task!(uniq("fresh"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} =
        Tasks.claim("worker-Q", scope ++ [phase_id: phase_id, dataset: @dataset])

      # ts_iso is "right now" (claim/2 just stamped it); ttl=300 → not expired.
      assert %{swept: 0, skipped: 0} = TtlSweeper.sweep(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "in_progress"
      assert reloaded.content["claim"]["epoch"] == claimed.content["claim"]["epoch"]
      assert reloaded.content["claim"]["worker"] == "worker-Q"

      events = events_for(task.doc_id, TtlSweeper.event_kind())
      assert events == []
    end
  end

  # ─── (3) Fencing kick — end-to-end ────────────────────────────────────────

  describe "fencing kick — the W7-05↔W7-04 integration" do
    test "claim → sweep → late close with old epoch → {:error, :fenced_off}",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-fence")
      task = mk_task!(uniq("fence"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} =
        Tasks.claim("worker-A", scope ++ [phase_id: phase_id, dataset: @dataset])

      assert claimed.content["claim"]["epoch"] == 1
      _ = age_claim!(claimed, 600)

      # THE sweep — bumps epoch from 1 to 2, flips to open, clears worker.
      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["claim"]["epoch"] == 2
      assert reloaded.content["lifecycle_status"] == "open"

      # Worker A wakes from its mid-task crash and tries to close with
      # the epoch it saw at claim time (1). The fencing primitive
      # rejects it — this is the unreapable-claim safety net working
      # end-to-end. (Same shape as tasks_claim_test.exs's W7-04
      # simulated-sweep test, but here the SWEEPER is the real bumper.)
      assert {:error, :fenced_off} =
               Tasks.close(task.id, "worker-A",
                 observed_epoch: 1,
                 lifecycle_status: "done"
               )

      # And the row is still open (not flipped to done by the rejected close).
      after_attempt = Repo.get!(Document, task.id)
      assert after_attempt.content["lifecycle_status"] == "open"
    end
  end

  # ─── (4) Re-claimable after sweep ─────────────────────────────────────────

  describe "re-claimable after sweep" do
    test "ready/1 surfaces the swept task; new claim by worker B → epoch=3",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-reclaim")
      task = mk_task!(uniq("reclaim"), scope, %{"parent_id" => phase_id})

      # Claim cycle 1: A claims, A "crashes," sweep reaps.
      {:ok, claim_a} =
        Tasks.claim("worker-A", scope ++ [phase_id: phase_id, dataset: @dataset])

      assert claim_a.content["claim"]["epoch"] == 1
      _ = age_claim!(claim_a, 600)
      assert %{swept: 1} = TtlSweeper.sweep(300)

      # Sweep took epoch 1 → 2 (the fencing kick stored on the row).
      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["claim"]["epoch"] == 2

      # The row should now be back on the ready queue.
      ready = Tasks.ready(scope ++ [phase_id: phase_id, dataset: @dataset])
      assert Enum.any?(ready, &(&1.id == task.id)),
             "swept task should be ready again; ready=#{inspect(Enum.map(ready, & &1.doc_id))}"

      # Claim cycle 2: B claims. The next epoch must be 3 (monotonic from
      # the sweep's epoch=2, not a fresh-from-zero=1).
      {:ok, claim_b} =
        Tasks.claim("worker-B", scope ++ [phase_id: phase_id, dataset: @dataset])

      assert claim_b.id == task.id
      assert claim_b.content["claim"]["epoch"] == 3,
             "epoch must be monotonic across reap→reclaim; got #{claim_b.content["claim"]["epoch"]}"

      assert claim_b.content["claim"]["worker"] == "worker-B"
      assert claim_b.content["lifecycle_status"] == "in_progress"
    end
  end

  # ─── (5) Advisory-lock contention ─────────────────────────────────────────

  describe "advisory-lock contention" do
    test "5 sweeps + 1 close on the same expired task — consistent final state",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-contend")
      task = mk_task!(uniq("contend"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} =
        Tasks.claim("worker-X", scope ++ [phase_id: phase_id, dataset: @dataset])

      _ = age_claim!(claimed, 600)
      epoch = claimed.content["claim"]["epoch"]

      # 5 sweepers + 1 closer — racing on the SAME task. The advisory
      # lock guarantees serial execution. Final state is one of:
      #   (a) close won first → done + bumped rev; sweeps each see
      #       lifecycle_status != "in_progress" and skip.
      #   (b) any sweep won first → open + epoch+1; close sees its
      #       observed_epoch is stale → :fenced_off; further sweeps
      #       see lifecycle_status == "open" and skip.
      close_fn = fn ->
        {:close,
         Tasks.close(task.id, "worker-X",
           observed_epoch: epoch,
           lifecycle_status: "done"
         )}
      end

      sweep_fns = for _ <- 1..5, do: fn -> {:sweep, TtlSweeper.sweep(300)} end
      tasks = [close_fn | sweep_fns]

      results =
        tasks
        |> Task.async_stream(& &1.(), max_concurrency: 6, ordered: false, timeout: 15_000)
        |> Enum.map(fn {:ok, v} -> v end)

      reloaded = Repo.get!(Document, task.id)
      status = reloaded.content["lifecycle_status"]

      close_results = for {:close, r} <- results, do: r
      sweep_results = for {:sweep, r} <- results, do: r

      assert length(close_results) == 1
      assert length(sweep_results) == 5

      assert status in ["done", "open"],
             "unexpected final status #{inspect(status)}; results=#{inspect(results)}"

      lease_events = events_for(task.doc_id, TtlSweeper.event_kind())
      closed_events = events_for(task.doc_id, Tasks.event_kinds().closed)

      case status do
        "done" ->
          # Close won. Exactly one close event; no lease_expired event
          # (sweeps all skipped because status != in_progress inside lock).
          assert match?({:ok, _}, hd(close_results)),
                 "close should have returned {:ok, _}; got #{inspect(close_results)}"

          assert length(closed_events) == 1
          assert lease_events == [],
                 "no lease_expired events when close wins; got #{inspect(lease_events)}"

          # Epoch unchanged (close doesn't bump; only claim and sweep do).
          assert reloaded.content["claim"]["epoch"] == epoch

        "open" ->
          # Sweep won. Exactly one lease_expired event (subsequent
          # sweeps skip because status != in_progress under their lock).
          assert length(lease_events) == 1

          # Close failed — either :fenced_off (saw the bumped epoch) or
          # :stale_claim (lost CAS). Both are acceptable lost-race
          # outcomes.
          assert match?({:error, reason} when reason in [:fenced_off, :stale_claim], hd(close_results)),
                 "close should be fenced or stale; got #{inspect(close_results)}"

          assert reloaded.content["claim"]["epoch"] == epoch + 1
          assert reloaded.content["claim"]["worker"] == nil
      end
    end
  end

  # ─── (6) No-op on closed tasks ────────────────────────────────────────────

  describe "no-op on terminal-state tasks" do
    test "done task with stale ts_iso is NOT swept", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-done")
      task = mk_task!(uniq("done"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} =
        Tasks.claim("worker-D", scope ++ [phase_id: phase_id, dataset: @dataset])

      {:ok, closed} =
        Tasks.close(claimed.id, "worker-D",
          observed_epoch: claimed.content["claim"]["epoch"],
          lifecycle_status: "done"
        )

      assert closed.content["lifecycle_status"] == "done"

      # Backdate ts_iso to simulate a long-completed task.
      _ = age_claim!(closed, 999_999)

      assert %{swept: 0, skipped: 0} = TtlSweeper.sweep(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "done"
      assert events_for(task.doc_id, TtlSweeper.event_kind()) == []
    end

    test "cancelled task with stale ts_iso is NOT swept", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-canc")
      task = mk_task!(uniq("canc"), scope, %{"parent_id" => phase_id})

      {:ok, claimed} =
        Tasks.claim("worker-C", scope ++ [phase_id: phase_id, dataset: @dataset])

      {:ok, cancelled} =
        Tasks.close(claimed.id, "worker-C",
          observed_epoch: claimed.content["claim"]["epoch"],
          lifecycle_status: "cancelled"
        )

      _ = age_claim!(cancelled, 999_999)

      assert %{swept: 0, skipped: 0} = TtlSweeper.sweep(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "cancelled"
    end

    test "open task (never claimed) is NOT swept regardless of any stale fields",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_task!(uniq("never"), scope)
      assert task.content["lifecycle_status"] == "open"

      assert %{swept: 0, skipped: 0} = TtlSweeper.sweep(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "open"
    end
  end

  # ─── (7) Multi-task ───────────────────────────────────────────────────────

  describe "multi-task sweep" do
    test "3 expired + 2 fresh → swept=3, skipped=0; fresh untouched", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      phase_id = uniq("phase-multi")

      expired_tasks =
        for i <- 1..3 do
          t = mk_task!(uniq("exp-#{i}"), scope, %{"parent_id" => phase_id})
          {:ok, c} = Tasks.claim("w-exp-#{i}", scope ++ [phase_id: phase_id, dataset: @dataset])
          _ = age_claim!(c, 600)
          {t, c}
        end

      fresh_tasks =
        for i <- 1..2 do
          t = mk_task!(uniq("fresh-#{i}"), scope, %{"parent_id" => phase_id})
          {:ok, c} = Tasks.claim("w-fresh-#{i}", scope ++ [phase_id: phase_id, dataset: @dataset])
          {t, c}
        end

      assert %{swept: 3, skipped: 0} = TtlSweeper.sweep(300)

      for {task, _} <- expired_tasks do
        reloaded = Repo.get!(Document, task.id)

        assert reloaded.content["lifecycle_status"] == "open",
               "#{task.doc_id} should be open after sweep"

        assert reloaded.content["claim"]["epoch"] == 2
        assert reloaded.content["claim"]["worker"] == nil
        assert length(events_for(task.doc_id, TtlSweeper.event_kind())) == 1
      end

      for {task, claimed} <- fresh_tasks do
        reloaded = Repo.get!(Document, task.id)

        assert reloaded.content["lifecycle_status"] == "in_progress",
               "#{task.doc_id} should still be in_progress (fresh ts_iso)"

        assert reloaded.content["claim"]["worker"] == claimed.content["claim"]["worker"]
        assert events_for(task.doc_id, TtlSweeper.event_kind()) == []
      end
    end
  end
end
