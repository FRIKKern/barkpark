defmodule BarkparkWeb.Studio.ChatShowActiveOnlyTest do
  @moduledoc """
  SHOW-ACTIVE-ONLY, unit half (task-b66928b2958c8cfa).

  While a turn is RUNNING the transcript keeps the ACTIVE tool row on screen and
  folds the rows BEFORE it behind one `+N previous` control, so a long turn can
  no longer scroll away the thing the reader is watching. U1
  (task-8f904a88b9bc3d59) owns the SETTLED half and is not touched here.

  This suite owns the parts that need no LiveView:

    * the RULE — `ChatToolRenderer.active_row_index/1`: the active row is the
      first row still awaiting its `tool_result`, or the last row when every
      result already landed;
    * the COUNT + the LABEL — byte-locked to the Go surface by the SHARED
      fixture `test/support/fixtures/chat_fold_labels.json` (`running_cases`),
      which `internal/chat/running_fold_test.go` reads too. Change one surface's
      counter or wording and the OTHER surface reds;
    * the GROUPING — `ChatLive.fold_running_turn/1`, the pass that turns a
      running turn's consecutive rows into one control plus the active row.

  The LiveView half (collapse, expand on click, re-collapse, settled unaffected)
  lives in `chat_live_test.exs`'s own show-active-only describe.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.ChatLive
  alias BarkparkWeb.Studio.ChatToolRenderer

  @label_fixture Path.expand("../../../support/fixtures/chat_fold_labels.json", __DIR__)

  defp running_cases do
    @label_fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("running_cases")
  end

  # One tool row of a RUNNING turn: no settle stamp, so U1's fold can never
  # claim it. An EMPTY output is a row whose tool_result has not landed.
  defp live_row(id, output),
    do: %{id: id, role: :tool, turn_settled: false, output: output}

  # ── the shared count + label lock ───────────────────────────────────────────

  describe "running_hidden_count/1 + running_fold_label/1 against the SHARED fixture" do
    test "every running case matches — the count AND the control's wording" do
      cases = running_cases()

      # A vacuous lock proves nothing: the fixture must actually carry cases.
      assert length(cases) >= 3

      for c <- cases do
        rows =
          c["row_outputs"] |> Enum.with_index(1) |> Enum.map(fn {out, i} -> live_row(i, out) end)

        n = ChatToolRenderer.running_hidden_count(rows)

        assert n == c["hidden"],
               "#{c["case"]}: running_hidden_count = #{n}, fixture says #{c["hidden"]}"

        case c["control"] do
          nil ->
            assert n == 0, "#{c["case"]}: a case with no control must hide nothing"

          control ->
            assert ChatToolRenderer.running_fold_label(n) == control,
                   "#{c["case"]}: the control must read #{control}, got #{ChatToolRenderer.running_fold_label(n)}"
        end
      end
    end

    test "the fixture still carries the three shapes the contract names" do
      # Non-vacuity in the other direction: a future edit cannot quietly delete
      # the 1-row turn, the N=3 turn, or the active-is-first turn and leave the
      # lock above passing over whatever remains.
      cases = running_cases()
      hidden = Enum.map(cases, & &1["hidden"])
      lengths = Enum.map(cases, &length(&1["row_outputs"]))

      assert 3 in hidden, "the fixture must keep an N=3 case"
      assert 0 in hidden, "the fixture must keep an N=0 case"
      assert 1 in lengths, "the fixture must keep a 1-row turn"

      assert Enum.any?(cases, fn c ->
               length(c["row_outputs"]) > 1 and Enum.all?(c["row_outputs"], &(&1 == ""))
             end),
             "the fixture must keep a turn whose ACTIVE row is its FIRST row"
    end
  end

  # ── the rule the count is built on ──────────────────────────────────────────

  describe "active_row_index/1 — which row is the one in flight" do
    test "the first row still awaiting its result is the active one" do
      rows = [live_row(1, "ok"), live_row(2, "ok"), live_row(3, "ok"), live_row(4, nil)]
      assert ChatToolRenderer.active_row_index(rows) == 3
      assert ChatToolRenderer.running_hidden_count(rows) == 3
    end

    test "with parallel calls and nothing landed, the FIRST row is active and nothing hides" do
      rows = [live_row(1, nil), live_row(2, nil), live_row(3, nil)]
      assert ChatToolRenderer.active_row_index(rows) == 0
      assert ChatToolRenderer.running_hidden_count(rows) == 0
    end

    test "an empty result string counts as awaiting — the same test settle_state makes" do
      assert ChatToolRenderer.active_row_index([live_row(1, "ok"), live_row(2, "")]) == 1
    end

    test "every result landed but the turn still runs — the LAST row is active" do
      assert ChatToolRenderer.active_row_index([live_row(1, "ok"), live_row(2, "ok")]) == 1
    end

    test "a one-row turn and an empty run index nothing off the end" do
      assert ChatToolRenderer.active_row_index([live_row(1, nil)]) == 0
      assert ChatToolRenderer.active_row_index([]) == 0
      assert ChatToolRenderer.running_hidden_count([]) == 0
    end
  end

  # ── the grouping pass ───────────────────────────────────────────────────────

  describe "fold_running_turn/1 — one control per running turn" do
    defp row(id, opts) do
      {:row, Map.merge(%{id: id, role: :tool, turn_settled: false, output: nil}, Map.new(opts))}
    end

    test "a running turn collapses to ONE control plus the active row" do
      items = [
        row(1, output: "ok"),
        row(2, output: "ok"),
        row(3, output: "ok"),
        row(4, output: nil)
      ]

      assert [{:running_fold, 3, "+3 previous", hidden, [%{id: 4}]}] =
               ChatLive.fold_running_turn(items)

      assert Enum.map(hidden, & &1.id) == [1, 2, 3]
    end

    test "a turn that hides nothing keeps its flat rows and gets NO control" do
      # A 1-row turn…
      one = [row(1, output: nil)]
      assert ChatLive.fold_running_turn(one) == one

      # …and a turn whose ACTIVE row is its first row.
      parallel = [row(1, output: nil), row(2, output: nil), row(3, output: nil)]
      assert ChatLive.fold_running_turn(parallel) == parallel
    end

    test "a SETTLED turn passes through untouched — the running gate is U1's fence" do
      # THE MUTATION TARGET. Remove the "this turn has not settled" gate from
      # `running_run_key/1` and these settled rows collapse to their active row
      # here, losing the fold-on-settle header U1 owns.
      settled = [
        turn_settled: true,
        turn_settled_at: "t1",
        turn_outcome: "settled",
        turn_duration_ms: 192_000,
        output: "ok"
      ]

      items = [row(1, settled), row(2, settled), row(3, settled)]
      assert ChatLive.fold_running_turn(items) == items

      # And the whole pipeline still hands them to U1's fold, with its label.
      assert [{:turn_fold, "t1", "Worked for 3m 12s", rows}] =
               items |> ChatLive.fold_running_turn() |> ChatLive.fold_settled_turns()

      assert length(rows) == 3
    end

    test "a SETTLED row the server never stamped stays FLAT — not folded either way" do
      # U1's forward-compatible degrade: `turn_settled` with no `turn_settled_at`
      # cannot fold on settle, and it must not fall through to the RUNNING
      # collapse instead. The gate is `turn_settled`, never the fold key.
      items = [
        row(1, turn_settled: true, output: "ok"),
        row(2, turn_settled: true, output: "ok"),
        row(3, turn_settled: true, output: nil)
      ]

      assert ChatLive.fold_running_turn(items) == items
      assert items |> ChatLive.fold_running_turn() |> ChatLive.fold_settled_turns() == items
    end

    test "a non-tool row BREAKS the run — two running folds, never one merged" do
      items = [
        row(1, output: "ok"),
        row(2, output: nil),
        {:row, %{id: 3, role: :assistant}},
        row(4, output: "ok"),
        row(5, output: nil)
      ]

      assert [
               {:running_fold, 1, "+1 previous", [%{id: 1}], [%{id: 2}]},
               {:row, %{role: :assistant}},
               {:running_fold, 1, "+1 previous", [%{id: 4}], [%{id: 5}]}
             ] = ChatLive.fold_running_turn(items)
    end

    test "a D46 agent block BREAKS the run too" do
      items = [
        row(1, output: "ok"),
        row(2, output: nil),
        {:agent, %{id: 3, role: :tool, tool_use_id: "spawn"}, []},
        row(4, output: "ok"),
        row(5, output: nil)
      ]

      assert [
               {:running_fold, 1, _, _, _},
               {:agent, _, []},
               {:running_fold, 1, _, _, _}
             ] = ChatLive.fold_running_turn(items)
    end

    test "an empty transcript folds to nothing" do
      assert ChatLive.fold_running_turn([]) == []
    end
  end
end
