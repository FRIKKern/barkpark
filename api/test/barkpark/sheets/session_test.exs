defmodule Barkpark.Sheets.SessionTest do
  @moduledoc """
  M1 locks for `Barkpark.Sheets.Session` — the per-sheet collaborative
  GenServer: lazy lifecycle (start on first op, hibernate, idle stop),
  mailbox-serialized last-write-wins ops, per-op recompute deltas on the
  suffixed doc topic, op-count/idle-debounced persistence through the
  canonical upsert path (write-through embeds included), and the documented
  external-write conflict warning.

  `async: false` — sessions are globally registered processes that read and
  persist through the SQL sandbox, so every test runs in shared mode, and
  the timing knobs go through the global `Application` env.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content
  alias Barkpark.Sheets.Session

  @dataset "sheets_m1_session_test"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Sheets.Session)
    end)

    # Keep the production 2s debounce / 5min idle-stop out of test timing by
    # default; individual tests override the knob they exercise.
    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    :ok
  end

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Sheets.Session, [])
    Application.put_env(:barkpark, Barkpark.Sheets.Session, Keyword.merge(base, overrides))
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Barkpark.Sheets.SessionSupervisor),
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
        %{"doc_id" => slug, "content" => %{"locale" => "nb-NO", "tabs" => [%{"name" => "T0", "cells" => cells}]}},
        @dataset
      )

    doc
  end

  defp set_cell(ref, raw, tab \\ 0), do: %{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => raw}
  defp clear_cell(ref, tab \\ 0), do: %{"op" => "clear_cell", "tab" => tab, "ref" => ref}

  defp persisted_cell(slug, ref) do
    {:ok, doc} = Content.get_document(Content.draft_id(slug), "sheet", @dataset)
    get_in(doc.content, ["tabs", Access.at(0), "cells", ref])
  end

  defp peek_cell(slug, ref) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(0), "cells", ref])
  end

  defp wait_until(fun, timeout \\ 2_000) do
    do_wait_until(fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  # ── lifecycle ───────────────────────────────────────────────────────────────

  describe "lifecycle" do
    test "lazy start on first op; subsequent ops reuse the same session" do
      create_sheet("lc-lazy", %{"A1" => %{"v" => "x"}})
      assert Session.whereis("lc-lazy", @dataset) == nil

      {:ok, %{rev: 1}} = Session.apply_ops("lc-lazy", @dataset, [set_cell("B1", 1)])
      pid = Session.whereis("lc-lazy", @dataset)
      assert is_pid(pid)

      {:ok, %{rev: 2}} = Session.apply_ops("lc-lazy", @dataset, [set_cell("B2", 2)])
      assert Session.whereis("lc-lazy", @dataset) == pid
    end

    test "an unknown sheet never starts a session" do
      assert {:error, :not_found} = Session.apply_ops("lc-ghost", @dataset, [set_cell("A1", 1)])
      assert Session.whereis("lc-ghost", @dataset) == nil
    end

    test "idle stop after idle_stop_ms without calls — terminate persists" do
      put_cfg(idle_stop_ms: 80)
      create_sheet("lc-idle", %{"A1" => %{"v" => "old"}})

      {:ok, _} = Session.apply_ops("lc-idle", @dataset, [set_cell("A1", "new")])
      pid = Session.whereis("lc-idle", @dataset)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      # Registry entries clean up asynchronously after the process dies.
      wait_until(fn -> Session.whereis("lc-idle", @dataset) == nil end)
      assert persisted_cell("lc-idle", "A1") == %{"v" => "new"}
    end

    test "hibernates when idle" do
      put_cfg(hibernate_after: 20)
      create_sheet("lc-hib", %{"A1" => %{"v" => 1}})

      {:ok, _} = Session.apply_ops("lc-hib", @dataset, [set_cell("B1", 2)])
      pid = Session.whereis("lc-hib", @dataset)

      # The hibernated frame differs across OTP releases — accept both the
      # classic :erlang.hibernate/3 and the gen_server loop_hibernate wrapper.
      wait_until(fn ->
        case Process.info(pid, :current_function) do
          {:current_function, {:erlang, :hibernate, 3}} -> true
          {:current_function, {:gen_server, :loop_hibernate, 4}} -> true
          _ -> false
        end
      end)
    end
  end

  # ── ops ─────────────────────────────────────────────────────────────────────

  describe "ops" do
    test "set_cell stores plain values (ref normalized) and bumps rev per applied op" do
      create_sheet("op-set", %{})

      {:ok, %{rev: 2, applied: 2, errors: []}} =
        Session.apply_ops("op-set", @dataset, [set_cell("a1", "hello"), set_cell("B2", 4.5)])

      assert peek_cell("op-set", "A1") == %{"v" => "hello"}
      assert peek_cell("op-set", "B2") == %{"v" => 4.5}
    end

    test "a leading '=' means formula — stored canonical, recomputed immediately" do
      create_sheet("op-formula", %{"A1" => %{"v" => 2}})

      {:ok, %{applied: 1}} = Session.apply_ops("op-formula", @dataset, [set_cell("B1", "=A1*3")])

      assert peek_cell("op-formula", "B1") == %{"f" => "A1*3", "v" => 6, "t" => "n"}
    end

    test "clear_cell removes the cell and the delta carries nil" do
      doc = create_sheet("op-clear", %{"A1" => %{"v" => "gone"}})
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Session.topic("op-clear", @dataset, doc.workspace_id))

      {:ok, %{applied: 1}} = Session.apply_ops("op-clear", @dataset, [clear_cell("A1")])

      assert peek_cell("op-clear", "A1") == nil
      assert_receive {:sheets_op, %{rev: 1, tab: 0, changed: %{"A1" => nil}}}, 1_000
    end

    test "recompute delta includes dependent cells, not just the op target" do
      doc = create_sheet("op-deps", %{"B1" => %{"v" => 1}, "C1" => %{"f" => "B1*2"}})
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Session.topic("op-deps", @dataset, doc.workspace_id))

      {:ok, %{rev: 1}} = Session.apply_ops("op-deps", @dataset, [set_cell("B1", 5)])

      assert_receive {:sheets_op, %{sheet_id: "op-deps", rev: 1, tab: 0, changed: changed}}, 1_000
      assert changed["B1"] == %{"v" => 5}
      assert changed["C1"] == %{"f" => "B1*2", "v" => 10, "t" => "n"}
    end
  end

  # ── validation ──────────────────────────────────────────────────────────────

  describe "validation" do
    test "invalid ops reject individually with their index; the rest apply" do
      create_sheet("val-mixed", %{})

      ops = [
        set_cell("A1", "ok"),
        set_cell("XFE1", 1),
        set_cell("A1048577", 1),
        set_cell("nope", 1),
        set_cell("A1", 1, 7),
        %{"op" => "explode"},
        set_cell("A2", %{"not" => "scalar"})
      ]

      {:ok, %{rev: 1, applied: 1, errors: errors}} = Session.apply_ops("val-mixed", @dataset, ops)

      assert [
               %{index: 1, code: "ref_out_of_bounds"},
               %{index: 2, code: "ref_out_of_bounds"},
               %{index: 3, code: "invalid_ref"},
               %{index: 4, code: "tab_not_found"},
               %{index: 5, code: "malformed_op"},
               %{index: 6, code: "invalid_raw"}
             ] = errors

      assert peek_cell("val-mixed", "A1") == %{"v" => "ok"}
    end

    test "cap-aware set_cell: a new non-empty cell past the cap errors; overwrites still land" do
      put_cfg(cell_cap: 2)
      create_sheet("val-cap", %{"A1" => %{"v" => "one"}})

      {:ok, %{applied: 1, errors: []}} = Session.apply_ops("val-cap", @dataset, [set_cell("B1", "two")])

      {:ok, %{applied: 0, errors: [%{index: 0, code: "cell_cap_exceeded"}]}} =
        Session.apply_ops("val-cap", @dataset, [set_cell("C1", "three")])

      # Overwriting an existing cell does not grow the count — allowed.
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("val-cap", @dataset, [set_cell("A1", "one-bis")])

      # Clearing frees room for a new cell.
      {:ok, %{applied: 2, errors: []}} =
        Session.apply_ops("val-cap", @dataset, [clear_cell("A1"), set_cell("C1", "three")])
    end
  end

  # ── LWW serialization ───────────────────────────────────────────────────────

  describe "LWW serialization under concurrent callers" do
    test "distinct cells from many processes: no lost updates, rev counts every op" do
      create_sheet("lww-distinct", %{})

      1..40
      |> Enum.map(fn i ->
        Task.async(fn -> Session.apply_ops("lww-distinct", @dataset, [set_cell("A#{i}", i)]) end)
      end)
      |> Task.await_many(10_000)

      {:ok, content} = Session.peek("lww-distinct", @dataset)
      cells = get_in(content, ["tabs", Access.at(0), "cells"])

      for i <- 1..40, do: assert(cells["A#{i}"] == %{"v" => i})

      {:ok, %{rev: rev, applied: 0}} = Session.apply_ops("lww-distinct", @dataset, [])
      assert rev == 40
    end

    test "same cell from many processes: the final value is one whole write (mailbox order)" do
      create_sheet("lww-same", %{})

      1..20
      |> Enum.map(fn i ->
        Task.async(fn -> Session.apply_ops("lww-same", @dataset, [set_cell("A1", "w#{i}")]) end)
      end)
      |> Task.await_many(10_000)

      assert %{"v" => "w" <> _} = peek_cell("lww-same", "A1")

      {:ok, %{rev: 20}} = Session.apply_ops("lww-same", @dataset, [])
    end
  end

  # ── persistence ─────────────────────────────────────────────────────────────

  describe "debounced persistence" do
    test "op-count flush: persists at flush_after_ops, not before" do
      put_cfg(flush_after_ops: 3)
      create_sheet("ps-count", %{"A1" => %{"v" => "v0"}})

      {:ok, _} = Session.apply_ops("ps-count", @dataset, [set_cell("A1", "v1"), set_cell("B1", 1)])
      assert persisted_cell("ps-count", "A1") == %{"v" => "v0"}

      {:ok, _} = Session.apply_ops("ps-count", @dataset, [set_cell("C1", 2)])
      assert persisted_cell("ps-count", "A1") == %{"v" => "v1"}
      assert persisted_cell("ps-count", "C1") == %{"v" => 2}
    end

    test "idle flush: persists after debounce_ms without further ops" do
      put_cfg(debounce_ms: 60)
      create_sheet("ps-idle", %{"A1" => %{"v" => "v0"}})

      {:ok, _} = Session.apply_ops("ps-idle", @dataset, [set_cell("A1", "v1")])
      assert persisted_cell("ps-idle", "A1") == %{"v" => "v0"}

      wait_until(fn -> persisted_cell("ps-idle", "A1") == %{"v" => "v1"} end)
    end

    test "flush/2 persists on demand and is a no-op without a session" do
      create_sheet("ps-flush", %{"A1" => %{"v" => "v0"}})

      {:ok, _} = Session.apply_ops("ps-flush", @dataset, [set_cell("A1", "v1")])
      assert persisted_cell("ps-flush", "A1") == %{"v" => "v0"}

      assert Session.flush("ps-flush", @dataset) == :ok
      assert persisted_cell("ps-flush", "A1") == %{"v" => "v1"}

      assert Session.flush("ps-no-session", @dataset) == :ok
    end

    test "persist-on-terminate: stop/2 flushes dirty state" do
      create_sheet("ps-term", %{})

      {:ok, _} = Session.apply_ops("ps-term", @dataset, [set_cell("A1", "kept")])
      assert Session.stop("ps-term", @dataset) == :ok

      # Registry entries clean up asynchronously after the process dies.
      wait_until(fn -> Session.whereis("ps-term", @dataset) == nil end)
      assert persisted_cell("ps-term", "A1") == %{"v" => "kept"}
    end

    test "the persisted row rides the canonical path: write-through embeds refresh" do
      sheet = create_sheet("ps-embed", %{"A1" => %{"v" => "before"}})
      pub_id = Content.published_id(sheet.doc_id)

      {:ok, paper} =
        Content.create_document(
          "paper",
          %{
            "doc_id" => "ps-embed-paper",
            "content" => %{"blocks" => [%{"id" => "b1", "type" => "sheet", "ref" => pub_id, "tab" => 0}]}
          },
          @dataset
        )

      {:ok, _} = Session.apply_ops("ps-embed", @dataset, [set_cell("A1", "after")])
      :ok = Session.flush("ps-embed", @dataset)

      {:ok, refreshed} = Content.get_document(paper.doc_id, "paper", @dataset)
      [block] = get_in(refreshed.content, ["blocks"])
      assert block["snapshot"]["rows"] == [["after"]]
    end

    test "an external write while the session lives logs a warning; the session's persist wins" do
      sheet = create_sheet("ps-conflict", %{"A1" => %{"v" => "session-side"}})

      {:ok, _} = Session.apply_ops("ps-conflict", @dataset, [set_cell("B1", "mine")])

      # Direct mutate to the same row — the documented M1 conflict.
      {:ok, _} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => sheet.doc_id, "content" => %{"tabs" => [%{"name" => "T0", "cells" => %{"A1" => %{"v" => "external"}}}]}},
          @dataset
        )

      log = capture_log(fn -> :ok = Session.flush("ps-conflict", @dataset) end)
      assert log =~ "external write detected"

      assert persisted_cell("ps-conflict", "A1") == %{"v" => "session-side"}
      assert persisted_cell("ps-conflict", "B1") == %{"v" => "mine"}
    end
  end
end
