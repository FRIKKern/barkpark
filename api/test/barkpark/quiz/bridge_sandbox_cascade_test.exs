defmodule Barkpark.Quiz.BridgeSandboxCascadeTest do
  @moduledoc """
  THE REGRESSION for the 1,310-failure cascade (CI run 29710726459 attempt 1,
  job 88254095748), whose first Postgrex disconnect named the client exactly:

      Client #PID<0.390.0> (Barkpark.Quiz.Bridge) is still using a connection
      from owner
        lib/barkpark/quiz/content.ex  Quiz.Content.load_question/2
        lib/barkpark/quiz/bridge.ex   apply_now/3
        lib/barkpark/quiz/bridge.ex   handle_info/2  (the :document_changed clause)

  (The run's line numbers are dropped from the trace on purpose: they were
  true of that sha and rot with every edit, while the symbols do not.)

  This module does NOT `use Barkpark.DataCase`, on purpose. DataCase owns the
  sandbox lifecycle in its own `setup`/`on_exit`, and the defect under test IS
  that lifecycle boundary — the instant `stop_owner/1` runs while the Bridge is
  mid-read. To show the disconnect happening and then show the barrier
  preventing it, the owner must be started and stopped INSIDE the test body,
  where a log capture can see it. So each test starts its own shared-mode owner
  and stops it explicitly.

  Both tests drive the identical scenario and differ in exactly ONE line:
  whether `Barkpark.PubSubSingletons.drain!/1` runs before `stop_owner/1`.

  ## Why this does not sleep for the race

  A first draft slept a calibrated 15ms after the broadcast and asserted the
  disconnect. It reproduced only with a cold prepared-statement cache: run
  second in the file, the Bridge finished all its reads inside 15ms and sat in
  `{:gen_server, :loop, 5}`, so the owner stopped with nothing in flight and the
  test failed for a reason unrelated to the fix. A sleep cannot express "is
  mid-query"; it can only guess.

  `await_mid_query!/1` instead POLLS the Bridge's stacktrace until it is
  demonstrably inside Postgrex, and `flunk/1`s if it never gets there. That
  turns "the repro stopped reproducing" from a silent green into a red.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.{Content, Quiz}
  alias Ecto.Adapters.SQL.Sandbox

  # The exact string Postgrex logs when a non-owner client still holds the
  # owner's connection at stop_owner/1 — what CI recorded.
  @disconnect "is still using a connection from owner"

  # The Bridge reloads EVERY pin bound to the changed quiz, sequentially, in one
  # handle_info/2. Binding many pins makes the read loop long enough that after
  # await_mid_query!/1 observes a query in flight there are still ~100 more to
  # go, so stop_owner/1 lands squarely inside the loop rather than at its edge.
  # No rooms are created: Quiz.apply_question/2 no-ops on a dead pin
  # (room.ex:192 call_existing/3 returns its default), so a binding alone drives
  # the read this test is about.
  @pins 150

  @mid_query_timeout_ms 5_000

  setup do
    restart_bridge!()
    :ok
  end

  test "PRE-FIX SHAPE: stopping the owner with no singleton barrier disconnects mid-read" do
    log =
      capture_log(fn ->
        owner = Sandbox.start_owner!(Barkpark.Repo, shared: true)
        qid = seed_and_bind!()

        broadcast_quiz_changed(qid)
        await_mid_query!(Process.whereis(Barkpark.Quiz.Bridge))

        # NO barrier — this is main's behaviour before this task. on_exit drains
        # only the two Task supervisors, which cannot see a GenServer, so the
        # owner stops underneath the Bridge's in-flight read.
        Sandbox.stop_owner(owner)

        # Let the killed connection surface its disconnect on the logger.
        Process.sleep(300)
      end)

    assert log =~ @disconnect,
           """
           The unbarriered path did not reproduce the CI disconnect.

           A green here does NOT mean the defect is gone — it means this test
           stopped being able to observe it. Check that Quiz.Bridge still reads
           inside handle_info/2, then widen @pins.

           Captured log:
           #{log}
           """

    assert log =~ "Barkpark.Quiz.Bridge",
           "the disconnect must name the Bridge as the client still holding the connection"

    assert log =~ "apply_now",
           "the disconnect must carry the bridge.ex apply_now/3 frame from the CI stack"
  end

  test "POST-FIX: quiescing the singleton before stop_owner leaves no in-flight query" do
    log =
      capture_log(fn ->
        owner = Sandbox.start_owner!(Barkpark.Repo, shared: true)
        qid = seed_and_bind!()

        broadcast_quiz_changed(qid)
        await_mid_query!(Process.whereis(Barkpark.Quiz.Bridge))

        # THE ONE LINE THAT DIFFERS. `:sys.get_state/2` is answered only after the
        # Bridge has processed the {:document_changed, …} already in its mailbox,
        # so every read it triggered is complete before the owner goes away.
        Barkpark.PubSubSingletons.drain!()

        Sandbox.stop_owner(owner)
        Process.sleep(300)
      end)

    refute log =~ @disconnect,
           """
           The barrier did not prevent the disconnect.

           Captured log:
           #{log}
           """
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp seed_and_bind!() do
    Content.upsert_schema(
      %{
        "name" => "quiz",
        "title" => "Quiz",
        "visibility" => "public",
        "fields" => Quiz.Content.schema().fields
      },
      "production"
    )

    n = System.unique_integer([:positive])
    qid = "cascade-quiz-#{n}"

    {:ok, _} =
      Content.upsert_document(
        "quiz",
        %{"doc_id" => qid, "prompt" => "Q?", "choices" => [%{"id" => "a", "label" => "A"}]},
        "production"
      )

    {:ok, _} = Content.publish_document(qid, "quiz", "production")

    for i <- 1..@pins do
      :ok = Quiz.bind_quiz("CS#{n}#{i}", qid)
    end

    qid
  end

  # A local PubSub broadcast delivers by direct send/2 before it returns, so on
  # return the message is already in the Bridge's mailbox — measured: the queue
  # holds {:document_changed, …} immediately after broadcast/3 returns.
  defp broadcast_quiz_changed(qid) do
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      "documents:production",
      {:document_changed, %{type: "quiz", doc_id: qid}}
    )
  end

  # Block until the Bridge is provably executing a query, so the stop below is
  # mid-flight by observation rather than by hope.
  defp await_mid_query!(pid),
    do: await_mid_query!(pid, System.monotonic_time(:millisecond) + @mid_query_timeout_ms)

  defp await_mid_query!(pid, deadline) do
    cond do
      in_query?(pid) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("""
        Barkpark.Quiz.Bridge never entered a query FROM apply_now/3 within
        #{@mid_query_timeout_ms}ms.

        The repro can no longer observe the defect. Do NOT treat this as a fix:
        check that handle_info/2 still reads per bound pin through apply_now/3,
        and raise @pins. If apply_now/3 was renamed or lost its rescue clause
        (which is what keeps its frame on the stack), teach applying?/1 the new
        symbol rather than relaxing the barrier back to "any socket read" —
        that weaker barrier is what made this test flake.
        """)

      true ->
        await_mid_query!(pid, deadline)
    end
  end

  # THE BARRIER MUST PROVE THE STATE THE ASSERTIONS CLAIM, NOT A WEAKER ONE.
  #
  # This predicate used to answer true for a Postgrex/prim_inet frame ALONE.
  # That is "the Bridge is inside some socket read" — which a DBConnection
  # checkout handshake or an idle ping satisfies without `apply_now/3` being
  # anywhere on the stack. stop_owner/3 then landed on a connection-level read,
  # Postgrex logged a disconnect that named the Bridge with a stack that had no
  # `apply_now` frame, and the THIRD assertion failed while the first two
  # passed. That is exactly the recorded CI shape — four reds, all identical,
  # all `assert log =~ "apply_now"`, all green on rerun with no code change:
  #
  #   2026-08-23 15:16 · 2026-08-23 19:06 · 2026-08-24 09:53 · 2026-08-31 23:13
  #
  # (Sibling row task-1114657f292c59c8 predicted a DBConnection checkout
  # timeout under a contended shared test database. The failure bodies refute
  # it: not one names a checkout, a queue, or a timeout. The disconnect fired
  # every time — only the frame it carried was a coin flip.)
  #
  # Requiring `apply_now` here makes the precondition equal the postcondition,
  # so the stop lands inside the read the test is about. The @pins loop is
  # ~entirely apply_now, so the barrier is reached just as fast; and
  # `apply_now/3` carries a rescue/catch, so it is compiled with a try frame
  # and CANNOT be tail-call eliminated off the stack while the read runs.
  # flunk-on-timeout is unchanged: a repro that stops reproducing still reds.
  defp in_query?(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stack} ->
        socket_read?(stack) and applying?(stack)

      nil ->
        false
    end
  end

  defp socket_read?(stack) do
    Enum.any?(stack, fn
      {Postgrex.Protocol, _, _, _} -> true
      {:prim_inet, :recv0, _, _} -> true
      _ -> false
    end)
  end

  defp applying?(stack) do
    Enum.any?(stack, fn
      {Barkpark.Quiz.Bridge, name, _, _} ->
        name |> Atom.to_string() |> String.contains?("apply_now")

      _ ->
        false
    end)
  end

  # The Bridge is a boot-time singleton whose `bindings` map NOTHING in the suite
  # resets, so bindings leak across files. Restarting it keeps these two tests
  # independent of each other and of whatever ran before them.
  defp restart_bridge!() do
    case Process.whereis(Barkpark.Quiz.Bridge) do
      nil ->
        wait_for_bridge(50)

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          2_000 -> :ok
        end

        wait_for_bridge(50)
    end
  end

  defp wait_for_bridge(0), do: flunk("Barkpark.Quiz.Bridge did not come back after restart")

  defp wait_for_bridge(tries) do
    case Process.whereis(Barkpark.Quiz.Bridge) do
      nil ->
        Process.sleep(20)
        wait_for_bridge(tries - 1)

      _pid ->
        :ok
    end
  end
end
