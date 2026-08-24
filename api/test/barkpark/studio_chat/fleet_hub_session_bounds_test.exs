defmodule Barkpark.StudioChat.FleetHubSessionBoundsTest do
  @moduledoc """
  `FleetHub.record_flip/4` caps the ring in one expression and, on the very next
  line, writes `states` and `owners` with no bound at all — one entry per session
  id, added on the first activity frame (including the line-only non-flip branch)
  and never removed. This is a singleton under `StudioChat.Supervisor`, so "never
  removed" means BEAM lifetime.

  These tests pin the bound, its derivation, and the fact that it reports itself.
  They never sleep to advance a clock: the `seen` stamps are backdated through
  `:sys.replace_state/2`, so every assertion is deterministic rather than a race
  against the scheduler.
  """
  # async: false — FleetHub subscribes the SHARED activity topic, and the horizon
  # is read from Application env (global).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.StudioChat.FleetHub
  alias Barkpark.StudioChat.Recorder

  @heartbeat_key :studio_chat_agent_heartbeat_ms

  setup do
    hub =
      start_supervised!({FleetHub, name: :"fleet_bounds_#{System.unique_integer([:positive])}"})

    prior = Application.get_env(:barkpark, @heartbeat_key)

    on_exit(fn ->
      if is_nil(prior) do
        Application.delete_env(:barkpark, @heartbeat_key)
      else
        Application.put_env(:barkpark, @heartbeat_key, prior)
      end
    end)

    %{hub: hub}
  end

  # `map_state/2` dispatches on the wave-5 ATOM vocabulary
  # (:working / :needs_you / :idle / :offline) — a string falls through its
  # catch-all to the prior, which is a NON-flip and would silently defuse every
  # assertion below.
  defp activity(sid, state, owner_ws) when is_atom(state) do
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Recorder.activity_topic(),
      {:chat_activity, sid, %{state: state, owner_workspace_id: owner_ws}}
    )
  end

  # A local broadcast delivers by a direct send/2 before it returns, so a
  # :sys.get_state issued afterwards cannot be answered until every queued frame
  # has been processed. That is the barrier — no sleeping.
  defp settled_state(hub), do: :sys.get_state(hub)

  defp backdate_seen!(hub, by_ms) do
    :sys.replace_state(hub, fn s ->
      %{s | seen: Map.new(s.seen, fn {sid, ms} -> {sid, ms - by_ms} end)}
    end)
  end

  describe "the per-session maps grow with session churn" do
    test "every distinct session id adds an entry to states, owners AND seen", %{hub: hub} do
      for i <- 1..40, do: activity("churn-#{i}", :working, "ws-1")

      s = settled_state(hub)

      assert map_size(s.states) == 40
      assert map_size(s.owners) == 40
      assert map_size(s.seen) == 40

      # The ring beside them is capped in the same expression that writes these
      # maps — which is exactly why the omission read as deliberate.
      assert length(s.ring) <= FleetHub.ring_cap()
    end

    # The non-flip branch is the worse half: `owners` is written even when no
    # wire frame is emitted and no seq is consumed, so a session that never
    # changes state still pins two map entries forever.
    test "a line-only NON-FLIP still pins an entry", %{hub: hub} do
      activity("nonflip", :working, "ws-1")
      activity("nonflip", :working, "ws-1")

      s = settled_state(hub)

      assert Map.has_key?(s.owners, "nonflip")
      assert Map.has_key?(s.seen, "nonflip")
      # One flip only — the second frame consumed no seq, and still touched state.
      assert s.seq == 1
    end
  end

  describe "the sweep bounds them" do
    test "a session silent past the horizon is dropped from ALL THREE maps", %{hub: hub} do
      Application.put_env(:barkpark, @heartbeat_key, 1_000)

      activity("gone-1", :working, "ws-1")
      activity("gone-2", :needs_you, "ws-2")
      assert map_size(settled_state(hub).states) == 2

      # Horizon is 2.5 x 1_000ms = 2_500ms. Backdate past it deterministically.
      backdate_seen!(hub, 3_000)
      send(hub, :sweep_sessions)

      s = settled_state(hub)

      assert s.states == %{}
      assert s.owners == %{}
      assert s.seen == %{}
    end

    test "a session INSIDE the horizon survives", %{hub: hub} do
      Application.put_env(:barkpark, @heartbeat_key, 1_000)

      activity("keep-me", :working, "ws-1")
      backdate_seen!(hub, 1_000)
      send(hub, :sweep_sessions)

      s = settled_state(hub)

      assert Map.get(s.states, "keep-me") == "working"
      assert Map.get(s.owners, "keep-me") == "ws-1"
    end

    # THE ONE THAT MATTERS FOR CORRECTNESS: a heartbeat is the cheapest liveness
    # proof there is. An idle-but-alive session emits heartbeats and no flips, so
    # if heartbeats did not refresh the sweep clock the bound would evict a live
    # session out from under its own heartbeats and silently drop its scope.
    test "a heartbeat refreshes the clock, so an idle-but-alive session is not swept", %{hub: hub} do
      Application.put_env(:barkpark, @heartbeat_key, 1_000)

      activity("alive", :working, "ws-1")
      backdate_seen!(hub, 3_000)

      # No flip — just the liveness tick a live session sends every heartbeat.
      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        Recorder.activity_topic(),
        {:chat_heartbeat, "alive", DateTime.utc_now()}
      )

      send(hub, :sweep_sessions)

      s = settled_state(hub)

      assert Map.get(s.owners, "alive") == "ws-1",
             "a heartbeating session must keep its heartbeat scope"

      assert Map.get(s.states, "alive") == "working"
    end

    test "a title frame also refreshes the clock", %{hub: hub} do
      Application.put_env(:barkpark, @heartbeat_key, 1_000)

      activity("titled", :working, "ws-1")
      backdate_seen!(hub, 3_000)

      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        Recorder.activity_topic(),
        {:chat_title, "titled", "a title"}
      )

      send(hub, :sweep_sessions)

      assert Map.get(settled_state(hub).owners, "titled") == "ws-1"
    end
  end

  describe "the horizon is derived from the live heartbeat interval, not hardcoded" do
    # AgentStateSweeper answers this same question with a hardcoded 150, stating
    # its arithmetic as "2.5x the 60s heartbeat". This reuses the MULTIPLE, so a
    # configured heartbeat moves the horizon with it. A copied constant would not.
    test "the reported horizon tracks the configured heartbeat", %{hub: hub} do
      handler = "fleet-bounds-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:barkpark, :studio_chat, :fleet_hub, :sessions_swept],
        fn _e, m, _meta, _ -> send(test_pid, {:swept, m}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Application.put_env(:barkpark, @heartbeat_key, 4_000)
      activity("derived", :working, "ws-1")
      backdate_seen!(hub, 30_000)
      send(hub, :sweep_sessions)
      _ = settled_state(hub)

      assert_received {:swept, %{stale_after_ms: 10_000, dropped: 1, remaining: 0}}
    end
  end

  describe "the sweep reports itself" do
    test "it logs the count, the horizon, its derivation and the consequence", %{hub: hub} do
      Application.put_env(:barkpark, @heartbeat_key, 1_000)

      activity("logged-1", :working, "ws-1")
      activity("logged-2", :working, "ws-1")
      backdate_seen!(hub, 3_000)

      # api/config/test.exs sets `config :logger, level: :warning`, which drops an
      # :info line BEFORE any handler — capture_log's own :level cannot recover
      # it. The sweep is routine hygiene, so :info is the right production level;
      # the test lowers the global threshold for the duration instead of promoting
      # the line to a warning it would spam.
      prior_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prior_level) end)

      log =
        capture_log(fn ->
          send(hub, :sweep_sessions)
          _ = settled_state(hub)
        end)

      assert log =~ "FleetHub swept 2 session(s)"
      assert log =~ "no frame of any kind"
      assert log =~ "2500ms"
      # The derivation is in the line, so a reader never has to guess where the
      # number came from.
      assert log =~ "2.5x the 1000ms heartbeat"
      # The consequence, not just the count.
      assert log =~ "loses its dedup prior"
      assert log =~ "heartbeat scope"
    end

    test "a sweep with nothing to drop is SILENT and rebuilds no state", %{hub: hub} do
      Application.put_env(:barkpark, @heartbeat_key, 60_000)

      activity("fresh", :working, "ws-1")
      before = settled_state(hub)

      log =
        capture_log(fn ->
          send(hub, :sweep_sessions)
          _ = settled_state(hub)
        end)

      refute log =~ "FleetHub swept"
      assert settled_state(hub).states == before.states
      assert settled_state(hub).owners == before.owners
    end
  end

  describe "a returning session is treated as unseen, which is the correct truth" do
    test "after a sweep the same sid flips again and its owner is re-learned", %{hub: hub} do
      Application.put_env(:barkpark, @heartbeat_key, 1_000)

      activity("returns", :working, "ws-1")
      seq_before = settled_state(hub).seq

      backdate_seen!(hub, 3_000)
      send(hub, :sweep_sessions)
      assert settled_state(hub).states == %{}

      # Same four-state as before the sweep. With the dedup prior gone this is a
      # flip again — one extra frame, and a truthful one: the rest of the system
      # had already relabelled this session offline.
      activity("returns", :working, "ws-2")

      s = settled_state(hub)

      assert s.seq == seq_before + 1
      assert Map.get(s.states, "returns") == "working"
      assert Map.get(s.owners, "returns") == "ws-2"
    end
  end
end
