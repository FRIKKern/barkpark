defmodule Barkpark.Sync.PushWorkerTest do
  @moduledoc """
  Deterministic tests for the drain-tick GenServer. The default-off gate is
  asserted at the Settings/splice-predicate level (invariant #2 — no live tree
  needed). The drain tick is driven by an injected `tick_fun` that fires exactly
  ONE `:drain_tick` (no sleeps, no real interval), proving pending api events are
  pushed in id order and the cursor reaches max id.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Sync.{PushCursor, PushWorker, Settings}

  @dataset "test"
  @halt_event [:barkpark, :sync, :push, :halt]

  describe "default-off gate (invariant #2)" do
    test "push_active? is false when push_enabled is off even with full pull creds, true when on" do
      prev = Application.get_env(:barkpark, Barkpark.Sync)
      on_exit(fn -> restore_env(prev) end)

      # Full creds + pull enabled, but push OFF → no PushWorker splice.
      Application.put_env(:barkpark, Barkpark.Sync,
        url: "http://remote",
        token: "t",
        dataset: "production",
        workspace: "gyldendal",
        enabled: true,
        push_enabled: false
      )

      refute Settings.push_active?(Settings.load())

      # Push ON → spliceable.
      Application.put_env(:barkpark, Barkpark.Sync,
        url: "http://remote",
        token: "t",
        dataset: "production",
        workspace: "gyldendal",
        enabled: true,
        push_enabled: true
      )

      assert Settings.push_active?(Settings.load())

      # Fresh install (no creds) is always off, regardless of the push flag.
      Application.put_env(:barkpark, Barkpark.Sync, push_enabled: true)
      refute Settings.push_active?(Settings.load())
    end
  end

  describe "drain tick" do
    test "bootstrap skips pre-enable history; only post-enable events push, in id order; cursor reaches max id" do
      test_pid = self()
      source = "pw-#{System.unique_integer([:positive])}"

      # Mirror prod ordering: a PRE-enable event already exists when the worker
      # boots and bootstraps the cursor to head. It must NEVER be pushed.
      pre = insert_event!("pre")
      pre_id = pre.id

      push_fun = fn _ctx, event, _base ->
        send(test_pid, {:pushed, event.id})
        {:ok, "remote-#{event.doc_id}"}
      end

      # Non-firing tick: we drive every :drain_tick explicitly (no busy loop).
      tick_fun = fn _pid, _delay -> :ok end

      settings = %Settings{
        source: source,
        dataset: @dataset,
        push_batch_size: 50,
        push_interval_ms: 60_000
      }

      {:ok, pid} =
        PushWorker.start_link(
          name: nil,
          settings: settings,
          ctx: %{source: source, dataset: @dataset},
          push_fun: push_fun,
          tick_fun: tick_fun
        )

      # Barrier: get_state returns only after handle_continue (bootstrap) ran.
      _ = :sys.get_state(pid)
      assert PushCursor.get(source, @dataset) == pre_id

      # NOW the to-be-pushed events appear (ids > pre.id).
      e1 = insert_event!("a")
      e2 = insert_event!("b")

      send(pid, :drain_tick)

      assert_receive {:pushed, id1}
      assert_receive {:pushed, id2}
      assert [id1, id2] == Enum.sort([id1, id2])
      assert [e1.id, e2.id] == Enum.sort([id1, id2])

      # Barrier: get_state returns only after the drain handler completed.
      _ = :sys.get_state(pid)
      assert PushCursor.get(source, @dataset) == max(e1.id, e2.id)

      # The pre-enable event was NEVER pushed (history skipped, no ping-pong).
      refute_received {:pushed, ^pre_id}
    end
  end

  describe "halt visibility" do
    test "a halted drain logs a warning naming the remote/reason/cursor/halt-count and emits telemetry" do
      source = "pw-halt-#{System.unique_integer([:positive])}"

      push_fun = fn _ctx, _event, _base -> {:error, :transient} end
      tick_fun = fn _pid, _delay -> :ok end

      settings = %Settings{
        source: source,
        dataset: @dataset,
        push_batch_size: 50,
        push_interval_ms: 60_000
      }

      ref = :telemetry_test.attach_event_handlers(self(), [@halt_event])

      {:ok, pid} =
        PushWorker.start_link(
          name: nil,
          settings: settings,
          ctx: %{source: source, dataset: @dataset, url: "https://remote.example/w/ws/p/proj"},
          push_fun: push_fun,
          tick_fun: tick_fun
        )

      # Barrier: bootstrap_if_absent runs on :continue, pinning the cursor to
      # whatever already exists. The to-be-pushed event must be inserted AFTER
      # this barrier (same discipline as the "drain tick" test above) or the
      # bootstrap would silently swallow it as pre-enable history.
      _ = :sys.get_state(pid)
      e = insert_event!("halts")

      log =
        capture_log(fn ->
          send(pid, :drain_tick)
          _ = :sys.get_state(pid)
          # `Logger.warning` inside the PushWorker process is async w.r.t. the
          # test process; `:sys.get_state` only proves `handle_info` RAN, not
          # that the enqueued log message reached the capture backend yet.
          # `Logger.flush/0` blocks until the Logger pipeline drains (the same
          # idiom as user_notifier_test.exs for an async-process log).
          Logger.flush()
        end)

      assert log =~ "[Sync] push drain halted"
      assert log =~ inspect(e.id)
      assert log =~ ":transient"
      assert log =~ "https://remote.example/w/ws/p/proj"
      assert log =~ "consecutive halts: 1"

      halt_event = @halt_event
      assert_receive {^halt_event, ^ref, measurements, metadata}

      assert measurements.consecutive_halts == 1
      assert is_integer(measurements.cursor)
      assert metadata.source == source
      assert metadata.dataset == @dataset
      assert metadata.url == "https://remote.example/w/ws/p/proj"
      assert metadata.event_id == e.id
      assert metadata.reason == :transient
      assert metadata.consecutive_halts == 1

      # The cursor stayed frozen at the last success (pre-existing behaviour,
      # unchanged by this task) — no success has happened yet for this source.
      assert PushCursor.get(source, @dataset) == 0
    end

    test "repeated consecutive halts do not log a warning on every tick" do
      # Cadence: logged on the 1st halt, then only when the consecutive-halt
      # count is a power of two (1, 2, 4, 8, ...) — see `log_halt?/1` in
      # push_worker.ex. Three consecutive halts on the SAME stuck event (the
      # cursor stays frozen so the same event is re-fetched every tick) must
      # log on halt #1 and halt #2, but NOT on halt #3.
      source = "pw-halt-cadence-#{System.unique_integer([:positive])}"

      push_fun = fn _ctx, _event, _base -> {:error, :transient} end
      tick_fun = fn _pid, _delay -> :ok end

      settings = %Settings{
        source: source,
        dataset: @dataset,
        push_batch_size: 50,
        push_interval_ms: 60_000
      }

      {:ok, pid} =
        PushWorker.start_link(
          name: nil,
          settings: settings,
          ctx: %{source: source, dataset: @dataset},
          push_fun: push_fun,
          tick_fun: tick_fun
        )

      # Same bootstrap barrier as above: insert AFTER the cursor bootstraps,
      # or this event is swallowed as pre-enable history and nothing halts.
      _ = :sys.get_state(pid)
      _e = insert_event!("stuck")

      log =
        capture_log(fn ->
          for _ <- 1..3 do
            send(pid, :drain_tick)
            _ = :sys.get_state(pid)
          end

          Logger.flush()
        end)

      occurrences =
        log
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "[Sync] push drain halted"))

      assert occurrences == 2
      assert log =~ "consecutive halts: 1"
      assert log =~ "consecutive halts: 2"
      refute log =~ "consecutive halts: 3"
    end
  end

  defp insert_event!(doc_id) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: @dataset,
      type: "post",
      doc_id: doc_id,
      mutation: "create",
      rev: "r-#{doc_id}",
      document: %{"_id" => doc_id, "_type" => "post", "_rev" => "r-#{doc_id}"},
      source: "api",
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp restore_env(nil), do: Application.delete_env(:barkpark, Barkpark.Sync)
  defp restore_env(prev), do: Application.put_env(:barkpark, Barkpark.Sync, prev)
end
