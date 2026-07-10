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
  use ExUnit.Case, async: true

  alias BarkparkWeb.ListenController

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
end
