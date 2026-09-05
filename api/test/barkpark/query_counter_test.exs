defmodule Barkpark.QueryCounterTest do
  @moduledoc """
  The PERMANENT leak trap for `Barkpark.QueryCounter` — the shared
  lineage-scoped counter every statement-budget test in this repo now rides.

  Two halves, and the pair is the whole point:

    * NEGATIVE — a statement issued by a process with no spawn lineage back to
      the measurement (exactly the shape of a background sweeper started by the
      application supervisor at boot) must NOT enter the census, even though it
      lands INSIDE the measured window. This reproduces DETERMINISTICALLY the
      flake that reddened main at 2c5b658d41 (`chat_messages 1` from
      `StudioChat.BlockedSweeper`, once per 60s).

    * POSITIVE — a real LiveView connected mount, which runs in a SPAWNED
      process the measurement never called, MUST be counted once `own/1` names
      it. Without this half the negative half is satisfiable by the cheap wrong
      fix (`if self() == test_pid`), which silently drops every connected leg.

  Reverting `QueryCounter` to a global counter reds the negative half; reverting
  it to a pid filter reds the positive half.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.QueryCounter

  describe "the foreign-process leak trap (permanent)" do
    test "a statement from a process outside the measurement never enters the census" do
      {_, {clean, clean_sources}} = QueryCounter.census(fn -> owned_documents_statement!() end)

      # A raw GLOBAL handler runs alongside the scoped one: it is the
      # NON-VACUITY witness. If the foreign process never actually reached the
      # database (an unshared sandbox would do that), this counts 0 and the
      # trap is proved toothless instead of quietly passing.
      {{_, {noisy, noisy_sources}}, globally_seen} =
        with_global_chat_messages_witness(fn ->
          QueryCounter.census(fn ->
            owned_documents_statement!()
            foreign_chat_messages_statement!()
          end)
        end)

      assert clean > 0,
             "the measurement counted nothing at all — this trap cannot discriminate " <>
               "(#{inspect(clean_sources)})"

      assert globally_seen >= 1,
             "the foreign process issued no chat_messages statement a global handler " <>
               "could see — this trap has gone vacuous and would pass against ANY counter"

      refute Map.has_key?(clean_sources, "chat_messages"),
             "the control block queried chat_messages — this trap's premise moved " <>
               "(#{inspect(clean_sources)})"

      refute Map.has_key?(noisy_sources, "chat_messages"),
             "a foreign process's chat_messages statement entered the census " <>
               "(#{inspect(noisy_sources)}) — the counter is global again"

      assert noisy == clean,
             "a foreign statement moved the census: #{noisy} with the foreign process " <>
               "vs #{clean} without it (#{inspect(noisy_sources)})"
    end
  end

  describe "the connected-leg positive control (permanent)" do
    test "statements issued IN the LiveView process are counted", %{conn: conn} do
      {view, events} =
        QueryCounter.capture(fn ->
          {:ok, view, _html} = live(conn, "/finder")
          QueryCounter.own(view.pid)
          view
        end)

      from_liveview = Enum.filter(events, &(&1.pid == view.pid))

      refute Enum.empty?(events),
             "the /finder mount issued no statements at all — this control is vacuous"

      refute Enum.empty?(from_liveview),
             "no statement was credited to the LiveView process #{inspect(view.pid)} " <>
               "(counted pids: #{inspect(events |> Enum.map(& &1.pid) |> Enum.uniq())}) — " <>
               "either the counter has become pid-filtered and drops every connected leg, " <>
               "or /finder's connected mount stopped issuing statements"
    end

    test "a Task's statement is counted through $callers, without naming its pid" do
      {_, {count, sources}} =
        QueryCounter.census(fn ->
          Task.async(fn -> Barkpark.Repo.aggregate(Barkpark.Content.Document, :count, :id) end)
          |> Task.await(5_000)
        end)

      assert Map.get(sources, "documents", 0) >= 1,
             "a Task-spawned statement was dropped despite $callers naming this test " <>
               "(#{count} statements, #{inspect(sources)})"
    end
  end

  # Deliberately the WRONG shape — an unscoped, node-global counter — attached
  # for the length of `fun` purely to witness that the foreign statement really
  # happened. Never a measurement; only a non-vacuity proof.
  defp with_global_chat_messages_witness(fun) do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, :witness, ref}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _e, _m, meta, _cfg ->
        if meta[:source] == "chat_messages", do: send(test_pid, {ref, :seen})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain_witness(ref, 0)}
  end

  defp drain_witness(ref, acc) do
    receive do
      {^ref, :seen} -> drain_witness(ref, acc + 1)
    after
      0 -> acc
    end
  end

  # An OWNED statement: issued by the test process itself, so it is counted by
  # any shape of counter — the denominator the foreign statement is measured
  # against.
  defp owned_documents_statement! do
    Barkpark.Repo.aggregate(Barkpark.Content.Document, :count, :id)
  end

  # A process with NO spawn lineage back to the test: plain `spawn/1` writes
  # neither `$callers` nor `$ancestors`, which is exactly the shape of a
  # sweeper started by the application supervisor at boot. It issues the same
  # `chat_messages` statement `BlockedSweeper.sweep/1` issues, INSIDE the
  # measured window, and we block until it has actually run.
  defp foreign_chat_messages_statement! do
    parent = self()
    marker = make_ref()

    spawn(fn ->
      _ = Barkpark.Repo.aggregate(Barkpark.StudioChat.Message, :count, :id)
      send(parent, {marker, :done})
    end)

    receive do
      {^marker, :done} -> :ok
    after
      5_000 -> flunk("the foreign chat_messages statement never ran")
    end
  end
end
