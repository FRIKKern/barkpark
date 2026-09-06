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
      # A TTL reap releases the LEASE, not the ASSIGNMENT: content.assignee
      # survives so the board keeps showing who owns the task while the
      # (slow / crashed) worker is off it. Only claim.worker is cleared.
      assert reloaded.content["assignee"] == "worker-A"
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

      original_ttl = Application.get_env(:barkpark, :task_lease_ttl_seconds)
      Application.put_env(:barkpark, :task_lease_ttl_seconds, 1)
      on_exit(fn -> Application.put_env(:barkpark, :task_lease_ttl_seconds, original_ttl) end)

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
          assert match?(
                   {:error, reason} when reason in [:fenced_off, :stale_claim],
                   hd(close_results)
                 ),
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
          lifecycle_status: "cancelled",
          # A cancel needs a reason (task-650d7844d8fe7199) — every other close
          # gate exempts `cancelled` by name, so the reason is its whole record.
          reason: "cancelled by the sweeper fixture — a terminal row must not be swept"
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

  # ─── (8) Engagement honesty sweep (tlv-s6, charter D4) ────────────────────
  #
  # The SECOND sweep in the same worker: lapse THOUGHT states whose
  # engagement.ts went stale. researching → considering (engagement cleared);
  # considering → engagement cleared, stays considering. No epoch machinery —
  # the sweep never touches a claim map. Emits task.engagement_lapsed
  # (lease_expired payload shape MINUS the epoch fields).

  defp iso_ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

  # Force a task's engagement.ts `seconds_ago` seconds into the past — the
  # engagement-sweep twin of age_claim!/2, so a stage written through the real
  # verb can be swept without sleeping.
  defp age_engagement!(doc, seconds_ago) do
    import Ecto.Query

    new_engagement = Map.put(doc.content["engagement"], "ts", iso_ago(seconds_ago))
    new_content = Map.put(doc.content, "engagement", new_engagement)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id)
      |> Repo.update_all(set: [content: new_content])

    Repo.get!(Document, doc.id)
  end

  defp mk_thought_task!(doc_id, scope, status, engagement) do
    extra =
      case engagement do
        nil -> %{"lifecycle_status" => status}
        %{} = e -> %{"lifecycle_status" => status, "engagement" => e}
      end

    mk_task!(doc_id, scope, extra)
  end

  describe "sweep_engagement/1" do
    test "researching with stale engagement.ts → considering, engagement cleared, event emitted",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      engagement = %{
        "object" => "research",
        "holder" => "cycle-w1",
        "ts" => iso_ago(600),
        "note" => "surveying the queue seam"
      }

      task = mk_thought_task!(uniq("eng-res"), scope, "researching", engagement)

      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep_engagement(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "considering"
      refute Map.has_key?(reloaded.content, "engagement")
      # NO epoch machinery: the sweep never grows a claim map on the row.
      refute Map.has_key?(reloaded.content, "claim")

      events = events_for(task.doc_id, TtlSweeper.engagement_event_kind())
      assert length(events) == 1
      [ev] = events
      payload = ev.document["engagement_lapsed"]
      assert payload["previous_rev"] == task.rev
      assert payload["rev"] == reloaded.rev
      assert payload["previous_holder"] == "cycle-w1"
      assert payload["from_status"] == "researching"
      assert payload["to_status"] == "considering"
      assert payload["engagement"] == engagement
      # The lease_expired epoch fields are ABSENT — thought carries no fence.
      refute Map.has_key?(payload, "expired_epoch")
      refute Map.has_key?(payload, "new_epoch")
      assert ev.workspace_id == task.workspace_id
    end

    test "considering with stale engagement → engagement cleared, STAYS considering",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      engagement = %{"object" => "build", "holder" => "cycle-w2", "ts" => iso_ago(600)}
      task = mk_thought_task!(uniq("eng-con"), scope, "considering", engagement)

      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep_engagement(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "considering"
      refute Map.has_key?(reloaded.content, "engagement")

      [ev] = events_for(task.doc_id, TtlSweeper.engagement_event_kind())
      payload = ev.document["engagement_lapsed"]
      assert payload["from_status"] == "considering"
      assert payload["to_status"] == "considering"
      assert payload["previous_holder"] == "cycle-w2"
    end

    test "TTL boundary: fresh engagement survives, stale lapses — same sweep",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      fresh_engagement = %{"object" => "research", "holder" => "h-fresh", "ts" => iso_ago(200)}
      stale_engagement = %{"object" => "research", "holder" => "h-stale", "ts" => iso_ago(400)}

      fresh = mk_thought_task!(uniq("eng-fresh"), scope, "researching", fresh_engagement)
      stale = mk_thought_task!(uniq("eng-stale"), scope, "researching", stale_engagement)

      # ttl=300 → the 200 s-old engagement is inside the lease, 400 s is past.
      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep_engagement(300)

      fresh_reloaded = Repo.get!(Document, fresh.id)
      assert fresh_reloaded.content["lifecycle_status"] == "researching"
      assert fresh_reloaded.content["engagement"] == fresh_engagement
      assert events_for(fresh.doc_id, TtlSweeper.engagement_event_kind()) == []

      stale_reloaded = Repo.get!(Document, stale.id)
      assert stale_reloaded.content["lifecycle_status"] == "considering"
      refute Map.has_key?(stale_reloaded.content, "engagement")
      assert length(events_for(stale.doc_id, TtlSweeper.engagement_event_kind())) == 1
    end

    test "considering WITHOUT an engagement map is the resting state — never a candidate",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_thought_task!(uniq("eng-rest"), scope, "considering", nil)

      assert %{swept: 0, skipped: 0} = TtlSweeper.sweep_engagement(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "considering"
      assert events_for(task.doc_id, TtlSweeper.engagement_event_kind()) == []
    end

    test "researching WITHOUT an engagement map is malformed and lapses to considering",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task = mk_thought_task!(uniq("eng-bare"), scope, "researching", nil)

      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep_engagement(300)

      reloaded = Repo.get!(Document, task.id)
      assert reloaded.content["lifecycle_status"] == "considering"

      [ev] = events_for(task.doc_id, TtlSweeper.engagement_event_kind())
      payload = ev.document["engagement_lapsed"]
      assert payload["previous_holder"] == nil
      assert payload["engagement"] == nil
    end

    test "lapse is idempotent: a second sweep finds nothing to lapse", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      engagement = %{"object" => "research", "holder" => "h-once", "ts" => iso_ago(600)}
      task = mk_thought_task!(uniq("eng-idem"), scope, "researching", engagement)

      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep_engagement(300)
      # The row is now considering WITHOUT engagement — the resting state, not
      # a candidate. No second event, ever.
      assert %{swept: 0, skipped: 0} = TtlSweeper.sweep_engagement(300)

      assert length(events_for(task.doc_id, TtlSweeper.engagement_event_kind())) == 1
    end

    test "non-thought lifecycles are never touched, stale engagement or not",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      stale = %{"object" => "research", "holder" => "h-x", "ts" => iso_ago(999_999)}

      open_task = mk_task!(uniq("eng-open"), scope, %{"engagement" => stale})

      done_task =
        mk_task!(uniq("eng-done"), scope, %{
          "lifecycle_status" => "done",
          "engagement" => stale
        })

      assert %{swept: 0, skipped: 0} = TtlSweeper.sweep_engagement(300)

      for {task, status} <- [{open_task, "open"}, {done_task, "done"}] do
        reloaded = Repo.get!(Document, task.id)
        assert reloaded.content["lifecycle_status"] == status
        assert reloaded.content["engagement"] == stale
        assert events_for(task.doc_id, TtlSweeper.engagement_event_kind()) == []
      end
    end

    # ─── The durable/ephemeral split (PDS wave 23) ──────────────────────────
    #
    # The lapse releases the LEASE. It must not eat the ADJUDICATION. Measured
    # on guerrilla before the split: a row staged at 20:02:00.455593 lost its
    # engagement.note at 20:17:01.430503 (15m00.97 s) while the lifecycle flip
    # survived — `bp task stage --note` returning ok:true on a field with a
    # 15-minute half-life. These two reds are the guard.
    test "a reason written through the stage verb SURVIVES the lapse that clears its lease",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      reason = "parked: waiting on the crown proof — reopen when pds-w20-crown-fire closes"
      task = mk_task!(uniq("eng-durable"), scope)

      {:ok, staged} =
        Tasks.stage(task.id, "considering",
          object: "research",
          holder: "cycle-w23",
          note: reason
        )

      # The reason is NOT on the lease the sweeper deletes…
      refute Map.has_key?(staged.content["engagement"], "note")
      assert staged.content["disposition_reason"] == reason

      # …so a sweep past the TTL takes the lease and leaves the reason.
      staged = age_engagement!(staged, 600)
      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep_engagement(300)

      reloaded = Repo.get!(Document, staged.id)
      refute Map.has_key?(reloaded.content, "engagement")
      assert reloaded.content["lifecycle_status"] == "considering"

      assert reloaded.content["disposition_reason"] == reason,
             "the lapse ate the durable adjudication reason — a park that reports " <>
               "success and then forgets why is exactly the lie this epic closes"

      # And the lapse is honest about what it took: the event carries the lease.
      [ev] = events_for(staged.doc_id, TtlSweeper.engagement_event_kind())
      assert ev.document["engagement_lapsed"]["engagement"]["object"] == "research"
      assert ev.document["content"]["disposition_reason"] == reason
    end

    test "a LEGACY engagement.note is promoted to disposition_reason on the way out",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # A row written BEFORE the split: the reason still rides the lease.
      engagement = %{
        "object" => "research",
        "holder" => "cycle-old",
        "ts" => iso_ago(600),
        "note" => "parked in wave 22: blocked on the status read-path"
      }

      task = mk_thought_task!(uniq("eng-legacy"), scope, "considering", engagement)

      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep_engagement(300)

      reloaded = Repo.get!(Document, task.id)
      refute Map.has_key?(reloaded.content, "engagement")

      assert reloaded.content["disposition_reason"] ==
               "parked in wave 22: blocked on the status read-path"
    end

    test "promotion never overwrites a reason already adjudicated", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      task =
        mk_task!(uniq("eng-nooverwrite"), scope, %{
          "lifecycle_status" => "considering",
          "disposition_reason" => "the adjudicated reason",
          "engagement" => %{
            "object" => "research",
            "holder" => "cycle-old",
            "ts" => iso_ago(600),
            "note" => "a stale lease leftover"
          }
        })

      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep_engagement(300)

      assert Repo.get!(Document, task.id).content["disposition_reason"] ==
               "the adjudicated reason"
    end

    test "perform/1 runs BOTH sweeps: lease reap + engagement lapse in one job",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # A stale claim for the lease sweep…
      phase_id = uniq("phase-both")
      _lease_task = mk_task!(uniq("both-lease"), scope, %{"parent_id" => phase_id})
      {:ok, claimed} = Tasks.claim("worker-B", scope ++ [phase_id: phase_id, dataset: @dataset])
      _ = age_claim!(claimed, 600)

      # …and a stale engagement for the second sweep.
      thought =
        mk_thought_task!(uniq("both-thought"), scope, "researching", %{
          "object" => "research",
          "holder" => "cycle-b",
          "ts" => iso_ago(600)
        })

      for {key, original} <- [
            {:task_lease_ttl_seconds, Application.get_env(:barkpark, :task_lease_ttl_seconds)},
            {:task_engagement_ttl_seconds,
             Application.get_env(:barkpark, :task_engagement_ttl_seconds)}
          ] do
        Application.put_env(:barkpark, key, 1)
        on_exit(fn -> Application.put_env(:barkpark, key, original) end)
      end

      assert {:ok, %{swept: 1, skipped: 0, engagement: %{swept: 1, skipped: 0}}} =
               TtlSweeper.perform(%Oban.Job{})

      assert Repo.get!(Document, claimed.id).content["lifecycle_status"] == "open"
      assert Repo.get!(Document, thought.id).content["lifecycle_status"] == "considering"
    end
  end
end
