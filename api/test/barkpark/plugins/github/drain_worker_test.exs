defmodule Barkpark.Plugins.Github.DrainWorkerTest do
  @moduledoc """
  Deterministic tests for the outbound-mirror drain-tick GenServer. Every seam is
  injected (no Oban, no network, no sleeps): `enqueue_fun` records to the test
  pid, `tick_fun` records the scheduled delay (or no-ops so we drive `:drain_tick`
  ourselves), and `datasets_fun`/`active_fun` are pure fakes. Events are inserted
  straight into `mutation_events` so the test controls `id`/`source`/`type`.

  The capstone proves the mirror is loop-immune BY CONSTRUCTION at the drain
  level: a bookkeeping write stamped `source="github"` (what
  `Github.Link.put(source: :github)` emits) is EXCLUDED by `Outbox.fetch/3`, so a
  re-drain enqueues ZERO jobs (loop-cut #2, epic D4/D12). The full
  Content→Link.put→MirrorJob→Bypass e2e lives with slices 1/3 (those modules are
  not present in this worktree); here we prove the engine's own convergence.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.{Cursor, DrainWorker}
  alias Barkpark.Repo

  # A tick_fun that never fires a real :drain_tick — we drive ticks by hand.
  defp silent_tick, do: fn _pid, _delay -> :ok end

  # A tick_fun that reports every scheduled delay back to the test.
  defp reporting_tick(test_pid), do: fn _pid, delay -> send(test_pid, {:scheduled, delay}) end

  # Enqueue fake: records each attempt; :ok unless the doc_id says otherwise.
  defp ok_enqueue(test_pid) do
    fn %{doc_id: doc_id, dataset: ds} ->
      send(test_pid, {:enqueued, doc_id, ds})
      :ok
    end
  end

  defp new_dataset, do: "ds-#{System.unique_integer([:positive])}"

  defp insert_event!(dataset, doc_id, source \\ "api", type \\ "task") do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: dataset,
      type: type,
      doc_id: doc_id,
      mutation: "create",
      rev: "r-#{doc_id}",
      document: %{"_id" => doc_id, "_type" => type},
      source: source,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  # Boot a worker with the given seams and wait past handle_continue (bootstrap).
  defp boot!(opts) do
    {:ok, pid} = DrainWorker.start_link(Keyword.put(opts, :name, nil))
    _ = :sys.get_state(pid)
    pid
  end

  describe "backoff_ms/1 (pure)" do
    test "exponential from a 1 s floor, capped at 30 s" do
      assert DrainWorker.backoff_ms(0) == 1_000
      assert DrainWorker.backoff_ms(1) == 2_000
      assert DrainWorker.backoff_ms(2) == 4_000
      # Capped — a large attempt never exceeds the ceiling.
      assert DrainWorker.backoff_ms(100) == 30_000
    end
  end

  describe "handle_continue bootstrap (D1 — skip pre-enable backlog)" do
    test "seeds every whitelisted dataset's cursor to head at boot" do
      ds_a = new_dataset()
      ds_b = new_dataset()

      # Pre-enable history in each dataset. Bootstrap must seed the cursor to
      # these heads so they are NEVER mirrored.
      pre_a = insert_event!(ds_a, "pre-a")
      pre_b1 = insert_event!(ds_b, "pre-b1")
      pre_b2 = insert_event!(ds_b, "pre-b2")

      boot!(
        datasets_fun: fn -> [ds_a, ds_b] end,
        active_fun: fn -> true end,
        enqueue_fun: ok_enqueue(self()),
        tick_fun: silent_tick()
      )

      assert Cursor.get(ds_a) == pre_a.id
      assert Cursor.get(ds_b) == max(pre_b1.id, pre_b2.id)
    end
  end

  describe "drain tick — enqueue per event + write-then-advance" do
    test "enqueues each post-enable task event and advances the cursor to max id" do
      ds = new_dataset()
      test_pid = self()

      pid =
        boot!(
          datasets_fun: fn -> [ds] end,
          active_fun: fn -> true end,
          enqueue_fun: ok_enqueue(test_pid),
          tick_fun: reporting_tick(test_pid)
        )

      # Bootstrap seeded the (empty) cursor to 0; these are the events to mirror.
      e1 = insert_event!(ds, "task-1")
      e2 = insert_event!(ds, "task-2")

      send(pid, :drain_tick)

      assert_receive {:enqueued, "task-1", ^ds}
      assert_receive {:enqueued, "task-2", ^ds}

      _ = :sys.get_state(pid)
      assert Cursor.get(ds) == max(e1.id, e2.id)

      # A clean drain reschedules at the idle interval (not a backoff).
      assert_receive {:scheduled, 15_000}
    end

    test "excludes source=github and non-task rows from the drain window" do
      ds = new_dataset()
      test_pid = self()

      pid =
        boot!(
          datasets_fun: fn -> [ds] end,
          active_fun: fn -> true end,
          enqueue_fun: ok_enqueue(test_pid),
          tick_fun: silent_tick()
        )

      keep = insert_event!(ds, "keep")
      _github = insert_event!(ds, "intaken", "github")
      _post = insert_event!(ds, "a-post", "api", "post")

      send(pid, :drain_tick)

      assert_receive {:enqueued, "keep", ^ds}
      refute_receive {:enqueued, "intaken", _}
      refute_receive {:enqueued, "a-post", _}

      _ = :sys.get_state(pid)
      assert Cursor.get(ds) == keep.id
    end
  end

  describe "drain tick — HALT-no-advance on enqueue failure (D1)" do
    test "stops at the failing event; cursor parks at the last enqueued id" do
      ds = new_dataset()
      test_pid = self()

      # e2 fails; e3 must never be attempted and the cursor must not pass e1.
      failing_enqueue = fn %{doc_id: doc_id, dataset: dataset} ->
        send(test_pid, {:enqueued, doc_id, dataset})
        if doc_id == "fail", do: {:error, :boom}, else: :ok
      end

      pid =
        boot!(
          datasets_fun: fn -> [ds] end,
          active_fun: fn -> true end,
          enqueue_fun: failing_enqueue,
          tick_fun: reporting_tick(test_pid)
        )

      e1 = insert_event!(ds, "ok-first")
      _e2 = insert_event!(ds, "fail")
      _e3 = insert_event!(ds, "ok-third")

      send(pid, :drain_tick)

      assert_receive {:enqueued, "ok-first", ^ds}
      assert_receive {:enqueued, "fail", ^ds}
      # The event AFTER the failure is never enqueued (halt, not skip).
      refute_receive {:enqueued, "ok-third", _}

      _ = :sys.get_state(pid)
      # Cursor advanced ONLY to the last successfully-enqueued event.
      assert Cursor.get(ds) == e1.id

      # A halted batch reschedules on a backoff (attempt 0 → 1 s), not the idle.
      assert_receive {:scheduled, 1_000}
    end

    test "a first-event failure leaves the cursor exactly where it was" do
      ds = new_dataset()
      test_pid = self()

      always_fail = fn %{doc_id: doc_id, dataset: dataset} ->
        send(test_pid, {:enqueued, doc_id, dataset})
        {:error, :boom}
      end

      pid =
        boot!(
          datasets_fun: fn -> [ds] end,
          active_fun: fn -> true end,
          enqueue_fun: always_fail,
          tick_fun: silent_tick()
        )

      _e1 = insert_event!(ds, "first")
      before = Cursor.get(ds)

      send(pid, :drain_tick)

      assert_receive {:enqueued, "first", ^ds}
      _ = :sys.get_state(pid)
      # Monotonic no-op: the cursor never advanced past the un-enqueued event.
      assert Cursor.get(ds) == before
    end
  end

  describe "idle gate (default-off preserved)" do
    test "does zero work and reschedules idle when Settings.active? is false" do
      ds = new_dataset()
      test_pid = self()

      pid =
        boot!(
          datasets_fun: fn -> [ds] end,
          active_fun: fn -> false end,
          enqueue_fun: ok_enqueue(test_pid),
          tick_fun: reporting_tick(test_pid)
        )

      # An event is waiting, but a dark plugin must not touch it.
      _e = insert_event!(ds, "waiting")
      before = Cursor.get(ds)

      send(pid, :drain_tick)
      _ = :sys.get_state(pid)

      refute_receive {:enqueued, _, _}
      assert Cursor.get(ds) == before
      # Rescheduled at the idle interval, ready to wake when creds land.
      assert_receive {:scheduled, 15_000}
    end
  end

  describe "dark→active enable (D1 — skip dark-window backlog)" do
    test "the first active tick seeds the cursor to head; the dark backlog never mirrors" do
      ds = new_dataset()
      test_pid = self()
      {:ok, active} = Agent.start_link(fn -> false end)
      on_exit(fn -> if Process.alive?(active), do: Agent.stop(active) end)

      # Boots DARK (whitelisted but uncredentialed): handle_continue must NOT seed
      # a cursor while inactive.
      pid =
        boot!(
          datasets_fun: fn -> [ds] end,
          active_fun: fn -> Agent.get(active, & &1) end,
          enqueue_fun: ok_enqueue(test_pid),
          tick_fun: silent_tick()
        )

      # Task events pile up while the operator provisions the GitHub App (dark).
      _d1 = insert_event!(ds, "dark-1")
      d2 = insert_event!(ds, "dark-2")

      # Creds land — the plugin goes active. The FIRST active tick bootstraps the
      # cursor to head-at-activation, so the entire dark backlog is skipped (D1),
      # NOT flooded to GitHub.
      Agent.update(active, fn _ -> true end)
      send(pid, :drain_tick)
      _ = :sys.get_state(pid)

      refute_receive {:enqueued, _, _}
      assert Cursor.get(ds) == d2.id

      # A task mutated AFTER enable does mirror (proves the cursor isn't stuck).
      d3 = insert_event!(ds, "post-enable")
      send(pid, :drain_tick)
      assert_receive {:enqueued, "post-enable", ^ds}
      _ = :sys.get_state(pid)
      assert Cursor.get(ds) == d3.id
    end
  end

  describe "capstone — loop-immune by construction (D4/D12)" do
    test "a github-stamped bookkeeping write is never re-enqueued on re-drain" do
      ds = new_dataset()
      test_pid = self()

      pid =
        boot!(
          datasets_fun: fn -> [ds] end,
          active_fun: fn -> true end,
          enqueue_fun: ok_enqueue(test_pid),
          tick_fun: silent_tick()
        )

      # 1) A task mutates → the drain enqueues exactly one MirrorJob, cursor advances.
      task = insert_event!(ds, "task-loop", "api")

      send(pid, :drain_tick)
      assert_receive {:enqueued, "task-loop", ^ds}
      _ = :sys.get_state(pid)
      assert Cursor.get(ds) == task.id

      # 2) The mirror completes and stamps content.github via Link.put(source:
      #    :github). That write lands in mutation_events stamped source="github"
      #    (id > the task event). Simulated directly — it is exactly the row
      #    Link.put emits (see link.ex + outbox_test).
      stamp = insert_event!(ds, "task-loop", "github")
      assert stamp.id > task.id

      # 3) Re-drain: Outbox.fetch EXCLUDES the source="github" row, so zero new
      #    events → zero MirrorJobs re-enqueue. The loop is broken structurally.
      send(pid, :drain_tick)
      _ = :sys.get_state(pid)

      refute_receive {:enqueued, _, _}
      # Cursor unmoved (nothing to advance past — the stamp is invisible to the
      # outbound reader), so the mirror has reached a fixed point.
      assert Cursor.get(ds) == task.id
    end
  end
end
