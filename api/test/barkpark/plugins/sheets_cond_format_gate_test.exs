defmodule Barkpark.Plugins.SheetsCondFormatGateTest do
  @moduledoc """
  Pure locks for the Sheets `before_save` conditional-formatting gate
  (CF-D6). Drives the lifecycle hook DIRECTLY — no DB, no DataCase (the
  DB-bound `sheets_validation_test.exs` is off-limits as a gate) — asserting
  `:ok` for well-formed rules and `{:halt, msg}` for every strictness
  violation: op whitelist + per-op value typing, unknown keys anywhere in
  the rule / `when` / `style`, a required `#rrggbb` `bg`, `b`/`i` literal
  true, non-empty unique `id`, single-A1-or-A1:B2 in-bounds `range`,
  single-rule-per-normalized-range, and the 200-rule cap.
  """
  use ExUnit.Case, async: true

  # The before_save hook is a one-element list (see lifecycle_hooks/0).
  defp hook do
    [hook] = Barkpark.Plugins.Sheets.lifecycle_hooks().before_save
    hook
  end

  defp run_doc(doc), do: hook().(%{doc: doc})

  # Drive the gate over a single tab carrying `cond_formats` (a list, or an
  # arbitrary term for the not-a-list case).
  defp run_cfs(cond_formats) do
    run_doc(%{"type" => "sheet", "content" => %{"tabs" => [%{"cond_formats" => cond_formats}]}})
  end

  defp run_rule(overrides), do: run_cfs([rule(overrides)])

  defp rule(overrides) do
    Map.merge(
      %{
        "id" => "r1",
        "range" => "B2",
        "when" => %{"op" => "gt", "value" => 100},
        "style" => %{"bg" => "#ff0000"}
      },
      overrides
    )
  end

  # ── valid rules ─────────────────────────────────────────────────────────

  test "a valid single-cell gt rule passes" do
    assert run_rule(%{}) == :ok
  end

  test "a valid between rule with value + value2 passes" do
    assert run_rule(%{"when" => %{"op" => "between", "value" => 1, "value2" => 10}}) == :ok
  end

  test "eq accepts number, non-empty string, and boolean" do
    assert run_rule(%{"when" => %{"op" => "eq", "value" => 42}}) == :ok
    assert run_rule(%{"when" => %{"op" => "eq", "value" => "hello"}}) == :ok
    assert run_rule(%{"when" => %{"op" => "eq", "value" => true}}) == :ok
  end

  test "contains accepts a non-empty string" do
    assert run_rule(%{"when" => %{"op" => "contains", "value" => "abc"}}) == :ok
  end

  test "an A1:B2 range (any corner order) and optional b/i true pass" do
    assert run_rule(%{
             "range" => "D9:B2",
             "style" => %{"bg" => "#00FF00", "b" => true, "i" => true}
           }) ==
             :ok
  end

  test "a sheet with no cond_formats passes" do
    assert run_doc(%{"type" => "sheet", "content" => %{"tabs" => [%{"cells" => %{}}]}}) == :ok
  end

  test "a non-sheet document passes untouched" do
    assert run_doc(%{"type" => "post", "content" => %{"tabs" => "whatever"}}) == :ok
  end

  # ── op whitelist + per-op typing ────────────────────────────────────────

  test "an unknown op is rejected" do
    assert {:halt, msg} = run_rule(%{"when" => %{"op" => "wat", "value" => 1}})
    assert msg =~ "gt|lt|eq|between|contains"
  end

  test "gt/lt require a numeric value" do
    assert {:halt, _} = run_rule(%{"when" => %{"op" => "gt", "value" => "x"}})
    assert {:halt, _} = run_rule(%{"when" => %{"op" => "lt", "value" => "x"}})
  end

  test "value2 is forbidden for every op except between" do
    assert {:halt, m1} = run_rule(%{"when" => %{"op" => "gt", "value" => 1, "value2" => 2}})
    assert m1 =~ "value2 is not allowed"
    assert {:halt, _} = run_rule(%{"when" => %{"op" => "eq", "value" => 1, "value2" => 2}})

    assert {:halt, _} =
             run_rule(%{"when" => %{"op" => "contains", "value" => "a", "value2" => 2}})
  end

  test "between requires value2" do
    assert {:halt, msg} = run_rule(%{"when" => %{"op" => "between", "value" => 1}})
    assert msg =~ "value2 is required"
  end

  test "between requires both value and value2 numeric" do
    assert {:halt, _} =
             run_rule(%{"when" => %{"op" => "between", "value" => "x", "value2" => 10}})

    assert {:halt, _} = run_rule(%{"when" => %{"op" => "between", "value" => 1, "value2" => "y"}})
  end

  test "eq rejects an empty string and a nil value" do
    assert {:halt, _} = run_rule(%{"when" => %{"op" => "eq", "value" => ""}})
    assert {:halt, _} = run_rule(%{"when" => %{"op" => "eq", "value" => nil}})
  end

  test "contains rejects a non-string / empty-string value" do
    assert {:halt, _} = run_rule(%{"when" => %{"op" => "contains", "value" => 5}})
    assert {:halt, _} = run_rule(%{"when" => %{"op" => "contains", "value" => ""}})
  end

  # ── style ───────────────────────────────────────────────────────────────

  test "a missing bg is rejected" do
    assert {:halt, msg} = run_rule(%{"style" => %{"b" => true}})
    assert msg =~ "style.bg is required"
  end

  test "an invalid bg is rejected" do
    assert {:halt, _} = run_rule(%{"style" => %{"bg" => "red"}})
    assert {:halt, _} = run_rule(%{"style" => %{"bg" => "#ff00"}})
    assert {:halt, _} = run_rule(%{"style" => %{"bg" => "#ff00zz"}})
    assert {:halt, _} = run_rule(%{"style" => %{"bg" => 123}})
  end

  test "a bg with a trailing newline is rejected (\\z anchor, not $)" do
    assert {:halt, _} = run_rule(%{"style" => %{"bg" => "#ff0000\n"}})
  end

  test "b/i must be literal true when present" do
    assert {:halt, _} = run_rule(%{"style" => %{"bg" => "#ff0000", "b" => false}})
    assert {:halt, _} = run_rule(%{"style" => %{"bg" => "#ff0000", "i" => "yes"}})
  end

  # ── unknown / missing keys ──────────────────────────────────────────────

  test "an unknown key in the rule is rejected" do
    assert {:halt, msg} = run_rule(%{"priority" => 1})
    assert msg =~ "unknown key"
  end

  test "an unknown key in when is rejected" do
    assert {:halt, msg} = run_rule(%{"when" => %{"op" => "gt", "value" => 1, "extra" => 2}})
    assert msg =~ "unknown key"
  end

  test "an unknown key in style is rejected" do
    assert {:halt, msg} = run_rule(%{"style" => %{"bg" => "#ff0000", "fg" => "#000000"}})
    assert msg =~ "unknown key"
  end

  test "a missing required key (when) is rejected" do
    assert {:halt, msg} =
             run_cfs([%{"id" => "r1", "range" => "B2", "style" => %{"bg" => "#ff0000"}}])

    assert msg =~ "missing key"
  end

  # ── id ──────────────────────────────────────────────────────────────────

  test "a non-empty string id is required" do
    assert {:halt, _} = run_rule(%{"id" => ""})
    assert {:halt, _} = run_rule(%{"id" => 7})
  end

  test "duplicate ids within a tab are rejected" do
    a = rule(%{"id" => "dup", "range" => "A1"})
    b = rule(%{"id" => "dup", "range" => "A2"})
    assert {:halt, msg} = run_cfs([a, b])
    assert msg =~ "duplicate id"
  end

  # ── range ───────────────────────────────────────────────────────────────

  test "a malformed range is rejected" do
    assert {:halt, _} = run_rule(%{"range" => "not-a-range"})
    assert {:halt, _} = run_rule(%{"range" => "A1:B2:C3"})
    assert {:halt, _} = run_rule(%{"range" => 5})
  end

  test "an out-of-bounds range is rejected" do
    assert {:halt, _} = run_rule(%{"range" => "XFE1"})
    assert {:halt, _} = run_rule(%{"range" => "A1:A1048577"})
  end

  test "a duplicate normalized range (B2 vs B2:B2) is rejected" do
    a = rule(%{"id" => "a", "range" => "B2"})
    b = rule(%{"id" => "b", "range" => "B2:B2"})
    assert {:halt, msg} = run_cfs([a, b])
    assert msg =~ "duplicate normalized range"
  end

  test "a duplicate normalized range with reordered corners (C1:A3 vs A1:C3) is rejected" do
    a = rule(%{"id" => "a", "range" => "C1:A3"})
    b = rule(%{"id" => "b", "range" => "A1:C3"})
    assert {:halt, msg} = run_cfs([a, b])
    assert msg =~ "duplicate normalized range"
  end

  test "distinct ranges are allowed even when they overlap" do
    a = rule(%{"id" => "a", "range" => "A1:C3"})
    b = rule(%{"id" => "b", "range" => "B2:D4"})
    assert run_cfs([a, b]) == :ok
  end

  # ── shape + cap ─────────────────────────────────────────────────────────

  test "a non-map rule is rejected" do
    assert {:halt, msg} = run_cfs(["notamap"])
    assert msg =~ "rule must be a map"
  end

  test "cond_formats that is not a list is rejected" do
    assert {:halt, msg} = run_cfs(%{"nope" => 1})
    assert msg =~ "cond_formats must be a list"
  end

  test "more than 200 rules in a tab is rejected" do
    rules = for i <- 1..201, do: rule(%{"id" => "r#{i}", "range" => "A#{i}"})
    assert {:halt, msg} = run_cfs(rules)
    assert msg =~ "cap is 200"
  end

  test "exactly 200 rules is allowed" do
    rules = for i <- 1..200, do: rule(%{"id" => "r#{i}", "range" => "A#{i}"})
    assert run_cfs(rules) == :ok
  end
end
