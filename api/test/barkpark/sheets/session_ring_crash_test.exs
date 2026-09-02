defmodule Barkpark.Plugins.Sheets.SessionRingCrashTest do
  @moduledoc """
  A crash of the `ReplayRing` GenServer ALONE must not void exactly-once.

  The ring is a separate process from the sessions BY DESIGN — that is what
  lets a cached reply outlive a session that died twice (the 503 path). The
  same separation is a hole in the other direction: the ring owns the
  `:sheets_ops_replay` ETS table, so if only the RING crashes, the table dies
  with its owner while every session keeps running. The supervisor restarts the
  ring, `init/1` builds a FRESH EMPTY table, and the next retry of a
  `request_id` that was already applied reads `:miss` and applies a
  non-idempotent `insert_rows` a second time. `safe_lookup/1`'s
  `rescue ArgumentError -> []` made even the window between the crash and the
  restart look like an ordinary miss: no log line, no error, a silently lost
  guarantee.

  These tests pin the fix from the outside — a REAL kill of the real
  supervised process, not a mock:

    * the table is created with the Sheets supervisor as its ETS `heir`, so it
      is handed to a longer-lived process at the instant its owner dies and the
      restarted ring ADOPTS it instead of replacing it;
    * if the table is nonetheless gone, `lookup/2` returns `:unavailable`
      (logged at `:error`, naming the key) and the session REFUSES the batch
      with `{:error, :replay_unavailable}` rather than re-applying it.

  `async: false`: these tests kill a globally registered singleton and, in one
  case, delete a public named table that every Sheets session reads. ExUnit
  runs sync modules serially and after the async ones, so no other test is in
  flight. Each test that disturbs the ring restores it before returning, and
  the kills are budgeted — the Sheets supervisor tolerates 3 restarts in 5s and
  this module spends at most 2.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Plugins.Sheets.Session.ReplayRing

  @dataset "sheets_ring_crash_test"
  @table :sheets_ops_replay
  @sheets_sup Barkpark.Plugins.Sheets.Supervisor

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      ensure_ring!()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    # The 60s debounce keeps the first apply UNPERSISTED, so nothing but the
    # ring can explain a second application not happening.
    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    :ok
  end

  # ── (1) THE ROW'S CASE: the ring dies alone, between two identical ids ─────

  test "a ring crash between two apply_ops calls carrying the same request_id does not re-apply" do
    slug = uniq("ring-crash")
    create_sheet(slug, %{"A3" => %{"v" => "x"}})
    rid = "rid-" <> slug

    {:ok, reply1} = Session.apply_ops(slug, @dataset, [insert_two_rows()], rid)
    assert reply1.applied == 1

    # One application shifted A3 -> A5. A second would land it on A7.
    assert Map.has_key?(cells(slug), "A5")
    refute Map.has_key?(cells(slug), "A7")

    session_pid = Session.whereis(slug, @dataset)
    assert is_pid(session_pid)

    sup = Process.whereis(@sheets_sup)
    old_ring = Process.whereis(ReplayRing)
    old_tid = :ets.whereis(@table)

    # The heir transfer makes the supervisor log one "unexpected message"
    # error report; captured so it does not read as a test failure.
    {new_ring, _log} = with_log(fn -> restart_ring!() end)

    # The ring died ALONE — the session process is untouched and still holds
    # the applied state. This is the shape the filing names.
    assert Process.alive?(session_pid)
    assert Session.whereis(slug, @dataset) == session_pid
    refute new_ring == old_ring
    assert Process.alive?(sup)

    # THE LOAD-BEARING ASSERTION, stated before any mechanism check so a
    # regression reads as the behaviour it is: the same request_id, re-sent
    # across a ring crash, must not shift the cell a second time.
    {:ok, reply2} = Session.apply_ops(slug, @dataset, [insert_two_rows()], rid)

    refute Map.has_key?(cells(slug), "A7"),
           "the retried insert_rows applied a SECOND time across the ring crash " <>
             "(A3 -> A5 -> A7): exactly-once lapsed with no error and no log"

    assert Map.has_key?(cells(slug), "A5")
    assert Map.get(reply2, :replayed) == true
    assert reply2 == Map.put(reply1, :replayed, true)

    # ...and the mechanism that bought it: the table outlived its owner and is
    # the SAME table, not a fresh empty one. ETS hands a table to its heir at
    # the instant the owner dies.
    assert :ets.whereis(@table) == old_tid
    assert :ets.info(@table, :owner) == sup

    assert match?({:ok, _}, ReplayRing.lookup(ring_key(slug), rid)),
           "the cached reply for #{rid} did not survive the ring crash"
  end

  # ── (2) THE BACKSTOP: no table at all -> refuse, loudly, instead of re-apply ─

  test "with the table truly gone the session refuses the retry and the ring logs at :error" do
    slug = uniq("ring-gone")
    create_sheet(slug, %{"A3" => %{"v" => "x"}})
    rid = "rid-" <> slug

    {:ok, _reply1} = Session.apply_ops(slug, @dataset, [insert_two_rows()], rid)
    assert Map.has_key?(cells(slug), "A5")

    log =
      capture_log(fn ->
        # The heir cannot help here: an explicit delete takes the table with no
        # transfer. This is the residual (c) does not cover, and the reason the
        # fail-soft rescues had to stop being silent.
        :ets.delete(@table)
        assert :ets.whereis(@table) == :undefined

        assert Session.apply_ops(slug, @dataset, [insert_two_rows()], rid) ==
                 {:error, :replay_unavailable}
      end)

    assert log =~ "ReplayRing"
    assert log =~ "[error]"

    assert log =~ Content.published_id(slug),
           "the :error log must name the ring key so the lapse is traceable"

    # Refused, not applied: the cell did not take a second shift.
    assert Map.has_key?(cells(slug), "A5")
    refute Map.has_key?(cells(slug), "A7")

    ensure_ring!()
    assert :ets.whereis(@table) != :undefined
  end

  # ── (3) THE ANCHOR, order-independent ──────────────────────────────────────

  test "the replay table is anchored to the Sheets supervisor, not to the ring alone" do
    sup = Process.whereis(@sheets_sup)
    assert is_pid(sup)

    owner = :ets.info(@table, :owner)
    heir = :ets.info(@table, :heir)

    assert owner == sup or heir == sup, """
    :sheets_ops_replay must be anchored to #{inspect(@sheets_sup)} in one of its
    two legal states: the ring owns it with the supervisor as HEIR (no crash yet
    in this VM), or the supervisor already OWNS it (a crash happened and the
    heir took it — ETS clears the heir on transfer). Neither held:
      owner: #{inspect(owner)}
      heir:  #{inspect(heir)}
      sup:   #{inspect(sup)}
    A table anchored only to the ring dies with the ring, and exactly-once dies
    with it silently.
    """
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Sheets.Session,
      Keyword.merge(base, overrides)
    )
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp create_sheet(slug, cells) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "content" => %{"locale" => "nb-NO", "tabs" => [%{"name" => "T0", "cells" => cells}]}
        },
        @dataset
      )

    doc
  end

  defp cells(slug) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(0), "cells"])
  end

  # `insert_rows at:1 count:2` shifts every row down by two: A3 -> A5 after ONE
  # application, A7 after TWO. The non-idempotent op the guarantee is about.
  defp insert_two_rows, do: %{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => 2}

  # The ring key an unscoped `apply_ops/4` resolves to — `Session.key/3`
  # normalizes a nil workspace to the seeded Default workspace.
  defp ring_key(slug) do
    ws =
      case Barkpark.Tenancy.get_default_workspace() do
        %{id: id} when is_binary(id) -> id
        _ -> nil
      end

    {@dataset, ws, Content.published_id(slug)}
  end

  # A REAL restart: kill the supervised singleton and wait for the supervisor
  # to put a NEW pid in its place. No mock, no manual start.
  defp restart_ring! do
    pid = Process.whereis(ReplayRing)
    assert is_pid(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

    wait_until(fn ->
      case Process.whereis(ReplayRing) do
        new when is_pid(new) -> new != pid
        _ -> false
      end
    end)

    Process.whereis(ReplayRing)
  end

  # Restore the invariant a test may have broken: a live ring owning (or
  # sharing, via the heir) a live table.
  defp ensure_ring! do
    if :ets.whereis(@table) == :undefined do
      with_log(fn -> restart_ring!() end)
    end

    :ok
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met in time")
      true -> Process.sleep(10) && do_wait_until(fun, deadline)
    end
  end
end
