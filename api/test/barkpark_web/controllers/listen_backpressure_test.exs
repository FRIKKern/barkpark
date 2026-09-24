defmodule BarkparkWeb.ListenBackpressureTest do
  @moduledoc """
  Protective test for the SSE subscriber-backpressure guard (unbounded-mailbox
  scar, task-febe33ce84d39bb4).

  NAMED FAILURE MODE: `ListenController.listen_loop/5` runs in the connection
  process. On Bandit, `Plug.Conn.chunk/2` BLOCKS on a stalled/slow TCP reader;
  meanwhile `Phoenix.PubSub` keeps `send/2`-ing `{:document_changed, msg}` (each
  a full rendered document) into that SAME mailbox. With no consumer-side bound,
  a high-mutation dataset + one stalled client grows the mailbox without limit →
  heap growth → node OOM.

  These assert the guard's decision seam directly against a REAL flooded process
  mailbox (the same `send/2` shape PubSub uses) — no Bandit socket needed, so
  the test runs as a plain unit test (`ExUnit.Case`, no DB / no Phoenix boot),
  matching the seam-testing convention `listen_controller_test.exs` documents.
  """
  use ExUnit.Case, async: false

  # WHY THESE ASSERTIONS CARRY AN EXPLICIT 2_000 ms BUDGET.
  #
  # Three `assert_receive`s in this file are STARTUP-GATED: each waits on a
  # process spawned inside the same test, so the spawn, the controller's
  # `Phoenix.PubSub.subscribe/2`, the event forwarder's boot and the first
  # `chunk/2` all have to be scheduled before the message can land. ExUnit's
  # implicit 100 ms default was the only thing between that and a red under
  # fleet load, and it MEASURED as one: 1 of 12 sequential runs reddened
  # (task-c24236119b999b62).
  #
  # A TIMING BUDGET CANNOT MASK A DROPPED EVENT, because a dropped event never
  # arrives at any budget. That is not theory — it was proven on THIS file
  # during PR #15696: the fix's own `forward_event?(_msg, :shared_only) -> false`
  # arm dropped the fixture's seeded events, and the failure read "the process
  # mailbox is EMPTY" after the FULL wait rather than a late arrival. The
  # mailbox would have been just as empty at 2_000 ms. Widening buys tolerance
  # for scheduler jitter and buys NOTHING for a real drop — exactly the
  # property a timing budget should have.
  #
  # WHICH THREE, and why not the rest. The set was measured, not guessed: with
  # the implicit default forced to 1 ms, 15 of 20 runs reddened, and only at
  # the three sites budgeted below. Every other `assert_receive` here fires
  # AFTER the listener is hot, on a message already queued by the work the
  # test just did, and passed every amplified run — so none is widened. This
  # is a timing budget only: no assertion is weakened, no message pattern is
  # broadened, no production code is touched.

  # The spin helpers at the bottom of this file wait on the same wall-clock
  # budget for the same reason.
  @spin_budget_ms 2_000

  alias Barkpark.Content.CallerContext
  alias BarkparkWeb.ListenController

  defmodule BlockingChunkAdapter do
    def send_chunked(state, _status, _headers), do: {:ok, "", state}

    def chunk(%{test: test} = state, body) do
      body = IO.iodata_to_binary(body)

      cond do
        String.starts_with?(body, "event: welcome") ->
          send(test, {:chunk, :welcome, self()})
          {:ok, body, state}

        String.starts_with?(body, "event: overloaded") ->
          send(test, {:chunk, :overloaded, self()})
          {:ok, body, state}

        true ->
          send(test, {:chunk, :blocked, self()})

          receive do
            {:release_chunk, from} when from == test -> {:ok, body, state}
          end
      end
    end
  end

  test "should_shed?/2 fires strictly ABOVE the limit (a burst at the limit still streams)" do
    refute ListenController.should_shed?(0, 500)
    refute ListenController.should_shed?(499, 500)
    refute ListenController.should_shed?(500, 500)
    assert ListenController.should_shed?(501, 500)
    assert ListenController.should_shed?(1_000, 500)
  end

  test "a 1000-message flood of {:document_changed, …} trips the shed guard" do
    limit = ListenController.sse_mailbox_limit()

    # Run inside a Task so the flood lands in an ISOLATED mailbox (never the
    # ExUnit runner's), then read the guard's inputs from inside that process.
    {len, shed?, empty_shed?} =
      Task.async(fn ->
        # Empty mailbox = healthy fast reader → never shed.
        {:message_queue_len, empty} = Process.info(self(), :message_queue_len)
        empty_shed? = ListenController.should_shed?(empty, limit)

        # The exact live-broadcast message shape PubSub send/2's while chunk/2
        # is blocked on a stalled reader.
        for i <- 1..1000, do: send(self(), {:document_changed, %{event_id: i}})

        {:message_queue_len, n} = Process.info(self(), :message_queue_len)
        {n, ListenController.should_shed?(n, limit), empty_shed?}
      end)
      |> Task.await()

    refute empty_shed?, "an empty mailbox must never be shed (healthy path)"
    assert len >= 1_000, "the flood must actually back the mailbox up"

    assert shed?,
           "a backlog of #{len} over limit #{limit} must trip the shed guard — " <>
             "without it the loop drains all #{len} into the connection heap (OOM path)"
  end

  test "a blocked chunk sink keeps its mailbox bounded and terminates after overload" do
    previous = Application.get_env(:barkpark, ListenController)

    Application.put_env(:barkpark, ListenController,
      mailbox_limit: 20,
      max_heap_words: 10_000_000
    )

    on_exit(fn -> restore_controller_env(previous) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.assign(:caller_context, %CallerContext{
        principal_type: :api_token,
        is_admin: true
      })
      |> Map.put(:adapter, {BlockingChunkAdapter, %{test: self()}})

    test = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        ListenController.listen(conn, %{"dataset" => "production"})
        send(test, :listener_returned)
      end)

    # Startup-gated (see the budget note at the top of this module): an
    # explicit 2_000 ms, not the implicit 100 ms. A timing budget cannot mask
    # a dropped event — a dropped event never arrives at any budget.
    assert_receive {:chunk, :welcome, ^pid}, 2_000
    forwarder = only_forwarder_link(pid)
    forwarder_monitor = Process.monitor(forwarder)

    send(pid, {:document_changed, event(0, %{"body" => "trigger"})})
    # Startup-gated (see the budget note at the top of this module): an
    # explicit 2_000 ms, not the implicit 100 ms. A timing budget cannot mask
    # a dropped event — a dropped event never arrives at any budget.
    assert_receive {:chunk, :blocked, ^pid}, 2_000

    for id <- 1..1_000 do
      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        "documents:production",
        {:document_changed, event(id, %{"body" => "queued #{id}"})}
      )
    end

    await_bounded_overload(pid, 20)
    await_empty_mailbox(forwarder)

    {:message_queue_len, stable_queue} = Process.info(pid, :message_queue_len)
    assert stable_queue <= 21

    send(pid, {:release_chunk, self()})

    assert_receive {:chunk, :overloaded, ^pid}
    assert_receive :listener_returned
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert_receive {:DOWN, ^forwarder_monitor, :process, ^forwarder, :normal}
  end

  test "an overload signal at the low-queue race boundary terminates and cleans up" do
    previous = Application.get_env(:barkpark, ListenController)

    Application.put_env(:barkpark, ListenController,
      mailbox_limit: 20,
      max_heap_words: 10_000_000
    )

    on_exit(fn -> restore_controller_env(previous) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.assign(:caller_context, %CallerContext{
        principal_type: :api_token,
        is_admin: true
      })
      |> Map.put(:adapter, {BlockingChunkAdapter, %{test: self()}})

    {pid, monitor} =
      spawn_monitor(fn -> ListenController.listen(conn, %{"dataset" => "production"}) end)

    # Startup-gated (see the budget note at the top of this module): an
    # explicit 2_000 ms, not the implicit 100 ms. A timing budget cannot mask
    # a dropped event — a dropped event never arrives at any budget.
    assert_receive {:chunk, :welcome, ^pid}, 2_000
    forwarder = only_forwarder_link(pid)
    forwarder_monitor = Process.monitor(forwarder)

    send(pid, :sse_overloaded)

    assert_receive {:chunk, :overloaded, ^pid}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert_receive {:DOWN, ^forwarder_monitor, :process, ^forwarder, :normal}
  end

  test "backpressure_step continues on an empty mailbox and does NOT emit the overloaded frame" do
    {tag, emitted?} =
      Task.async(fn ->
        # A conn placeholder is only touched on the shed branch; :cont returns it
        # untouched, so a bare map is a safe stand-in for the healthy path here.
        {tag, conn} = ListenController.backpressure_step(%{sentinel: :conn}, 500)
        {tag, match?(%{resp_body: _}, conn)}
      end)
      |> Task.await()

    assert tag == :cont
    refute emitted?, "healthy path must not touch the response"
  end

  test "overloaded_frame is a well-formed SSE frame naming the backpressure close" do
    frame = ListenController.overloaded_frame()

    assert frame =~ "event: overloaded\n"
    assert frame =~ ~s("reason":"slow_consumer")
    # SSE frames terminate on a blank line.
    assert String.ends_with?(frame, "\n\n")
  end

  # A DEADLINE, NOT AN ATTEMPT COUNT. `attempts \\ 10_000` was the wrong unit:
  # 10_000 `:erlang.yield()`s is however long the scheduler feels like taking,
  # so the same loop is generous on an idle box and a flake on a loaded one.
  # The safety argument is the one stated at the top of this module — a timing
  # budget cannot mask a dropped event, because a dropped event never arrives
  # at any budget. These flunk on exactly the SAME condition as before; they
  # simply wait a stated wall-clock span instead of an unstated scheduling one.
  # The deadline is checked AFTER the success clause, so a condition that is
  # already satisfied can never be flunked by an expired budget.
  defp deadline_from_now, do: System.monotonic_time(:millisecond) + @spin_budget_ms

  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp await_bounded_overload(pid, limit),
    do: await_bounded_overload(pid, limit, deadline_from_now())

  defp await_bounded_overload(pid, limit, deadline) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} when n > limit ->
        n

      {:message_queue_len, _n} ->
        if expired?(deadline) do
          flunk(
            "event forwarder never filled the bounded listener window " <>
              "within #{@spin_budget_ms}ms"
          )
        end

        :erlang.yield()
        await_bounded_overload(pid, limit, deadline)

      nil ->
        flunk("listener terminated before the blocked chunk was released")
    end
  end

  defp await_empty_mailbox(pid), do: await_empty_mailbox(pid, deadline_from_now())

  defp await_empty_mailbox(pid, deadline) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, 0} ->
        :ok

      {:message_queue_len, _n} ->
        if expired?(deadline) do
          flunk("event forwarder mailbox did not drain within #{@spin_budget_ms}ms")
        end

        :erlang.yield()
        await_empty_mailbox(pid, deadline)

      nil ->
        flunk("event forwarder terminated before the stable queue observation")
    end
  end

  defp only_forwarder_link(pid) do
    {:links, links} = Process.info(pid, :links)
    assert length(links) == 1
    hd(links)
  end

  # A SHARED-LAYER event: `workspace_id: nil`, the value `tap_broadcast/5`
  # stamps for a write that resolved no workspace. Stated EXPLICITLY, not
  # omitted, because this fixture's conn carries no `:current_workspace` assign,
  # so `ScopeHelpers.scope_opts/1` hands the listener the empty-scope sentinel
  # `:shared_only` — and `forward_event?/2`'s `:shared_only` arm forwards a
  # shared-layer event (`workspace_id` NULL) while DROPPING a msg that carries
  # no `workspace_id` key at all (the defensive arm). Omitting the key used to
  # work only because the old nil scope forwarded everything, including every
  # other tenant's events — the cross-tenant leak this fixture must not depend
  # on. This test's subject is BACKPRESSURE on a blocked sink; it needs its
  # events forwarded, not the tenancy fence relaxed to forward them.
  defp event(id, document) do
    %{
      event_id: id,
      workspace_id: nil,
      mutation: "update",
      type: "post",
      doc_id: "drafts.backpressure-#{id}",
      rev: "rev-#{id}",
      previous_rev: "rev-#{id - 1}",
      document: document
    }
  end

  defp restore_controller_env(nil), do: Application.delete_env(:barkpark, ListenController)
  defp restore_controller_env(value), do: Application.put_env(:barkpark, ListenController, value)
end
