defmodule Barkpark.Plugins.Sheets.CondFormatSeamTest do
  @moduledoc """
  The gate ↔ kernel ↔ save-path seam for conditional formatting — pure, no DB,
  no app boot. Closes the two CF-1 caveats the file-disjoint CF-A/CF-B slices
  left open:

    * **caveat 1 — gate-accepted ⊆ parse_rules-accepted.** Nothing pinned that a
      rule the STRICT `before_save` gate (CF-B) accepts is also KEPT by the
      LENIENT `CondFormat.parse_rules/1` (CF-A). A gate-valid rule that
      `parse_rules/1` silently dropped would store fine and then be a no-op on
      every surface. For every gate-accepted CF-D9 fixture row we assert the
      subset property AND that `matches?/2`/`style_for/3` agree with the row's
      recorded `expect` against the row's cell.
    * **caveat 6 — the end-to-end save path.** No test flowed a gate-valid doc
      through the real `before_save` hook into a snapshot. We drive
      `before_save` (accepted) → `Core.snapshot_for/2` and assert the snapshot
      `"styles"` map carries the composed style for a matched OCCUPIED cell and
      nothing for an unmatched or blank one (CF-D8).

  The CF-D9 fixture (`sheet-cond-format-eval.json`) is the contract (CF-D5); it
  is reused VERBATIM here (CF-D9) — never edited.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.CondFormat
  alias Barkpark.Plugins.Sheets.Core

  @fixture_path Path.expand(
                  "../../../support/fixtures/sheet-cond-format-eval.json",
                  __DIR__
                )
  @fixture @fixture_path |> File.read!() |> Jason.decode!()

  # Drive the STRICT CF-B gate exactly as the pure gate test does: the
  # before_save lifecycle hook is a one-element list; call it directly on a
  # sheet doc carrying the given content. Returns :ok | {:halt, msg}.
  defp gate_content(content) do
    [hook] = Barkpark.Plugins.Sheets.lifecycle_hooks().before_save
    hook.(%{doc: %{"type" => "sheet", "content" => content}})
  end

  # Rules-only shorthand for the seam loop: one tab, just the rule list.
  defp gate(cond_formats),
    do: gate_content(%{"tabs" => [%{"cond_formats" => cond_formats}]})

  # A full storable rule around a fixture row's `when`, ranged to a single cell
  # (B2 == col 2, row 2) so `style_for/3` can be probed at {2, 2}.
  defp rule_of(row, id) do
    when_map =
      %{"op" => row["op"], "value" => row["value"]}
      |> then(fn m ->
        if Map.has_key?(row, "value2"), do: Map.put(m, "value2", row["value2"]), else: m
      end)

    %{"id" => id, "range" => "B2", "when" => when_map, "style" => %{"bg" => "#ff0000"}}
  end

  describe "gate-accepted ⊆ parse_rules-accepted (CF-1 caveat 1)" do
    test "every gate-accepted fixture row is KEPT by parse_rules and evals as specified" do
      {accepted, rejected} =
        @fixture["rows"]
        |> Enum.with_index()
        |> Enum.reduce({0, 0}, fn {row, i}, {acc, rej} ->
          rule = rule_of(row, "seam-#{i}")
          cell = row["cell"]
          expect = row["expect"]
          when_map = rule["when"]

          case gate([rule]) do
            :ok ->
              # THE SEAM: a gate-accepted rule must survive the lenient kernel.
              parsed = CondFormat.parse_rules([rule])

              assert length(parsed) == 1,
                     "gate accepted but parse_rules dropped it (silent no-op): " <>
                       "#{inspect(row["desc"])}"

              # Kernel eval agrees with the fixture's recorded expectation …
              assert CondFormat.matches?(when_map, cell) == expect,
                     "matches?/2 disagrees with fixture expect for #{inspect(row["desc"])}"

              # … and the composed style_for at the ranged cell mirrors it.
              style_for = CondFormat.style_for(parsed, {2, 2}, cell)

              if expect do
                assert style_for == %{"bg" => "#ff0000"},
                       "expected a match style for #{inspect(row["desc"])}"
              else
                assert style_for == nil,
                       "expected no style for #{inspect(row["desc"])}"
              end

              {acc + 1, rej}

            {:halt, _msg} ->
              # Rows the gate rejects are the deliberate eval-leniency cases
              # (mistyped rule values, unknown op) — not part of the subset
              # property. They stay in the fixture to pin kernel totality.
              {acc, rej + 1}
          end
        end)

      # Vacuity floors: the loop must actually exercise the seam on a broad set
      # of accepted rules, and the fixture must still carry its gate-rejected
      # leniency rows.
      assert accepted >= 40,
             "only #{accepted} rows were gate-accepted — the seam loop went thin"

      assert rejected >= 5,
             "only #{rejected} rows were gate-rejected — the leniency rows vanished"
    end
  end

  describe "end-to-end save path: before_save → snapshot_for (CF-1 caveat 6)" do
    # One tab, no frozen head (data_start = 1 → keys are "row-1,col-1"), a manual
    # style on the matched cell to also pin compose in the real projection.
    @content %{
      "tabs" => [
        %{
          "name" => "Data",
          "cells" => %{
            # A1 numeric above threshold, manually left-aligned.
            "A1" => %{"v" => 150, "t" => "n", "s" => %{"al" => "left"}},
            # A2 numeric below threshold — occupied but unmatched.
            "A2" => %{"v" => 50, "t" => "n"},
            # A3 text — occupied, wrong class for gt.
            "A3" => %{"v" => "plain"}
            # A4..A10 blank (no cell) — never matched (CF-D8 occupied-only).
          },
          "cond_formats" => [
            %{
              "id" => "e2e-gt",
              "range" => "A1:A10",
              "when" => %{"op" => "gt", "value" => 100},
              "style" => %{"bg" => "#00ff00"}
            }
          ]
        }
      ]
    }

    test "the gate accepts the doc" do
      # The FULL content (cells AND rules) — the very doc snapshot_for consumes
      # below is the one the gate admits, not just its rule list.
      assert gate_content(@content) == :ok
    end

    test "the snapshot styles map carries the composed style for the matched cell only" do
      styles = Core.snapshot_for(@content, 0)["styles"]

      # A1 (150 > 100) matches: CF wins `bg`, the manual `al` survives (CF-D3).
      # No frozen head → A1 is body key "0,0".
      assert styles["0,0"] == %{"al" => "left", "bg" => "#00ff00"}

      # A2 (50) is occupied but below threshold — no entry.
      refute Map.has_key?(styles, "1,0")

      # A3 (text) is occupied, wrong class — no entry.
      refute Map.has_key?(styles, "2,0")

      # Blank cells in the range (A4..A10) never earn an entry (CF-D8): the ONLY
      # key is the single matched cell.
      assert map_size(styles) == 1
    end
  end
end
