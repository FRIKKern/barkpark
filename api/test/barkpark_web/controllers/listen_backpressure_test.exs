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

    assert_receive {:chunk, :welcome, ^pid}
    forwarder = only_forwarder_link(pid)
    forwarder_monitor = Process.monitor(forwarder)

    send(pid, {:document_changed, event(0, %{"body" => "trigger"})})
    assert_receive {:chunk, :blocked, ^pid}

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

    assert_receive {:chunk, :welcome, ^pid}
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

  defp await_bounded_overload(pid, limit, attempts \\ 10_000)

  defp await_bounded_overload(_pid, _limit, 0),
    do: flunk("event forwarder never filled the bounded listener window")

  defp await_bounded_overload(pid, limit, attempts) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} when n > limit ->
        n

      {:message_queue_len, _n} ->
        :erlang.yield()
        await_bounded_overload(pid, limit, attempts - 1)

      nil ->
        flunk("listener terminated before the blocked chunk was released")
    end
  end

  defp await_empty_mailbox(pid, attempts \\ 10_000)

  defp await_empty_mailbox(_pid, 0),
    do: flunk("event forwarder mailbox did not drain")

  defp await_empty_mailbox(pid, attempts) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, 0} ->
        :ok

      {:message_queue_len, _n} ->
        :erlang.yield()
        await_empty_mailbox(pid, attempts - 1)

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
