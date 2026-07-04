defmodule Barkpark.Plugins.Sheets.SessionIdempotencyTest do
  @moduledoc """
  QR-A locks for the `/ops` request_id replay ring — exactly-once batch
  application under retry (QR-D1).

  The named failure: a retried batch under a 503 double-applies its
  non-idempotent ops (an `insert_rows` runs twice) because a 503-retry lands
  on a FRESH session by construction, so any in-GenServer guard is gone. The
  ring lives in a restart-surviving public ETS table
  (`Barkpark.Plugins.Sheets.Session.ReplayRing`), so a re-sent batch that
  carries the same `request_id` replays the cached reply and applies NOTHING.

  `async: false` — sessions are globally registered processes reading and
  persisting through the SQL sandbox, and the ring is a global ETS table.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @dataset "sheets_idempotency_test"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    # Keep the production 2s debounce / 5min idle-stop out of test timing:
    # the 503-survival test relies on the first apply NOT having persisted
    # (so the fresh session reloads the ORIGINAL row), which the 60s debounce
    # guarantees.
    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    :ok
  end

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

  # `insert_rows at:1 count:2` shifts every row down by two, so a cell parked
  # at A3 lands at A5 after ONE application and at A7 after TWO — the
  # non-idempotent op the wish names.
  defp insert_two_rows, do: %{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => 2}

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

  # ── (a) THE WISH CASE: same request_id twice, same live session ───────────

  test "a re-sent insert_rows batch with the same request_id applies exactly once" do
    create_sheet("idem-wish", %{"A3" => %{"v" => "x"}})

    {:ok, reply1} =
      Session.apply_ops("idem-wish", @dataset, [insert_two_rows()], "wish-req-1")

    # First application shifted A3 → A5.
    assert Map.has_key?(cells("idem-wish"), "A5")
    refute Map.has_key?(cells("idem-wish"), "A3")
    refute Map.has_key?(cells("idem-wish"), "A7")
    assert reply1.applied == 1

    {:ok, reply2} =
      Session.apply_ops("idem-wish", @dataset, [insert_two_rows()], "wish-req-1")

    # The retry did NOT re-apply: A5 stays, no A7 (double-shift would land at A7).
    assert Map.has_key?(cells("idem-wish"), "A5")
    refute Map.has_key?(cells("idem-wish"), "A7")

    # The second reply IS the first, verbatim, + the additive replayed flag.
    assert reply2 == Map.put(reply1, :replayed, true)
    assert reply2.replayed == true
  end

  # ── (b) THE 503 CLASS: ring survives a session restart ────────────────────

  test "the ring survives a killed session — a retry after a crash never re-applies" do
    create_sheet("idem-503", %{"A3" => %{"v" => "x"}})

    {:ok, reply1} =
      Session.apply_ops("idem-503", @dataset, [insert_two_rows()], "req-503")

    pid = Session.whereis("idem-503", @dataset)
    assert is_pid(pid)

    # Kill hard (no terminate/persist — the first apply's shift is lost, exactly
    # the 503 scenario), then wait for the registry to drop the dead pid.
    Process.exit(pid, :kill)
    wait_until(fn -> Session.whereis("idem-503", @dataset) == nil end)

    # Resend the SAME batch + request_id. It lands on a FRESH session that
    # reloaded the ORIGINAL (unpersisted) row — without a surviving ring it
    # would re-apply and shift A3 → A5; with the ring it replays and applies
    # nothing, so the fresh session's content stays byte-original.
    {:ok, reply2} =
      Session.apply_ops("idem-503", @dataset, [insert_two_rows()], "req-503")

    assert reply2.replayed == true
    assert reply2 == Map.put(reply1, :replayed, true)

    # Proof no application happened on the fresh session: the original A3 is
    # still there, un-shifted.
    assert Map.has_key?(cells("idem-503"), "A3")
    refute Map.has_key?(cells("idem-503"), "A5")
  end

  # ── (c) NO request_id: byte-identical to today (both apply) ───────────────

  test "without a request_id two identical batches BOTH apply (pre-ring behavior)" do
    create_sheet("idem-none", %{"A3" => %{"v" => "x"}})

    {:ok, reply1} = Session.apply_ops("idem-none", @dataset, [insert_two_rows()])
    assert reply1.applied == 1
    refute Map.has_key?(reply1, :replayed)
    assert Map.has_key?(cells("idem-none"), "A5")

    {:ok, reply2} = Session.apply_ops("idem-none", @dataset, [insert_two_rows()])
    assert reply2.applied == 1
    refute Map.has_key?(reply2, :replayed)

    # Both applied → the cell double-shifted A3 → A5 → A7.
    assert Map.has_key?(cells("idem-none"), "A7")
    refute Map.has_key?(cells("idem-none"), "A5")
  end

  # ── (d) two DIFFERENT request_ids both apply ──────────────────────────────

  test "two different request_ids both apply" do
    create_sheet("idem-two", %{"A3" => %{"v" => "x"}})

    {:ok, reply1} = Session.apply_ops("idem-two", @dataset, [insert_two_rows()], "rid-A")
    assert reply1.applied == 1
    assert Map.has_key?(cells("idem-two"), "A5")

    {:ok, reply2} = Session.apply_ops("idem-two", @dataset, [insert_two_rows()], "rid-B")
    assert reply2.applied == 1
    refute Map.get(reply2, :replayed, false)

    # Distinct keys → both applied → double shift to A7.
    assert Map.has_key?(cells("idem-two"), "A7")
  end

  # ── same request_id, DIFFERENT ops → the FIRST reply (idempotency-key) ─────

  test "same request_id with different ops returns the first reply and applies nothing new" do
    create_sheet("idem-firstwins", %{"A3" => %{"v" => "x"}})

    {:ok, reply1} =
      Session.apply_ops("idem-firstwins", @dataset, [insert_two_rows()], "rid-fw")

    assert Map.has_key?(cells("idem-firstwins"), "A5")

    # A completely different batch under the SAME request_id: no new application.
    {:ok, reply2} =
      Session.apply_ops(
        "idem-firstwins",
        @dataset,
        [%{"op" => "set_cell", "tab" => 0, "ref" => "Z9", "raw" => "should-not-land"}],
        "rid-fw"
      )

    assert reply2 == Map.put(reply1, :replayed, true)
    refute Map.has_key?(cells("idem-firstwins"), "Z9")
  end
end
