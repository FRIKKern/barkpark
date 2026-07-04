defmodule Barkpark.Plugins.Sheets.SessionTest do
  @moduledoc """
  M1 locks for `Barkpark.Plugins.Sheets.Session` — the per-sheet collaborative
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
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Plugins.Sheets.Session.Ops

  @dataset "sheets_m1_session_test"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    # Keep the production 2s debounce / 5min idle-stop out of test timing by
    # default; individual tests override the knob they exercise.
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

  defp set_cell(ref, raw, tab \\ 0),
    do: %{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => raw}

  # S1's dynamic-array marker contract, verbatim: the anchor carries "f" +
  # "spill"(self) + "spill_dims"; each spilled cell carries "v" + "spill"(anchor)
  # and NO "f" (engine output, not user content).
  defp spill_anchor(formula, top_left, dims \\ [3, 1]),
    do: %{"f" => formula, "v" => top_left, "t" => "n", "spill" => "A1", "spill_dims" => dims}

  defp spilled(v), do: %{"v" => v, "t" => "n", "spill" => "A1"}

  defp clear_cell(ref, tab \\ 0), do: %{"op" => "clear_cell", "tab" => tab, "ref" => ref}

  # Counts `Ops.recompute_tab/1` invocations (the coalescing probe) by
  # attaching to its telemetry event and forwarding each to the test mailbox;
  # `drain_recompute_count/0` then tallies them non-blockingly.
  defp attach_recompute_counter do
    test_pid = self()
    handler_id = {:recompute_counter, make_ref()}

    :telemetry.attach(
      handler_id,
      [:barkpark, :sheets, :recompute_tab],
      fn _event, _measurements, _meta, _cfg -> send(test_pid, :recompute_tab_fired) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp drain_recompute_count(acc \\ 0) do
    receive do
      :recompute_tab_fired -> drain_recompute_count(acc + 1)
    after
      0 -> acc
    end
  end

  defp persisted_cell(slug, ref) do
    {:ok, doc} = Content.get_document(Content.draft_id(slug), "sheet", @dataset)
    get_in(doc.content, ["tabs", Access.at(0), "cells", ref])
  end

  defp peek_cell(slug, ref) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(0), "cells", ref])
  end

  defp merges(slug, tab \\ 0) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(tab), "merges"])
  end

  defp create_multi_tab(slug, tabs) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{"doc_id" => slug, "content" => %{"locale" => "nb-NO", "tabs" => tabs}},
        @dataset
      )

    doc
  end

  defp tab_names(slug) do
    {:ok, content} = Session.peek(slug, @dataset)
    Enum.map(content["tabs"], &Map.get(&1, "name"))
  end

  defp tab_map(slug, tab \\ 0) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(tab)])
  end

  defp tab_color(slug, tab \\ 0), do: Map.get(tab_map(slug, tab), "color")

  # A set_cell op stamped with a collaborator id so it records undo history.
  defp set_cell_by(user, ref, raw, tab \\ 0),
    do: set_cell(ref, raw, tab) |> Map.put("user", user)

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

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("op-clear", @dataset, doc.workspace_id)
      )

      {:ok, %{applied: 1}} = Session.apply_ops("op-clear", @dataset, [clear_cell("A1")])

      assert peek_cell("op-clear", "A1") == nil
      assert_receive {:sheets_op, %{rev: 1, tab: 0, changed: %{"A1" => nil}}}, 1_000
    end

    test "recompute delta includes dependent cells, not just the op target" do
      doc = create_sheet("op-deps", %{"B1" => %{"v" => 1}, "C1" => %{"f" => "B1*2"}})

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("op-deps", @dataset, doc.workspace_id)
      )

      {:ok, %{rev: 1}} = Session.apply_ops("op-deps", @dataset, [set_cell("B1", 5)])

      assert_receive {:sheets_op, %{sheet_id: "op-deps", rev: 1, tab: 0, changed: changed}}, 1_000
      assert changed["B1"] == %{"v" => 5}
      assert changed["C1"] == %{"f" => "B1*2", "v" => 10, "t" => "n"}
    end
  end

  # ── batch recompute coalescing ───────────────────────────────────────────────
  #
  # A batch of cell ops recomputes each dirty tab ONCE (not once per op) — the
  # 1000-op-paste timeout class. The coalesced delta must still carry recomputed
  # dependents, undo after a batch must recompute, and a fully-rejected batch
  # must not recompute at all.

  describe "batch recompute coalescing" do
    test "a multi-op cell batch recomputes the formula-bearing tab exactly once" do
      put_cfg(flush_after_ops: 10_000)
      create_sheet("bc-once", %{"A11" => %{"f" => "SUM(A1:A10)"}})
      attach_recompute_counter()

      ops = for r <- 1..10, do: set_cell("A#{r}", r)
      {:ok, %{applied: 10, errors: []}} = Session.apply_ops("bc-once", @dataset, ops)

      # One recompute for the whole batch — not one per op (the regression).
      assert drain_recompute_count() == 1
      assert peek_cell("bc-once", "A11") == %{"f" => "SUM(A1:A10)", "v" => 55, "t" => "n"}
    end

    test "each single-op call still recomputes once — per-op behavior unchanged" do
      put_cfg(flush_after_ops: 10_000)
      create_sheet("bc-single", %{"A11" => %{"f" => "SUM(A1:A10)"}})
      attach_recompute_counter()

      {:ok, %{applied: 1}} = Session.apply_ops("bc-single", @dataset, [set_cell("A1", 1)])
      assert drain_recompute_count() == 1

      {:ok, %{applied: 1}} = Session.apply_ops("bc-single", @dataset, [set_cell("A2", 2)])
      assert drain_recompute_count() == 1
    end

    test "the coalesced delta carries recomputed dependents and matches sequential final state" do
      doc = create_sheet("bc-delta", %{"A11" => %{"f" => "SUM(A1:A10)"}})

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("bc-delta", @dataset, doc.workspace_id)
      )

      ops = for r <- 1..10, do: set_cell("A#{r}", r)
      {:ok, %{rev: 10}} = Session.apply_ops("bc-delta", @dataset, ops)

      assert_receive {:sheets_op, %{tab: 0, changed: changed}}, 1_000
      assert changed["A1"] == %{"v" => 1}
      assert changed["A10"] == %{"v" => 10}
      # The dependent recomputed once and rode the coalesced delta.
      assert changed["A11"] == %{"f" => "SUM(A1:A10)", "v" => 55, "t" => "n"}

      # Applying the same ops one-per-call yields the identical final state.
      create_sheet("bc-seq", %{"A11" => %{"f" => "SUM(A1:A10)"}})
      for op <- ops, do: {:ok, _} = Session.apply_ops("bc-seq", @dataset, [op])
      assert peek_cell("bc-seq", "A11") == peek_cell("bc-delta", "A11")
    end

    test "undo after a batch that overwrote a formula's precedents recomputes the formula" do
      create_sheet("bc-undo", %{"A1" => %{"v" => 1}, "B1" => %{"f" => "A1*10"}})

      {:ok, %{applied: 1}} =
        Session.apply_ops("bc-undo", @dataset, [
          %{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => 9, "user" => "u1"}
        ])

      assert peek_cell("bc-undo", "B1") == %{"f" => "A1*10", "v" => 90, "t" => "n"}

      {:ok, %{applied: 1}} =
        Session.apply_ops("bc-undo", @dataset, [%{"op" => "undo", "user" => "u1"}])

      assert peek_cell("bc-undo", "A1") == %{"v" => 1}
      # The undo restored A1 AND recomputed the dependent — not a stale 90.
      assert peek_cell("bc-undo", "B1") == %{"f" => "A1*10", "v" => 10, "t" => "n"}
    end

    test "a fully-rejected batch on a formula tab triggers no recompute" do
      put_cfg(flush_after_ops: 10_000)
      create_sheet("bc-reject", %{"A11" => %{"f" => "SUM(A1:A10)"}})
      attach_recompute_counter()

      ops = [set_cell("nope", 1), %{"op" => "explode"}, set_cell("also-bad", 2)]
      {:ok, %{applied: 0, errors: [_, _, _]}} = Session.apply_ops("bc-reject", @dataset, ops)

      assert drain_recompute_count() == 0
    end

    test "1000 set_cell ops into a formula-bearing tab complete well under the call timeout" do
      put_cfg(flush_after_ops: 10_000)
      # ~100 formulas over a shared range plus the data column the batch fills.
      formulas = for r <- 1..100, into: %{}, do: {"C#{r}", %{"f" => "SUM(A1:A50)"}}
      create_sheet("bc-latency", formulas)

      ops = for r <- 1..1000, do: set_cell("A#{rem(r, 50) + 1}", r)

      {micros, {:ok, %{applied: 1000}}} =
        :timer.tc(fn -> Session.apply_ops("bc-latency", @dataset, ops) end)

      assert micros < 5_000_000,
             "1000-op batch took #{div(micros, 1000)}ms — coalescing regressed?"
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

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("val-cap", @dataset, [set_cell("B1", "two")])

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

  # ── structural ops ──────────────────────────────────────────────────────────

  describe "structural ops" do
    test "insert_rows shifts keys, rewrites + recomputes formulas, and the delta carries structure" do
      doc =
        create_sheet("st-insrow", %{
          "A1" => %{"v" => 1},
          "A2" => %{"v" => 2},
          "A3" => %{"f" => "SUM(A1:A2)", "v" => 3, "t" => "n"}
        })

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("st-insrow", @dataset, doc.workspace_id)
      )

      {:ok, %{rev: 1, applied: 1, errors: []}} =
        Session.apply_ops("st-insrow", @dataset, [
          %{"op" => "insert_rows", "tab" => 0, "at" => 2, "count" => 1}
        ])

      assert peek_cell("st-insrow", "A1") == %{"v" => 1}
      assert peek_cell("st-insrow", "A2") == nil
      assert peek_cell("st-insrow", "A3") == %{"v" => 2}
      # The range expanded over the inserted row and recomputed.
      assert peek_cell("st-insrow", "A4") == %{"f" => "SUM(A1:A3)", "v" => 3, "t" => "n"}

      assert_receive {:sheets_op, %{rev: 1, tab: 0, changed: changed, structure: structure}},
                     1_000

      assert structure == %{op: "insert_rows", at: 2, count: 1, tab: 0}
      assert changed["A2"] == nil
      assert changed["A3"] == %{"v" => 2}
      assert changed["A4"] == %{"f" => "SUM(A1:A3)", "v" => 3, "t" => "n"}
      refute Map.has_key?(changed, "A1")
    end

    test "delete_rows: refs into the span become #REF! and recompute to the error value" do
      create_sheet("st-delrow", %{
        "A1" => %{"v" => 1},
        "A2" => %{"v" => 2},
        "A3" => %{"f" => "A2*10", "v" => 20, "t" => "n"}
      })

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-delrow", @dataset, [
          %{"op" => "delete_rows", "tab" => 0, "at" => 2, "count" => 1}
        ])

      assert peek_cell("st-delrow", "A1") == %{"v" => 1}
      assert peek_cell("st-delrow", "A2") == %{"f" => "#REF!*10", "v" => "#REF!", "t" => "e"}
      assert peek_cell("st-delrow", "A3") == nil
    end

    test "insert_cols and delete_cols shift the column axis" do
      create_sheet("st-cols", %{"A1" => %{"v" => "a"}, "B1" => %{"v" => "b"}})

      {:ok, %{applied: 1}} =
        Session.apply_ops("st-cols", @dataset, [
          %{"op" => "insert_cols", "tab" => 0, "at" => 2, "count" => 2}
        ])

      assert peek_cell("st-cols", "A1") == %{"v" => "a"}
      assert peek_cell("st-cols", "D1") == %{"v" => "b"}

      {:ok, %{applied: 1}} =
        Session.apply_ops("st-cols", @dataset, [
          %{"op" => "delete_cols", "tab" => 0, "at" => 1, "count" => 3}
        ])

      assert peek_cell("st-cols", "A1") == %{"v" => "b"}
      assert peek_cell("st-cols", "D1") == nil
    end

    test "set_col_width and set_row_height set and clear; the delta carries structure, no cells" do
      doc = create_sheet("st-size", %{"A1" => %{"v" => 1}})

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("st-size", @dataset, doc.workspace_id)
      )

      {:ok, %{applied: 2, errors: []}} =
        Session.apply_ops("st-size", @dataset, [
          %{"op" => "set_col_width", "tab" => 0, "col" => 2, "px" => 120},
          %{"op" => "set_row_height", "tab" => 0, "row" => 3, "px" => 44}
        ])

      {:ok, content} = Session.peek("st-size", @dataset)
      assert get_in(content, ["tabs", Access.at(0), "col_widths"]) == %{"2" => 120}
      assert get_in(content, ["tabs", Access.at(0), "row_heights"]) == %{"3" => 44}

      assert_receive {:sheets_op,
                      %{
                        rev: 1,
                        changed: changed,
                        structure: %{op: "set_col_width", at: 2, count: nil, tab: 0}
                      }},
                     1_000

      assert changed == %{}

      {:ok, %{applied: 1}} =
        Session.apply_ops("st-size", @dataset, [
          %{"op" => "set_col_width", "tab" => 0, "col" => 2, "px" => nil}
        ])

      {:ok, content} = Session.peek("st-size", @dataset)
      assert get_in(content, ["tabs", Access.at(0), "col_widths"]) == %{}

      {:ok, %{applied: 0, errors: [%{index: 0, code: "invalid_px"}]}} =
        Session.apply_ops("st-size", @dataset, [
          %{"op" => "set_row_height", "tab" => 0, "row" => 1, "px" => -4}
        ])
    end

    test "set_frozen writes integer bands, clears on 0, and the delta carries structure" do
      doc = create_sheet("st-frozen", %{"A1" => %{"v" => 1}})

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("st-frozen", @dataset, doc.workspace_id)
      )

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-frozen", @dataset, [
          %{"op" => "set_frozen", "tab" => 0, "rows" => 2, "cols" => 1}
        ])

      {:ok, content} = Session.peek("st-frozen", @dataset)
      # Persisted as INTEGERS (not the schema's numeric-string convention).
      assert get_in(content, ["tabs", Access.at(0), "frozen_rows"]) == 2
      assert get_in(content, ["tabs", Access.at(0), "frozen_cols"]) == 1

      assert_receive {:sheets_op,
                      %{
                        rev: 1,
                        changed: changed,
                        structure: %{op: "set_frozen", at: nil, count: nil, tab: 0}
                      }},
                     1_000

      assert changed == %{}

      # A 0 band DELETES its key (sparse convention) — not a stored 0.
      {:ok, %{applied: 1}} =
        Session.apply_ops("st-frozen", @dataset, [
          %{"op" => "set_frozen", "tab" => 0, "rows" => 0, "cols" => 3}
        ])

      {:ok, content} = Session.peek("st-frozen", @dataset)
      tab = get_in(content, ["tabs", Access.at(0)])
      refute Map.has_key?(tab, "frozen_rows")
      assert Map.get(tab, "frozen_cols") == 3
    end

    test "set_frozen rejects a negative or non-integer band, leaving state untouched" do
      create_sheet("st-frozen-bad", %{})

      {:ok, %{applied: 0, errors: errors}} =
        Session.apply_ops("st-frozen-bad", @dataset, [
          %{"op" => "set_frozen", "tab" => 0, "rows" => -1, "cols" => 0},
          %{"op" => "set_frozen", "tab" => 0, "rows" => "x", "cols" => 0}
        ])

      assert [%{index: 0, code: "invalid_frozen"}, %{index: 1, code: "invalid_frozen"}] = errors

      {:ok, content} = Session.peek("st-frozen-bad", @dataset)
      tab = get_in(content, ["tabs", Access.at(0)])
      refute Map.has_key?(tab, "frozen_rows")
      refute Map.has_key?(tab, "frozen_cols")
    end

    test "set_frozen undo restores the prior band, normalizing a string-typed prior to an int" do
      # A tab whose frozen band was imported as the schema's numeric STRING.
      {:ok, _doc} =
        Content.create_document(
          "sheet",
          %{
            "doc_id" => "st-frozen-undo",
            "content" => %{
              "locale" => "nb-NO",
              "tabs" => [%{"name" => "T0", "cells" => %{}, "frozen_rows" => "2"}]
            }
          },
          @dataset
        )

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-frozen-undo", @dataset, [
          %{"op" => "set_frozen", "tab" => 0, "rows" => 0, "cols" => 4, "user" => "u1"}
        ])

      {:ok, content} = Session.peek("st-frozen-undo", @dataset)
      tab = get_in(content, ["tabs", Access.at(0)])
      refute Map.has_key?(tab, "frozen_rows")
      assert Map.get(tab, "frozen_cols") == 4

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-frozen-undo", @dataset, [%{"op" => "undo", "user" => "u1"}])

      {:ok, content} = Session.peek("st-frozen-undo", @dataset)
      tab = get_in(content, ["tabs", Access.at(0)])
      # Undo restored the "2" prior as an INTEGER; the transient cols band is gone.
      assert Map.get(tab, "frozen_rows") == 2
      refute Map.has_key?(tab, "frozen_cols")
    end

    test "rename_tab renames; a blank or non-string name is rejected" do
      create_sheet("st-rename", %{})

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-rename", @dataset, [
          %{"op" => "rename_tab", "tab" => 0, "name" => "Budget"}
        ])

      {:ok, content} = Session.peek("st-rename", @dataset)
      assert get_in(content, ["tabs", Access.at(0), "name"]) == "Budget"

      {:ok, %{applied: 0, errors: errors}} =
        Session.apply_ops("st-rename", @dataset, [
          %{"op" => "rename_tab", "tab" => 0, "name" => "  "},
          %{"op" => "rename_tab", "tab" => 0, "name" => 7}
        ])

      assert [%{index: 0, code: "invalid_name"}, %{index: 1, code: "invalid_name"}] = errors
    end

    test "add_tab appends an empty tab that immediately accepts ops" do
      doc = create_sheet("st-addtab", %{"A1" => %{"v" => "t0"}})

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("st-addtab", @dataset, doc.workspace_id)
      )

      {:ok, %{applied: 2, errors: []}} =
        Session.apply_ops("st-addtab", @dataset, [
          %{"op" => "add_tab", "name" => "T1"},
          %{"op" => "set_cell", "tab" => 1, "ref" => "A1", "raw" => "=1+1"}
        ])

      assert_receive {:sheets_op,
                      %{
                        rev: 1,
                        changed: %{} = changed,
                        structure: %{op: "add_tab", at: nil, count: nil, tab: 1}
                      }},
                     1_000

      assert changed == %{}

      {:ok, content} = Session.peek("st-addtab", @dataset)
      assert get_in(content, ["tabs", Access.at(1), "name"]) == "T1"

      assert get_in(content, ["tabs", Access.at(1), "cells", "A1"]) == %{
               "f" => "1+1",
               "v" => 2,
               "t" => "n"
             }

      assert get_in(content, ["tabs", Access.at(0), "cells", "A1"]) == %{"v" => "t0"}
    end

    test "delete_tab drops the tab, re-indexes counters, and the delta nils every cell" do
      doc = create_sheet("st-deltab", %{"A1" => %{"v" => "gone"}, "B2" => %{"v" => "also"}})

      {:ok, %{applied: 1}} =
        Session.apply_ops("st-deltab", @dataset, [%{"op" => "add_tab", "name" => "Keep"}])

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("st-deltab", @dataset, doc.workspace_id)
      )

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-deltab", @dataset, [%{"op" => "delete_tab", "tab" => 0}])

      assert_receive {:sheets_op, %{changed: changed, structure: %{op: "delete_tab", tab: 0}}},
                     1_000

      assert changed == %{"A1" => nil, "B2" => nil}

      # The surviving tab is now tab 0 — formulas on it still recompute
      # (the per-tab formula counters were recounted, not left stale).
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-deltab", @dataset, [
          %{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => "=2*3"}
        ])

      assert peek_cell("st-deltab", "A1") == %{"f" => "2*3", "v" => 6, "t" => "n"}
      {:ok, content} = Session.peek("st-deltab", @dataset)
      assert length(content["tabs"]) == 1
    end

    test "deleting the LAST tab is refused and nothing changes" do
      create_sheet("st-lasttab", %{"A1" => %{"v" => "stays"}})

      {:ok, %{applied: 0, errors: [%{index: 0, code: "last_tab"}]}} =
        Session.apply_ops("st-lasttab", @dataset, [%{"op" => "delete_tab", "tab" => 0}])

      assert peek_cell("st-lasttab", "A1") == %{"v" => "stays"}
    end

    test "an insert that would push occupied cells past the grid bounds errors cleanly" do
      create_sheet("st-bounds", %{"A1048576" => %{"v" => "edge"}})

      {:ok, %{applied: 0, errors: [%{index: 0, code: "grid_bounds_exceeded"}]}} =
        Session.apply_ops("st-bounds", @dataset, [
          %{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => 1}
        ])

      assert peek_cell("st-bounds", "A1048576") == %{"v" => "edge"}
    end

    test "move_tab reorders; the delta carries from/to and a reorder round-trips" do
      doc =
        create_multi_tab("st-move", [
          %{"name" => "A", "cells" => %{}},
          %{"name" => "B", "cells" => %{}},
          %{"name" => "C", "cells" => %{}}
        ])

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("st-move", @dataset, doc.workspace_id)
      )

      # Move the last tab to the front.
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-move", @dataset, [%{"op" => "move_tab", "from" => 2, "to" => 0}])

      assert_receive {:sheets_op,
                      %{changed: %{}, structure: %{op: "move_tab", from: 2, to: 0, tab: 0}}},
                     1_000

      assert tab_names("st-move") == ["C", "A", "B"]

      # The mirror move restores the original order (self-inverting permutation).
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-move", @dataset, [%{"op" => "move_tab", "from" => 0, "to" => 2}])

      assert tab_names("st-move") == ["A", "B", "C"]
    end

    test "move_tab: out-of-range from/to rejects; from == to is a silent no-op" do
      create_multi_tab("st-move-bounds", [
        %{"name" => "A", "cells" => %{}},
        %{"name" => "B", "cells" => %{}}
      ])

      {:ok, %{applied: 0, errors: [%{index: 0, code: "tab_not_found"}]}} =
        Session.apply_ops("st-move-bounds", @dataset, [
          %{"op" => "move_tab", "from" => 0, "to" => 9}
        ])

      {:ok, %{applied: 0, errors: [%{index: 0, code: "tab_not_found"}]}} =
        Session.apply_ops("st-move-bounds", @dataset, [
          %{"op" => "move_tab", "from" => 9, "to" => 0}
        ])

      # from == to bumps no rev, records nothing, broadcasts nothing.
      {:ok, %{rev: rev0}} = Session.apply_ops("st-move-bounds", @dataset, [set_cell("A1", "x")])

      {:ok, %{rev: ^rev0, applied: 1, errors: []}} =
        Session.apply_ops("st-move-bounds", @dataset, [
          %{"op" => "move_tab", "from" => 1, "to" => 1}
        ])

      assert tab_names("st-move-bounds") == ["A", "B"]
    end

    test "move_tab re-indexes the per-tab formula counters so the moved tab still recomputes" do
      create_multi_tab("st-move-fc", [
        %{"name" => "A", "cells" => %{}},
        %{"name" => "B", "cells" => %{"A1" => %{"v" => 2}, "A2" => %{"f" => "A1*10"}}}
      ])

      # Move the formula-bearing tab 1 to index 0, then edit its precedent —
      # a stale index-keyed counter would skip the engine and leave A2 raw.
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-move-fc", @dataset, [%{"op" => "move_tab", "from" => 1, "to" => 0}])

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-move-fc", @dataset, [set_cell("A1", 5, 0)])

      {:ok, content} = Session.peek("st-move-fc", @dataset)

      assert get_in(content, ["tabs", Access.at(0), "cells", "A2"]) == %{
               "f" => "A1*10",
               "v" => 50,
               "t" => "n"
             }
    end

    test "duplicate_tab deep-copies the whole tab, names it 'Copy of …', dedupes case-insensitively" do
      doc =
        create_multi_tab("st-dup", [
          %{
            "name" => "Data",
            "cells" => %{"A1" => %{"v" => "keep"}},
            "merges" => ["A1:B1"],
            "frozen_rows" => 1
          },
          %{"name" => "copy of data", "cells" => %{}}
        ])

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("st-dup", @dataset, doc.workspace_id)
      )

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-dup", @dataset, [%{"op" => "duplicate_tab", "tab" => 0}])

      assert_receive {:sheets_op, %{structure: %{op: "duplicate_tab", tab: 1}, changed: changed}},
                     1_000

      assert changed == %{"A1" => %{"v" => "keep"}}

      # Inserted at 0+1; the name collides case-insensitively with the existing
      # "copy of data", so it dedupes to " 2".
      assert tab_names("st-dup") == ["Data", "Copy of Data 2", "copy of data"]

      {:ok, content} = Session.peek("st-dup", @dataset)
      copy = get_in(content, ["tabs", Access.at(1)])
      assert copy["cells"] == %{"A1" => %{"v" => "keep"}}
      assert copy["merges"] == ["A1:B1"]
      assert copy["frozen_rows"] == 1
    end

    test "duplicate_tab: writing the copy leaves the source untouched" do
      create_multi_tab("st-dup-iso", [%{"name" => "Src", "cells" => %{"A1" => %{"v" => "orig"}}}])

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-dup-iso", @dataset, [%{"op" => "duplicate_tab", "tab" => 0}])

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("st-dup-iso", @dataset, [set_cell("A1", "mutated", 1)])

      {:ok, content} = Session.peek("st-dup-iso", @dataset)
      assert get_in(content, ["tabs", Access.at(0), "cells", "A1"]) == %{"v" => "orig"}
      assert get_in(content, ["tabs", Access.at(1), "cells", "A1"]) == %{"v" => "mutated"}
    end

    test "duplicate_tab enforces the session-total cell cap before copying" do
      put_cfg(cell_cap: 3)

      create_multi_tab("st-dup-cap", [
        %{"name" => "Full", "cells" => %{"A1" => %{"v" => 1}, "A2" => %{"v" => 2}}}
      ])

      # Source holds 2 non-empty cells; duplicating would make 4 > cap 3.
      {:ok, %{applied: 0, errors: [%{index: 0, code: "cell_cap_exceeded"}]}} =
        Session.apply_ops("st-dup-cap", @dataset, [%{"op" => "duplicate_tab", "tab" => 0}])

      {:ok, content} = Session.peek("st-dup-cap", @dataset)
      assert length(content["tabs"]) == 1
    end

    test "structural validation errors reject individually; the rest of the batch applies" do
      create_sheet("st-mixed", %{"A1" => %{"v" => 1}})

      ops = [
        %{"op" => "insert_rows", "tab" => 0, "at" => 0, "count" => 1},
        %{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => "two"},
        %{"op" => "insert_rows", "tab" => 9, "at" => 1, "count" => 1},
        %{"op" => "insert_rows", "tab" => 0, "at" => 1},
        %{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => 1}
      ]

      {:ok, %{rev: 1, applied: 1, errors: errors}} = Session.apply_ops("st-mixed", @dataset, ops)

      assert [
               %{index: 0, code: "invalid_at"},
               %{index: 1, code: "invalid_count"},
               %{index: 2, code: "tab_not_found"},
               %{index: 3, code: "malformed_op"}
             ] = errors

      assert peek_cell("st-mixed", "A2") == %{"v" => 1}
    end

    test "delete_rows frees non-empty-cell headroom (the cap counter is recounted)" do
      put_cfg(cell_cap: 2)
      create_sheet("st-cap", %{"A1" => %{"v" => "one"}, "A2" => %{"v" => "two"}})

      {:ok, %{applied: 0, errors: [%{code: "cell_cap_exceeded"}]}} =
        Session.apply_ops("st-cap", @dataset, [set_cell("B5", "over")])

      {:ok, %{applied: 2, errors: []}} =
        Session.apply_ops("st-cap", @dataset, [
          %{"op" => "delete_rows", "tab" => 0, "at" => 1, "count" => 2},
          set_cell("B5", "fits")
        ])

      assert peek_cell("st-cap", "B5") == %{"v" => "fits"}
    end

    test "structural state persists through the canonical path" do
      create_sheet("st-persist", %{"A1" => %{"v" => "x"}})

      {:ok, _} =
        Session.apply_ops("st-persist", @dataset, [
          %{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => 2},
          %{"op" => "set_col_width", "tab" => 0, "col" => 1, "px" => 99},
          %{"op" => "rename_tab", "tab" => 0, "name" => "Moved"}
        ])

      :ok = Session.flush("st-persist", @dataset)

      {:ok, doc} = Content.get_document(Content.draft_id("st-persist"), "sheet", @dataset)
      tab = get_in(doc.content, ["tabs", Access.at(0)])
      assert tab["cells"] == %{"A3" => %{"v" => "x"}}
      assert tab["col_widths"] == %{"1" => 99}
      assert tab["name"] == "Moved"
    end
  end

  # ── merge / unmerge ─────────────────────────────────────────────────────────

  describe "merge/unmerge ops" do
    test "merge_cells normalizes the range, lands in content, and the delta carries structure" do
      doc = create_sheet("mg-add", %{"A1" => %{"v" => "keep"}, "B2" => %{"v" => "covered"}})

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("mg-add", @dataset, doc.workspace_id)
      )

      # Unordered corners ("b2:a1") normalize to the canonical "A1:B2".
      {:ok, %{rev: 1, applied: 1, errors: []}} =
        Session.apply_ops("mg-add", @dataset, [
          %{"op" => "merge_cells", "tab" => 0, "range" => "b2:a1"}
        ])

      assert merges("mg-add") == ["A1:B2"]
      # NON-destructive: the covered cell keeps its value.
      assert peek_cell("mg-add", "B2") == %{"v" => "covered"}

      assert_receive {:sheets_op,
                      %{
                        rev: 1,
                        changed: changed,
                        structure: %{op: "merge_cells", at: nil, count: nil, tab: 0}
                      }},
                     1_000

      assert changed == %{}
    end

    test "overlap, degenerate, area and bounds are rejected with exact codes" do
      create_sheet("mg-reject", %{})

      {:ok, %{applied: 1}} =
        Session.apply_ops("mg-reject", @dataset, [
          %{"op" => "merge_cells", "tab" => 0, "range" => "A1:B2"}
        ])

      ops = [
        %{"op" => "merge_cells", "tab" => 0, "range" => "B2:C3"},
        %{"op" => "merge_cells", "tab" => 0, "range" => "E5:E5"},
        %{"op" => "merge_cells", "tab" => 0, "range" => "A100:CV1100"},
        %{"op" => "merge_cells", "tab" => 0, "range" => "XFC1:XFE2"}
      ]

      {:ok, %{applied: 0, errors: errors}} = Session.apply_ops("mg-reject", @dataset, ops)

      assert [
               %{index: 0, code: "merge_overlap"},
               %{index: 1, code: "merge_degenerate"},
               %{index: 2, code: "merge_area_exceeded"},
               %{index: 3, code: "merge_out_of_bounds"}
             ] = errors

      # The one valid merge is still the only one on the tab.
      assert merges("mg-reject") == ["A1:B2"]
    end

    test "unmerge_cells removes only the merges intersecting the range" do
      create_sheet("mg-un", %{})

      {:ok, %{applied: 2}} =
        Session.apply_ops("mg-un", @dataset, [
          %{"op" => "merge_cells", "tab" => 0, "range" => "A1:B2"},
          %{"op" => "merge_cells", "tab" => 0, "range" => "D4:E5"}
        ])

      # A range touching only the first span drops it and leaves the second.
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("mg-un", @dataset, [
          %{"op" => "unmerge_cells", "tab" => 0, "range" => "B2:B2"}
        ])

      assert merges("mg-un") == ["D4:E5"]

      # A range hitting no merge is refused.
      {:ok, %{applied: 0, errors: [%{index: 0, code: "no_merge_in_range"}]}} =
        Session.apply_ops("mg-un", @dataset, [
          %{"op" => "unmerge_cells", "tab" => 0, "range" => "Z9:Z10"}
        ])
    end

    test "a merged sheet persists through the canonical path without a before_save 409" do
      create_sheet("mg-persist", %{"A1" => %{"v" => "x"}})

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("mg-persist", @dataset, [
          %{"op" => "merge_cells", "tab" => 0, "range" => "A1:C3"}
        ])

      # The debounced flush runs the before_save gate (merge ≤ 10k, in bounds)
      # — a session merge the gate would 409 could never round-trip.
      :ok = Session.flush("mg-persist", @dataset)

      {:ok, doc} = Content.get_document(Content.draft_id("mg-persist"), "sheet", @dataset)
      assert get_in(doc.content, ["tabs", Access.at(0), "merges"]) == ["A1:C3"]
    end
  end

  # ── set_cell fmt/s overrides + the merge-covered-ref fence ───────────────────

  describe "set_cell fmt/s + covered-ref fence" do
    test "a set_cell WITHOUT fmt/s keys preserves the prior cell's fmt/s (#805 carry)" do
      create_sheet("sc-carry", %{"A1" => %{"v" => 1, "fmt" => "currency", "s" => %{"b" => true}}})

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("sc-carry", @dataset, [set_cell("A1", 2)])

      assert peek_cell("sc-carry", "A1") == %{
               "v" => 2,
               "fmt" => "currency",
               "s" => %{"b" => true}
             }
    end

    test "an explicit \"fmt\" override replaces the carried fmt; nil clears it" do
      create_sheet("sc-fmt", %{"A1" => %{"v" => 1, "fmt" => "currency"}})

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("sc-fmt", @dataset, [Map.put(set_cell("A1", 2), "fmt", "percent")])

      assert peek_cell("sc-fmt", "A1") == %{"v" => 2, "fmt" => "percent"}

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("sc-fmt", @dataset, [Map.put(set_cell("A1", 3), "fmt", nil)])

      assert peek_cell("sc-fmt", "A1") == %{"v" => 3}
    end

    test "an invalid \"fmt\" or non-map \"s\" rejects the op, leaving state untouched" do
      create_sheet("sc-bad", %{"A1" => %{"v" => "keep"}})

      {:ok, %{applied: 0, errors: errors}} =
        Session.apply_ops("sc-bad", @dataset, [
          Map.put(set_cell("A1", "x"), "fmt", "bogus"),
          Map.put(set_cell("A1", "y"), "s", "not-a-map")
        ])

      assert [%{index: 0, code: "invalid_fmt"}, %{index: 1, code: "invalid_style"}] = errors
      assert peek_cell("sc-bad", "A1") == %{"v" => "keep"}
    end

    test "set_cell into a merge-covered ref is rejected (merged_cell); the anchor still writes" do
      create_sheet("sc-cov", %{})

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("sc-cov", @dataset, [
          %{"op" => "merge_cells", "tab" => 0, "range" => "A1:B2"}
        ])

      # B1 is covered by the A1:B2 merge; A1 is the anchor.
      {:ok, %{applied: 1, errors: errors}} =
        Session.apply_ops("sc-cov", @dataset, [
          set_cell("B1", "phantom"),
          set_cell("A1", "anchor")
        ])

      assert [%{index: 0, code: "merged_cell"}] = errors
      assert peek_cell("sc-cov", "B1") == nil
      assert peek_cell("sc-cov", "A1") == %{"v" => "anchor"}
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

    test "structural + cell ops interleave whole from concurrent processes — no torn state" do
      create_sheet("lww-struct", Map.new(1..10, fn i -> {"A#{i}", %{"v" => i}} end))

      inserts =
        Enum.map(1..15, fn _ ->
          Task.async(fn ->
            Session.apply_ops("lww-struct", @dataset, [
              %{"op" => "insert_rows", "tab" => 0, "at" => 1, "count" => 1}
            ])
          end)
        end)

      # Each concurrent cell write targets its OWN column — a row insert
      # shifts it but can never collide it with another writer's cell.
      cols = ~w(B C D E F G H I J K L M N O P)

      sets =
        Enum.map(cols, fn col ->
          Task.async(fn ->
            Session.apply_ops("lww-struct", @dataset, [set_cell("#{col}1", "v-#{col}")])
          end)
        end)

      Task.await_many(inserts ++ sets, 10_000)

      {:ok, content} = Session.peek("lww-struct", @dataset)
      cells = get_in(content, ["tabs", Access.at(0), "cells"])

      # Every op was applied exactly once, whole.
      {:ok, %{rev: 30, applied: 0}} = Session.apply_ops("lww-struct", @dataset, [])

      # The ten seeded values survive in column A, contiguous and in order
      # — every insert shifted the WHOLE block or none of it (no tearing).
      a_cells =
        for {addr, %{"v" => v}} <- cells, String.starts_with?(addr, "A") do
          {String.to_integer(String.trim_leading(addr, "A")), v}
        end

      assert length(a_cells) == 10
      first_row = a_cells |> Enum.map(&elem(&1, 0)) |> Enum.min()
      assert first_row == 16
      assert Enum.sort(a_cells) == Enum.map(1..10, fn i -> {first_row + i - 1, i} end)

      # Every concurrent set_cell landed exactly once, value intact, alone
      # in its column (its key shifted with whichever inserts followed it).
      for col <- cols do
        assert [{_addr, %{"v" => v}}] =
                 Enum.filter(cells, fn {addr, _cell} -> String.starts_with?(addr, col) end)

        assert v == "v-#{col}"
      end
    end
  end

  # ── persistence ─────────────────────────────────────────────────────────────

  describe "debounced persistence" do
    test "op-count flush: persists at flush_after_ops, not before" do
      put_cfg(flush_after_ops: 3)
      create_sheet("ps-count", %{"A1" => %{"v" => "v0"}})

      {:ok, _} =
        Session.apply_ops("ps-count", @dataset, [set_cell("A1", "v1"), set_cell("B1", 1)])

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
            "content" => %{
              "blocks" => [%{"id" => "b1", "type" => "sheet", "ref" => pub_id, "tab" => 0}]
            }
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
          %{
            "doc_id" => sheet.doc_id,
            "content" => %{
              "tabs" => [%{"name" => "T0", "cells" => %{"A1" => %{"v" => "external"}}}]
            }
          },
          @dataset
        )

      log = capture_log(fn -> :ok = Session.flush("ps-conflict", @dataset) end)
      assert log =~ "external write detected"

      assert persisted_cell("ps-conflict", "A1") == %{"v" => "session-side"}
      assert persisted_cell("ps-conflict", "B1") == %{"v" => "mine"}
    end
  end

  describe "session epoch" do
    test "a restarted session re-counts rev from 1 under a NEW epoch" do
      doc = create_sheet("op-epoch", %{})

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("op-epoch", @dataset, doc.workspace_id)
      )

      {:ok, %{rev: 1, epoch: epoch1}} =
        Session.apply_ops("op-epoch", @dataset, [set_cell("A1", 1)])

      assert_receive {:sheets_op, %{rev: 1, epoch: ^epoch1}}, 1_000

      stop_all_sessions()

      # The Registry sweeps a dead pid asynchronously — wait it out so
      # call_session's single retry can't burn both attempts on the corpse
      # (same guard as the adversarial epoch test; real restarts are
      # seconds apart, this race is test-only).
      wait_until(fn ->
        Registry.lookup(Barkpark.Plugins.Sheets.SessionRegistry, {@dataset, "op-epoch"}) == []
      end)

      # New incarnation: same sheet, rev re-counts from 1 — the epoch is the
      # only thing telling a client this is NOT a stale frame.
      {:ok, %{rev: 1, epoch: epoch2}} =
        Session.apply_ops("op-epoch", @dataset, [set_cell("B1", 2)])

      assert_receive {:sheets_op, %{rev: 1, epoch: ^epoch2}}, 1_000
      assert epoch2 != epoch1
    end
  end

  # ── sort_range op (SF-A) ────────────────────────────────────────────────────

  describe "sort_range op" do
    defp sort_op(range, keys, extra \\ %{}),
      do: Map.merge(%{"op" => "sort_range", "tab" => 0, "range" => range, "keys" => keys}, extra)

    defp asc(col), do: %{"col" => col, "dir" => "asc"}

    test "reorders rows and RECOMPUTES verbatim-moved formulas" do
      # Each B references its own row's A; sorting A:B moves the formula strings
      # verbatim (=A2 stays =A2) but the recompute refreshes their values.
      create_sheet("sort-recompute", %{
        "A1" => %{"v" => 3},
        "B1" => %{"f" => "A1"},
        "A2" => %{"v" => 1},
        "B2" => %{"f" => "A2"},
        "A3" => %{"v" => 2},
        "B3" => %{"f" => "A3"}
      })

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("sort-recompute", @dataset, [sort_op("A1:B3", [asc(0)])])

      # A sorted ascending.
      assert peek_cell("sort-recompute", "A1")["v"] == 1
      assert peek_cell("sort-recompute", "A2")["v"] == 2
      assert peek_cell("sort-recompute", "A3")["v"] == 3

      # The formula strings rode along VERBATIM (old row 2 → new row 1, etc.)
      # while the recompute settled their values against the NEW neighbours.
      assert peek_cell("sort-recompute", "B1")["f"] == "A2"
      assert peek_cell("sort-recompute", "B1")["v"] == 2
      assert peek_cell("sort-recompute", "B3")["f"] == "A1"
      assert peek_cell("sort-recompute", "B3")["v"] == 1
    end

    test "an already-sorted range is a no-op — no rev bump, no undo entry" do
      create_sheet("sort-noop", %{"A1" => %{"v" => 1}, "A2" => %{"v" => 2}, "A3" => %{"v" => 3}})

      # A real op first so we have a known rev to compare against.
      {:ok, %{rev: rev1}} = Session.apply_ops("sort-noop", @dataset, [set_cell("D1", "x")])

      {:ok, %{applied: 1, errors: [], rev: rev2}} =
        Session.apply_ops("sort-noop", @dataset, [
          sort_op("A1:A3", [asc(0)], %{"user" => "u"})
        ])

      # Applied (not an error) but the identity permutation bumped nothing.
      assert rev2 == rev1

      # …and recorded NO undo entry, so the user's stack is empty.
      {:ok, %{applied: 0, errors: [%{code: "nothing_to_undo"}]}} =
        Session.apply_ops("sort-noop", @dataset, [%{"op" => "undo", "user" => "u"}])
    end

    test "a merge intersecting the range refuses with sort_merge_overlap" do
      create_sheet("sort-merge", %{"A1" => %{"v" => 2}, "A2" => %{"v" => 1}})

      {:ok, %{applied: 1}} =
        Session.apply_ops("sort-merge", @dataset, [
          %{"op" => "merge_cells", "tab" => 0, "range" => "A1:B2"}
        ])

      {:ok, %{applied: 0, errors: [%{code: "sort_merge_overlap"}]}} =
        Session.apply_ops("sort-merge", @dataset, [sort_op("A1:C3", [asc(0)])])
    end

    test "malformed keys refuse with invalid_sort_keys" do
      create_sheet("sort-keys", %{"A1" => %{"v" => 2}, "A2" => %{"v" => 1}})

      {:ok, %{applied: 0, errors: [%{code: "invalid_sort_keys"}]}} =
        Session.apply_ops("sort-keys", @dataset, [
          sort_op("A1:A2", [%{"col" => 0, "dir" => "up"}])
        ])
    end

    test "a range past the grid bounds refuses with sort_out_of_bounds" do
      create_sheet("sort-bounds", %{"A1" => %{"v" => 2}, "A2" => %{"v" => 1}})

      # Row 1_048_577 is one past the Excel grid; column XFE one past XFD.
      {:ok, %{applied: 0, errors: [%{code: "sort_out_of_bounds"}]}} =
        Session.apply_ops("sort-bounds", @dataset, [sort_op("A1:A1048577", [asc(0)])])

      {:ok, %{applied: 0, errors: [%{code: "sort_out_of_bounds"}]}} =
        Session.apply_ops("sort-bounds", @dataset, [sort_op("A1:XFE2", [asc(0)])])
    end

    test "a non-range string refuses with invalid_range" do
      create_sheet("sort-badrange", %{"A1" => %{"v" => 2}, "A2" => %{"v" => 1}})

      {:ok, %{applied: 0, errors: [%{code: "invalid_range"}]}} =
        Session.apply_ops("sort-badrange", @dataset, [sort_op("banana", [asc(0)])])
    end
  end

  # ── cross-tab references (X3 / wave-1) ──────────────────────────────────────
  #
  # X3 owns the SESSION half of cross-tab: the precedent index, cross-tab dirty
  # propagation, the whole-doc recompute path, and the lossless multi-tab rename
  # undo. The ENGINE half (actually resolving `Sheet2!A1` to a value / a cycle)
  # is X1 and is gated in engine_test — so these locks assert the session
  # PROPAGATION (which tab is dirtied + which delta is broadcast + the undo
  # capture), which is correct BEFORE X1 lands and only gets stronger after.
  describe "cross-tab references (X3)" do
    test "build_cross_tab_index maps target tab -> dependent tabs (by name; self-refs excluded)" do
      content = %{
        "tabs" => [
          # Sheet1 (0) reads Sheet2 and 'My Sheet'
          ct_tab("Sheet1", %{
            "A1" => %{"f" => "Sheet2!A1"},
            "B1" => %{"f" => "SUM('My Sheet'!A1:B5)"},
            "C1" => %{"f" => "Sheet1!A1"}
          }),
          ct_tab("Sheet2", %{"A1" => %{"v" => 5}}),
          ct_tab("My Sheet", %{"A1" => %{"v" => 1}})
        ]
      }

      index = Ops.build_cross_tab_index(content)

      # Sheet2 (1) and 'My Sheet' (2) each have Sheet1 (0) as a dependent.
      assert Map.get(index, 1) == MapSet.new([0])
      assert Map.get(index, 2) == MapSet.new([0])
      # A same-tab self-name-ref (Sheet1!A1 inside Sheet1) is NOT an edge —
      # it stays on the per-tab fast path.
      refute Map.has_key?(index, 0)
      # An unknown tab name adds no edge.
      assert Ops.build_cross_tab_index(%{
               "tabs" => [ct_tab("Sheet1", %{"A1" => %{"f" => "Ghost!A1"}})]
             }) == %{}
    end

    test "editing a referenced tab dirties + broadcasts the dependent tab's delta" do
      doc =
        create_multi_tab("ct-prop", [
          ct_tab("Sheet1", %{"A1" => %{"f" => "Sheet2!A1"}}),
          ct_tab("Sheet2", %{"A1" => %{"v" => 5}})
        ])

      Phoenix.PubSub.subscribe(Barkpark.PubSub, Session.topic("ct-prop", @dataset, doc.workspace_id))

      # Edit Sheet2!A1 (tab 1). Sheet1 (tab 0) references it by name, so the
      # session must dirty AND broadcast tab 0 too — the founding "other tabs
      # can't change" assumption is broken.
      {:ok, %{rev: 1}} =
        Session.apply_ops("ct-prop", @dataset, [set_cell("A1", 6, 1)])

      assert_receive {:sheets_op, %{tab: 1, changed: %{"A1" => %{"v" => 6}}}}, 1_000
      # The dependent tab's delta is the load-bearing assertion (the value it
      # carries becomes non-empty once X1's cross-tab eval lands).
      assert_receive {:sheets_op, %{tab: 0}}, 1_000
    end

    test "a zero-cross-tab edit keeps the per-tab fast path; a cross-tab edit goes whole-doc" do
      attach_recompute_counter()

      # (a) No cross-tab ref anywhere: editing a formula tab takes the per-tab
      # path, whose `recompute_tab/1` telemetry fires.
      create_multi_tab("ct-fast", [
        ct_tab("Sheet1", %{"A1" => %{"v" => 1}, "B1" => %{"f" => "A1*2"}}),
        ct_tab("Sheet2", %{"A1" => %{"v" => 9}})
      ])

      {:ok, %{rev: 1}} = Session.apply_ops("ct-fast", @dataset, [set_cell("A1", 5, 0)])
      assert drain_recompute_count() >= 1

      # (b) With a cross-tab ref, editing the referenced tab takes the WHOLE-DOC
      # path — one unified `Engine.recompute/1`, so the per-tab `recompute_tab/1`
      # telemetry does NOT fire.
      create_multi_tab("ct-whole", [
        ct_tab("Sheet1", %{"A1" => %{"f" => "Sheet2!A1"}}),
        ct_tab("Sheet2", %{"A1" => %{"v" => 5}})
      ])

      {:ok, %{rev: 1}} = Session.apply_ops("ct-whole", @dataset, [set_cell("A1", 6, 1)])
      assert drain_recompute_count() == 0
    end

    test "insert_rows on a tab shifts OTHER tabs' cross-tab refs into it (X3→X2 seam)" do
      create_multi_tab("ct-shift", [
        ct_tab("Sheet1", %{"A1" => %{"f" => "Sheet2!A5"}}),
        ct_tab("Sheet2", %{"A5" => %{"v" => 42}})
      ])

      # Insert 1 row at row 2 of Sheet2 (tab 1): A5 slides to A6, so Sheet1's
      # cross-tab ref must shift Sheet2!A5 -> Sheet2!A6. This is the X3
      # apply_cross_tab_shift -> X2 Structure.shift_cross_tab_refs/4 seam; before
      # the seam was wired it was a silent no-op (guarded on a nonexistent /5).
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("ct-shift", @dataset, [
          %{"op" => "insert_rows", "tab" => 1, "at" => 2, "count" => 1}
        ])

      assert cross_tab_formula("ct-shift", 0, "A1") == "Sheet2!A6"
    end

    test "rename_tab undo restores the cross-tab refs it rewrote, losslessly" do
      create_multi_tab("ct-rename", [
        ct_tab("Sheet1", %{"A1" => %{"f" => "Sheet2!A1"}}),
        ct_tab("Sheet2", %{"A1" => %{"v" => 5}})
      ])

      # Rename Sheet2 -> Data (the op X2's Structure.rename_refs sweep rides).
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("ct-rename", @dataset, [
          %{"op" => "rename_tab", "tab" => 1, "name" => "Data", "user" => "u1"}
        ])

      assert Enum.at(tab_names("ct-rename"), 1) == "Data"

      # Simulate X2's sweep having rewritten the dependent ref (an ANONYMOUS op
      # — no undo entry — so u1's stack still has only the rename). Without this
      # the guarded seam is a no-op on origin/main; the point is that the undo
      # CAPTURE restores the prior ref no matter what the sweep did.
      {:ok, %{applied: 1}} =
        Session.apply_ops("ct-rename", @dataset, [set_cell("A1", "=Data!A1", 0)])

      assert cross_tab_formula("ct-rename", 0, "A1") == "Data!A1"

      # Undo the rename: it must rename back AND restore Sheet1!A1's PRIOR
      # formula (`Sheet2!A1`) — the named silent-corruption hazard (design §6).
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("ct-rename", @dataset, [%{"op" => "undo", "user" => "u1"}])

      assert Enum.at(tab_names("ct-rename"), 1) == "Sheet2"
      assert cross_tab_formula("ct-rename", 0, "A1") == "Sheet2!A1"

      # Redo re-applies both the rename and the rewritten ref (redo re-captures
      # the current cells) — undo/redo are the same machine run either way.
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("ct-rename", @dataset, [%{"op" => "redo", "user" => "u1"}])

      assert Enum.at(tab_names("ct-rename"), 1) == "Data"
      assert cross_tab_formula("ct-rename", 0, "A1") == "Data!A1"
    end

    test "move_tab is a cross-tab ref no-op (names are position-stable)" do
      create_multi_tab("ct-move", [
        ct_tab("Sheet1", %{"A1" => %{"f" => "Sheet2!A1"}}),
        ct_tab("Sheet2", %{"A1" => %{"v" => 5}}),
        ct_tab("Sheet3", %{"A1" => %{"v" => 9}})
      ])

      # Move Sheet3 to the front: tabs become [Sheet3, Sheet1, Sheet2].
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("ct-move", @dataset, [%{"op" => "move_tab", "from" => 2, "to" => 0}])

      assert tab_names("ct-move") == ["Sheet3", "Sheet1", "Sheet2"]
      # Sheet1's formula text is UNCHANGED — a name-based ref does not rewrite on
      # reorder (design decision 1 / §3.2). Sheet1 now sits at index 1.
      assert cross_tab_formula("ct-move", 1, "A1") == "Sheet2!A1"
    end

    test "the replay ring still dedups a cross-tab batch to one rev" do
      create_multi_tab("ct-ring", [
        ct_tab("Sheet1", %{"A1" => %{"f" => "Sheet2!A1"}}),
        ct_tab("Sheet2", %{"A1" => %{"v" => 5}})
      ])

      {:ok, first} =
        Session.apply_ops("ct-ring", @dataset, [set_cell("A1", 6, 1)], "req-ct-1")

      refute Map.get(first, :replayed)

      {:ok, second} =
        Session.apply_ops("ct-ring", @dataset, [set_cell("A1", 6, 1)], "req-ct-1")

      assert second.replayed == true
      # Exactly-once: the retry replays the cached reply and applies nothing, so
      # the rev is unchanged — a cross-tab batch dedups like any other.
      assert second.rev == first.rev
    end
  end

  # ── dynamic-array spill regions (S2) ─────────────────────────────────────────
  #
  # Wave-3 (spill) session contract, design §3.3 (B-SP-5/6). The engine (S1)
  # materializes a spilled array into anchor-owned marked cells: the anchor
  # keeps its `"f"` and gains `"spill"`(self) + `"spill_dims"`; each non-anchor
  # spilled cell carries `"v"` + `"spill"`(anchorRef) and NO `"f"` — engine
  # OUTPUT, not user content. This block locks the three session-layer
  # invariants that ride that contract:
  #
  #   1. THE SEAM — `nonempty_flag/1` excludes engine-owned spilled cells, so a
  #      spill is invisible to every user-content count (`count_nonempty`,
  #      `tab_nonempty`, and the incremental cell-cap arithmetic all inherit it
  #      through that ONE predicate). A spill must never eat the cell-cap budget
  #      as N user cells.
  #   2. VACATE-AS-NIL — a shrunk/cleared region's now-empty positions surface
  #      as `nil` in the coalesced delta, through the ordinary
  #      captured-prior-vs-recomputed diff (no new delta shape).
  #   3. UNDO RE-DERIVES — the anchor edit's inverse stays the ordinary
  #      `{:cell, tab, anchorRef, prior_anchor_cell}`; undo restores the prior
  #      anchor + recomputes, and the region re-derives — spilled cells need NO
  #      individual inverse.
  #
  # S1 (the engine's array distribution + `#SPILL!`) is a SEPARATE slice; these
  # tests exercise the session mechanism directly (seeded marker-shaped cells +
  # the diff/undo rails) so they hold on the plain session cluster, and stay
  # byte-identical once S1's recompute drives real spills through them.

  describe "dynamic-array spill regions (S2)" do
    test "nonempty_flag: a non-anchor spilled cell counts 0; the anchor counts 1; plain cells unchanged" do
      # The seam. Engine-owned spilled output → 0.
      assert Ops.nonempty_flag(spilled(2)) == 0
      assert Ops.nonempty_flag(%{"v" => "", "spill" => "A1"}) == 0
      # The anchor carries "spill" too but ALSO an "f" — user-authored → 1.
      assert Ops.nonempty_flag(spill_anchor("=SORT(C1:C3)", 3)) == 1

      # No-spill regression: a cell with NO "spill" marker follows the exact
      # pre-seam v/f predicate, byte-identical.
      assert Ops.nonempty_flag(%{"v" => 5}) == 1
      assert Ops.nonempty_flag(%{"f" => "=A1"}) == 1
      assert Ops.nonempty_flag(%{"v" => ""}) == 0
      assert Ops.nonempty_flag(%{"v" => nil}) == 0
      assert Ops.nonempty_flag(nil) == 0
      # Defensive: a non-binary "spill" is not a marker — falls to the v/f rule.
      assert Ops.nonempty_flag(%{"v" => 7, "spill" => true}) == 1
    end

    test "count_nonempty counts the anchor + user cells but not the spilled region" do
      content = %{
        "tabs" => [
          %{
            "cells" => %{
              # anchor + two engine-owned spilled cells (the array =SORT(C1:C3))
              "A1" => spill_anchor("=SORT(C1:C3)", 3),
              "A2" => spilled(5),
              "A3" => spilled(9),
              # the source data (real user cells)
              "C1" => %{"v" => 9},
              "C2" => %{"v" => 5},
              "C3" => %{"v" => 3}
            }
          }
        ]
      }

      # anchor(1) + C1/C2/C3(3) = 4 user cells; A2/A3 (spilled) contribute 0.
      assert Ops.count_nonempty(content) == 4
    end

    test "a spilled region does not consume the cell-cap budget as N user cells" do
      put_cfg(cell_cap: 2)
      # Anchor (1 user cell) + two engine-owned spilled cells. Under the pre-seam
      # accounting the session would boot at nonempty=3 — already over the cap of
      # 2 — and reject the very first user write. With the seam it boots at 1.
      # The anchor formula is trivial + dependency-free so the first op's
      # recompute is deterministic and preserves the markers (write_value only
      # touches v/t).
      create_sheet("sp-cap", %{
        "A1" => spill_anchor("=SEQUENCE(3)", 1),
        "A2" => spilled(0),
        "A3" => spilled(0)
      })

      # One more USER cell lands (anchor=1 + this=2 == cap).
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("sp-cap", @dataset, [set_cell("E1", "user")])

      # The next user cell is over the cap — only USER content is budgeted, so
      # the two spilled cells never counted.
      {:ok, %{applied: 0, errors: [%{index: 0, code: "cell_cap_exceeded"}]}} =
        Session.apply_ops("sp-cap", @dataset, [set_cell("E2", "user2")])

      # And the seeded markers survived recompute — the anchor is still a marked
      # formula (counts 1), the spilled cells still excluded.
      {:ok, content} = Session.peek("sp-cap", @dataset)
      assert Ops.count_nonempty(content) == 2
      assert get_in(content, ["tabs", Access.at(0), "cells", "A1", "spill"]) == "A1"
      assert get_in(content, ["tabs", Access.at(0), "cells", "A2", "spill"]) == "A1"
    end

    test "the coalesced delta carries a vacated position as nil (the diff rail a shrunk spill rides)" do
      # When S1's recompute shrinks/vacates a region it REMOVES the now-empty
      # positions from the cells map; the session surfaces them through the
      # ordinary captured-prior-vs-recomputed diff as `nil`. Lock that rail here
      # without depending on the engine to spill: a batch that removes a seeded
      # cell must nil it in the ONE coalesced delta, alongside written cells.
      doc = create_sheet("sp-vacate", %{"A2" => %{"v" => "stale"}, "B1" => %{"f" => "=1+1"}})

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("sp-vacate", @dataset, doc.workspace_id)
      )

      {:ok, %{applied: 2}} =
        Session.apply_ops("sp-vacate", @dataset, [set_cell("C1", 7), clear_cell("A2")])

      assert_receive {:sheets_op, %{tab: 0, changed: changed}}, 1_000
      assert changed["C1"] == %{"v" => 7}
      # Vacated position — present in the delta, as nil (so a client CLEARS it),
      # not merely absent.
      assert Map.has_key?(changed, "A2")
      assert changed["A2"] == nil
    end

    test "undo of an anchor edit restores the prior anchor + recomputes — no new inverse shape" do
      # The anchor edit's inverse is the ordinary {:cell, tab, ref, prior}. Undo
      # restores the prior (marker-bearing) anchor cell and recomputes the tab;
      # the region re-derives from the restored anchor. Spilled cells carry no
      # individual inverse — recompute reconstructs them (design §3.3 undo).
      anchor = spill_anchor("=SEQUENCE(3)", 1)

      create_sheet("sp-undo", %{
        "A1" => anchor,
        "A2" => spilled(0),
        "A3" => spilled(0),
        # a reader of the anchor's top-left proves recompute runs on undo
        "D1" => %{"f" => "=A1"}
      })

      # Boot + settle the reader.
      {:ok, %{applied: 1}} = Session.apply_ops("sp-undo", @dataset, [set_cell("Z1", 0, 0)])
      assert peek_cell("sp-undo", "D1") == %{"f" => "=A1", "v" => 1, "t" => "n"}

      # Edit the anchor to a plain scalar — the formula + markers drop (set_cell
      # carries only fmt/s from the prior cell, never "spill").
      {:ok, %{applied: 1}} =
        Session.apply_ops("sp-undo", @dataset, [
          %{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => 42, "user" => "u1"}
        ])

      # A scalar set_cell stores just "v" (no "t" — the engine only stamps "t"
      # on formula cells); the anchor is now a plain, unmarked user cell.
      assert peek_cell("sp-undo", "A1") == %{"v" => 42}
      assert peek_cell("sp-undo", "D1") == %{"f" => "=A1", "v" => 42, "t" => "n"}

      # Undo: the ordinary cell inverse restores the FULL prior anchor (formula +
      # "spill" + "spill_dims") and recomputes — D1 re-derives to the anchor's
      # value. No per-spilled-cell inverse was needed.
      {:ok, %{applied: 1}} =
        Session.apply_ops("sp-undo", @dataset, [%{"op" => "undo", "user" => "u1"}])

      assert peek_cell("sp-undo", "A1") == anchor
      assert peek_cell("sp-undo", "D1") == %{"f" => "=A1", "v" => 1, "t" => "n"}
    end

    test "duplicate_tab's cap check counts only the source's USER cells, not its spilled region" do
      # duplicate_tab pre-checks `tab_nonempty(src_cells)` against the session
      # total (ops.ex:429) — the ONE cap path that does not route through
      # check_cap/apply_cell. It inherits the seam through the shared
      # `nonempty_flag`, so duplicating a spill-bearing sheet budgets only the
      # user cells (anchor + real data), never the engine-owned spilled cells.
      put_cfg(cell_cap: 4)

      # Source: anchor A1 (user, 1) + B1 (user, 1) = 2 user cells; A2/A3 are
      # engine-owned spilled output (0). Under the pre-seam count the source
      # would read as 4 (the two spilled cells inflating it) and the session
      # would boot at 4 == cap, so the duplicate (→ 8) would be refused. With the
      # seam the source counts 2, the session boots at 2, and the copy fits (→ 4).
      create_multi_tab("sp-dup", [
        %{
          "name" => "Arr",
          "cells" => %{
            "A1" => spill_anchor("=SEQUENCE(3)", 1),
            "A2" => spilled(5),
            "A3" => spilled(9),
            "B1" => %{"v" => "keep"}
          }
        }
      ])

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("sp-dup", @dataset, [%{"op" => "duplicate_tab", "tab" => 0}])

      {:ok, content} = Session.peek("sp-dup", @dataset)
      assert length(content["tabs"]) == 2
      # Both tabs together: 2 user cells each, the spilled region excluded → 4.
      assert Ops.count_nonempty(content) == 4
      # The copy carried the anchor's marker verbatim (deep-copy of the tab map).
      assert get_in(content, ["tabs", Access.at(1), "cells", "A1", "spill"]) == "A1"
    end
  end

  defp ct_tab(name, cells), do: %{"name" => name, "cells" => cells}

  defp cross_tab_formula(slug, tab, ref) do
    {:ok, content} = Session.peek(slug, @dataset)
    get_in(content, ["tabs", Access.at(tab), "cells", ref, "f"])
  end

  # ── per-gesture group undo (QL-D4) ──────────────────────────────────────────
  #
  # One `apply_ops` batch pushes ONE undo entry per user: a `{:group, …}` when
  # the batch yielded ≥2 inverses for that user, a bare inverse when exactly 1.
  # So a >100-cell paste undoes as a single step and `@undo_depth` counts
  # ENTRIES, not cells.
  describe "per-gesture group undo (QL-D4)" do
    test "a multi-cell paste in one batch undoes and redoes as a single group step" do
      create_sheet("grp-paste", %{})

      ops = [
        set_cell_by("u1", "A1", 1),
        set_cell_by("u1", "A2", 2),
        set_cell_by("u1", "A3", 3)
      ]

      {:ok, %{applied: 3, errors: []}} = Session.apply_ops("grp-paste", @dataset, ops)
      assert peek_cell("grp-paste", "A1") == %{"v" => 1}
      assert peek_cell("grp-paste", "A2") == %{"v" => 2}
      assert peek_cell("grp-paste", "A3") == %{"v" => 3}

      # ONE undo reverts all three cells.
      {:ok, %{applied: 1}} =
        Session.apply_ops("grp-paste", @dataset, [%{"op" => "undo", "user" => "u1"}])

      assert peek_cell("grp-paste", "A1") == nil
      assert peek_cell("grp-paste", "A2") == nil
      assert peek_cell("grp-paste", "A3") == nil

      # ONE redo re-applies all three.
      {:ok, %{applied: 1}} =
        Session.apply_ops("grp-paste", @dataset, [%{"op" => "redo", "user" => "u1"}])

      assert peek_cell("grp-paste", "A1") == %{"v" => 1}
      assert peek_cell("grp-paste", "A2") == %{"v" => 2}
      assert peek_cell("grp-paste", "A3") == %{"v" => 3}
    end

    test "a same-cell double write in one batch: undo blanks it, redo replays FORWARD to the last write" do
      create_sheet("grp-order", %{})

      # Two writes to the SAME cell in one batch — the order case: redo must
      # land on the batch's LAST write (2), not an intermediate value.
      ops = [set_cell_by("u1", "A1", 1), set_cell_by("u1", "A1", 2)]
      {:ok, %{applied: 2, errors: []}} = Session.apply_ops("grp-order", @dataset, ops)
      assert peek_cell("grp-order", "A1") == %{"v" => 2}

      {:ok, _} = Session.apply_ops("grp-order", @dataset, [%{"op" => "undo", "user" => "u1"}])
      assert peek_cell("grp-order", "A1") == nil

      {:ok, _} = Session.apply_ops("grp-order", @dataset, [%{"op" => "redo", "user" => "u1"}])
      assert peek_cell("grp-order", "A1") == %{"v" => 2}
    end

    test "a 150-cell paste is ONE entry — it outlives a 100-deep stack and reverts whole" do
      create_sheet("grp-depth", %{})

      paste = for i <- 1..150, do: set_cell_by("u1", "A#{i}", i)
      {:ok, %{applied: 150, errors: []}} = Session.apply_ops("grp-depth", @dataset, paste)

      # Five later single edits, each its own batch (⇒ its own stack entry).
      for c <- 1..5 do
        {:ok, %{applied: 1}} =
          Session.apply_ops("grp-depth", @dataset, [set_cell_by("u1", "C#{c}", c)])
      end

      # Undo the five single edits first.
      for _ <- 1..5 do
        {:ok, %{applied: 1}} =
          Session.apply_ops("grp-depth", @dataset, [%{"op" => "undo", "user" => "u1"}])
      end

      assert peek_cell("grp-depth", "A1") == %{"v" => 1}
      assert peek_cell("grp-depth", "A150") == %{"v" => 150}

      # ONE more undo reverts the ENTIRE 150-cell paste. Under per-cell
      # recording the paste's first 55 cells would have been truncated off the
      # 100-deep stack and could never revert — this is the QL-D4 fix.
      {:ok, %{applied: 1}} =
        Session.apply_ops("grp-depth", @dataset, [%{"op" => "undo", "user" => "u1"}])

      assert peek_cell("grp-depth", "A1") == nil
      assert peek_cell("grp-depth", "A75") == nil
      assert peek_cell("grp-depth", "A150") == nil
    end

    test "a LONE single edit undoes/redoes byte-identically — no group wrapper (regression lock)" do
      create_sheet("grp-lone", %{"A1" => %{"v" => "orig"}})

      {:ok, %{applied: 1}} =
        Session.apply_ops("grp-lone", @dataset, [set_cell_by("u1", "A1", "edited")])

      assert peek_cell("grp-lone", "A1") == %{"v" => "edited"}

      {:ok, _} = Session.apply_ops("grp-lone", @dataset, [%{"op" => "undo", "user" => "u1"}])
      assert peek_cell("grp-lone", "A1") == %{"v" => "orig"}

      {:ok, _} = Session.apply_ops("grp-lone", @dataset, [%{"op" => "redo", "user" => "u1"}])
      assert peek_cell("grp-lone", "A1") == %{"v" => "edited"}
    end

    test "a mixed-user batch records one entry per user; each undoes only their own cells" do
      create_sheet("grp-multi", %{})

      ops = [
        set_cell_by("u1", "A1", 1),
        set_cell_by("u2", "B1", 2),
        set_cell_by("u1", "A2", 3)
      ]

      {:ok, %{applied: 3, errors: []}} = Session.apply_ops("grp-multi", @dataset, ops)

      # u1's undo reverts u1's two cells (their group), leaving u2's cell.
      {:ok, _} = Session.apply_ops("grp-multi", @dataset, [%{"op" => "undo", "user" => "u1"}])
      assert peek_cell("grp-multi", "A1") == nil
      assert peek_cell("grp-multi", "A2") == nil
      assert peek_cell("grp-multi", "B1") == %{"v" => 2}

      # u2's undo reverts u2's single (bare) inverse.
      {:ok, _} = Session.apply_ops("grp-multi", @dataset, [%{"op" => "undo", "user" => "u2"}])
      assert peek_cell("grp-multi", "B1") == nil
    end

    test "an anonymous batch (no \"user\") records nothing — undo finds an empty stack" do
      create_sheet("grp-anon", %{})

      {:ok, %{applied: 2, errors: []}} =
        Session.apply_ops("grp-anon", @dataset, [set_cell("A1", 1), set_cell("A2", 2)])

      {:ok, %{applied: 0, errors: [%{index: 0, code: "nothing_to_undo"}]}} =
        Session.apply_ops("grp-anon", @dataset, [%{"op" => "undo", "user" => "u1"}])
    end
  end

  # ── set_tab_color op (QL-D2/D3) ─────────────────────────────────────────────
  #
  # A per-tab `"color"` (#rrggbb or absent), set live via an undoable, broadcast
  # session op. The inverse reuses `{:structural, op_map}` (a set_tab_color back
  # to the prior color; nil ⇒ clears the key).
  describe "set_tab_color op (QL-D2/D3)" do
    test "sets a normalized color; undo restores the prior; redo re-applies" do
      create_multi_tab("tc-set", [
        %{"name" => "A", "cells" => %{}, "color" => "#0000ff"},
        %{"name" => "B", "cells" => %{}}
      ])

      # Case-insensitive in, stored lowercase.
      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("tc-set", @dataset, [
          %{"op" => "set_tab_color", "tab" => 0, "color" => "#FF0000", "user" => "u1"}
        ])

      assert tab_color("tc-set", 0) == "#ff0000"

      {:ok, _} = Session.apply_ops("tc-set", @dataset, [%{"op" => "undo", "user" => "u1"}])
      assert tab_color("tc-set", 0) == "#0000ff"

      {:ok, _} = Session.apply_ops("tc-set", @dataset, [%{"op" => "redo", "user" => "u1"}])
      assert tab_color("tc-set", 0) == "#ff0000"
    end

    test "undo of a first-time set CLEARS the key (no phantom empty color)" do
      create_sheet("tc-clear", %{})

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("tc-clear", @dataset, [
          %{"op" => "set_tab_color", "tab" => 0, "color" => "#123456", "user" => "u1"}
        ])

      assert tab_color("tc-clear") == "#123456"

      {:ok, _} = Session.apply_ops("tc-clear", @dataset, [%{"op" => "undo", "user" => "u1"}])
      refute Map.has_key?(tab_map("tc-clear"), "color")
    end

    test "an empty-string color clears the key" do
      create_multi_tab("tc-empty", [%{"name" => "A", "cells" => %{}, "color" => "#abcdef"}])

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("tc-empty", @dataset, [
          %{"op" => "set_tab_color", "tab" => 0, "color" => "", "user" => "u1"}
        ])

      refute Map.has_key?(tab_map("tc-empty"), "color")
    end

    test "a junk color is rejected at the op boundary and never lands" do
      create_sheet("tc-bad", %{})

      {:ok, %{applied: 0, errors: [%{index: 0, code: "invalid_color"}]}} =
        Session.apply_ops("tc-bad", @dataset, [
          %{"op" => "set_tab_color", "tab" => 0, "color" => "#gggggg", "user" => "u1"}
        ])

      refute Map.has_key?(tab_map("tc-bad"), "color")

      # A trailing-newline stowaway is rejected too (sanitize_bg is \z-anchored).
      {:ok, %{applied: 0, errors: [%{index: 0, code: "invalid_color"}]}} =
        Session.apply_ops("tc-bad", @dataset, [
          %{"op" => "set_tab_color", "tab" => 0, "color" => "#ff0000\n", "user" => "u1"}
        ])
    end

    test "an unknown tab rejects" do
      create_sheet("tc-notab", %{})

      {:ok, %{applied: 0, errors: [%{index: 0, code: "tab_not_found"}]}} =
        Session.apply_ops("tc-notab", @dataset, [
          %{"op" => "set_tab_color", "tab" => 9, "color" => "#ff0000", "user" => "u1"}
        ])
    end

    test "broadcasts a set_tab_color structure delta so peers repaint the tab" do
      doc = create_multi_tab("tc-bcast", [%{"name" => "A", "cells" => %{}}])

      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Session.topic("tc-bcast", @dataset, doc.workspace_id)
      )

      {:ok, %{applied: 1, errors: []}} =
        Session.apply_ops("tc-bcast", @dataset, [
          %{"op" => "set_tab_color", "tab" => 0, "color" => "#00aa00", "user" => "u1"}
        ])

      assert_receive {:sheets_op, %{structure: %{op: "set_tab_color", tab: 0}}}, 1_000
    end
  end
end
