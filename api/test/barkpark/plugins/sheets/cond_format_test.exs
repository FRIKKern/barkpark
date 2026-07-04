defmodule Barkpark.Plugins.Sheets.CondFormatTest do
  @moduledoc """
  Unit locks for `Barkpark.Plugins.Sheets.CondFormat` — the conditional-
  formatting kernel. Pure functions, no DB.

  The `matches?/2` eval matrix is driven by the committed cross-runtime fixture
  `test/support/fixtures/sheet-cond-format-eval.json` (CF-D9): the fixture IS
  the contract, re-asserted VERBATIM by the later JS grid renderer. Direct
  unit tests cover `parse_rules/1` leniency, `style_for/3` first-match-wins,
  and `compose/2` per-key precedence.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.CondFormat

  @fixture_path Path.expand(
                  "../../../support/fixtures/sheet-cond-format-eval.json",
                  __DIR__
                )

  # ── matches?/2 — the CF-D9 fixture matrix ───────────────────────────────────

  describe "matches?/2 against the committed eval fixture" do
    @fixture @fixture_path |> File.read!() |> Jason.decode!()

    test "every fixture row evaluates exactly as specified" do
      for row <- @fixture["rows"] do
        when_map =
          %{"op" => row["op"], "value" => row["value"]}
          |> then(fn m ->
            if Map.has_key?(row, "value2"), do: Map.put(m, "value2", row["value2"]), else: m
          end)

        actual = CondFormat.matches?(when_map, row["cell"])

        assert actual == row["expect"],
               "row #{inspect(row["desc"])}: matches?(#{inspect(when_map)}, " <>
                 "#{inspect(row["cell"])}) = #{actual}, expected #{row["expect"]}"
      end
    end

    test "the fixture covers every op and every value class" do
      ops = @fixture["rows"] |> Enum.map(& &1["op"]) |> MapSet.new()
      assert MapSet.subset?(MapSet.new(~w(gt lt eq between contains)), ops)

      # at least one must-match and one must-not-match row exists overall
      expects = @fixture["rows"] |> Enum.map(& &1["expect"]) |> MapSet.new()
      assert MapSet.equal?(expects, MapSet.new([true, false]))
    end
  end

  # ── matches?/2 — direct edge cases beyond the fixture ────────────────────────

  describe "matches?/2 totality" do
    test "a non-map `when` never matches, never raises" do
      refute CondFormat.matches?(nil, %{"v" => 5})
      refute CondFormat.matches?("gt", %{"v" => 5})
    end

    test "an unknown op never matches" do
      refute CondFormat.matches?(%{"op" => "regex", "value" => "."}, %{"v" => "x"})
    end

    test "a malformed `when` (missing value) never raises" do
      refute CondFormat.matches?(%{"op" => "gt"}, %{"v" => 5})
      refute CondFormat.matches?(%{"op" => "between", "value" => 1}, %{"v" => 5})
    end

    test "eq treats 1 and 1.0 as equal (Elixir ==)" do
      assert CondFormat.matches?(%{"op" => "eq", "value" => 1}, %{"v" => 1.0})
      assert CondFormat.matches?(%{"op" => "eq", "value" => 1.0}, %{"v" => 1})
    end
  end

  # ── parse_rules/1 leniency ───────────────────────────────────────────────────

  describe "parse_rules/1" do
    test "non-list input yields []" do
      assert CondFormat.parse_rules(nil) == []
      assert CondFormat.parse_rules(%{}) == []
      assert CondFormat.parse_rules("nope") == []
    end

    test "a well-formed single-cell rule normalizes to a degenerate range" do
      rules =
        CondFormat.parse_rules([
          %{
            "range" => "B2",
            "when" => %{"op" => "gt", "value" => 5},
            "style" => %{"bg" => "#ff0000"}
          }
        ])

      assert [%{range: {2, 2, 2, 2}, condition: %{"op" => "gt"}, style: %{"bg" => "#ff0000"}}] =
               rules
    end

    test "a range rule normalizes corners top-left regardless of input order" do
      [rule] =
        CondFormat.parse_rules([
          %{
            "range" => "D9:B2",
            "when" => %{"op" => "lt", "value" => 1},
            "style" => %{"bg" => "#00FF00"}
          }
        ])

      assert rule.range == {2, 2, 4, 9}
      # bg is normalized lowercase, matching the manual sanitizer vocabulary
      assert rule.style == %{"bg" => "#00ff00"}
    end

    test "b/i flags are kept only when literally true" do
      [rule] =
        CondFormat.parse_rules([
          %{
            "range" => "A1",
            "when" => %{"op" => "eq", "value" => 1},
            "style" => %{"bg" => "#111111", "b" => true, "i" => false}
          }
        ])

      assert rule.style == %{"bg" => "#111111", "b" => true}
    end

    test "silently skips malformed entries — bad range, bad op, bad style" do
      rules =
        CondFormat.parse_rules([
          # bad range
          %{
            "range" => "notaref",
            "when" => %{"op" => "gt", "value" => 1},
            "style" => %{"bg" => "#ff0000"}
          },
          # unknown op
          %{"range" => "A1", "when" => %{"op" => "matches"}, "style" => %{"bg" => "#ff0000"}},
          # style sanitizes to empty (bad bg, no flags)
          %{
            "range" => "A1",
            "when" => %{"op" => "gt", "value" => 1},
            "style" => %{"bg" => "red"}
          },
          # not a map
          "garbage",
          # missing when
          %{"range" => "A1", "style" => %{"bg" => "#ff0000"}},
          # the one good rule
          %{
            "range" => "A1",
            "when" => %{"op" => "gt", "value" => 1},
            "style" => %{"bg" => "#abcdef"}
          }
        ])

      assert length(rules) == 1
      assert hd(rules).style == %{"bg" => "#abcdef"}
    end

    test "preserves list order (first-match priority relies on it)" do
      [r1, r2] =
        CondFormat.parse_rules([
          %{
            "range" => "A1",
            "when" => %{"op" => "gt", "value" => 0},
            "style" => %{"bg" => "#aaaaaa"}
          },
          %{
            "range" => "A1",
            "when" => %{"op" => "gt", "value" => 0},
            "style" => %{"bg" => "#bbbbbb"}
          }
        ])

      assert r1.style == %{"bg" => "#aaaaaa"}
      assert r2.style == %{"bg" => "#bbbbbb"}
    end

    test "a bg with a trailing newline drops the rule (`\\z` tightening)" do
      # The bg sanitizer is `\z`-anchored now: "#ff0000\n" leaks under `$` but
      # sanitizes to nil here, so the style is empty and the rule is skipped.
      assert CondFormat.parse_rules([
               %{
                 "range" => "A1",
                 "when" => %{"op" => "gt", "value" => 1},
                 "style" => %{"bg" => "#ff0000\n"}
               }
             ]) == []
    end
  end

  # ── sanitize_bg/1 + valid_bg?/1 — the SINGLE `#rrggbb` sanitizer owner ────────

  describe "sanitize_bg/1 and valid_bg?/1" do
    test "a #rrggbb normalizes to lowercase; case-insensitive in" do
      assert CondFormat.sanitize_bg("#ff0000") == "#ff0000"
      assert CondFormat.sanitize_bg("#FF00AA") == "#ff00aa"
      assert CondFormat.sanitize_bg("#AbCdEf") == "#abcdef"
    end

    test "a trailing newline is rejected (`\\z`, not `$`)" do
      assert CondFormat.sanitize_bg("#ff0000\n") == nil
      refute CondFormat.valid_bg?("#ff0000\n")
    end

    test "bad shapes and non-binaries return nil / false" do
      for bad <- ["red", "#fff", "#ffff", "#gggggg", "ff0000", "", nil, 42, %{}] do
        assert CondFormat.sanitize_bg(bad) == nil
        refute CondFormat.valid_bg?(bad)
      end
    end

    test "valid_bg?/1 acceptance is byte-identical to sanitize_bg/1 returning non-nil" do
      for v <- ["#ff0000", "#FF00AA", "#ff0000\n", "red", "#fff", nil, true] do
        assert CondFormat.valid_bg?(v) == (CondFormat.sanitize_bg(v) != nil)
      end
    end
  end

  # ── style_for/3 — first-match-wins under overlap ─────────────────────────────

  describe "style_for/3" do
    setup do
      rules =
        CondFormat.parse_rules([
          # rule 1: B1:C3, gt 100 → red
          %{
            "range" => "B1:C3",
            "when" => %{"op" => "gt", "value" => 100},
            "style" => %{"bg" => "#ff0000"}
          },
          # rule 2: A1:C3 (overlaps rule 1), gt 0 → green
          %{
            "range" => "A1:C3",
            "when" => %{"op" => "gt", "value" => 0},
            "style" => %{"bg" => "#00ff00"}
          }
        ])

      %{rules: rules}
    end

    test "first rule in list order whose range contains the cell AND matches wins", %{
      rules: rules
    } do
      # B2 is in both ranges; 150 > 100 so rule 1 (red) fires first
      assert CondFormat.style_for(rules, {2, 2}, %{"v" => 150}) == %{"bg" => "#ff0000"}
    end

    test "falls through to a later rule when the first matches range but not condition", %{
      rules: rules
    } do
      # B2 in both ranges; 50 is NOT > 100 (rule 1 fails) but IS > 0 (rule 2 green)
      assert CondFormat.style_for(rules, {2, 2}, %{"v" => 50}) == %{"bg" => "#00ff00"}
    end

    test "a cell only in the second range takes the second rule", %{rules: rules} do
      # A2 is outside B1:C3 but inside A1:C3
      assert CondFormat.style_for(rules, {1, 2}, %{"v" => 5}) == %{"bg" => "#00ff00"}
    end

    test "no matching rule yields nil", %{rules: rules} do
      # A2, value 0 — not > 0, no rule fires
      assert CondFormat.style_for(rules, {1, 2}, %{"v" => 0}) == nil
      # D4 is outside every range
      assert CondFormat.style_for(rules, {4, 4}, %{"v" => 999}) == nil
    end

    test "empty rule list yields nil" do
      assert CondFormat.style_for([], {1, 1}, %{"v" => 1}) == nil
    end
  end

  # ── compose/2 — per-key precedence ───────────────────────────────────────────

  describe "compose/2" do
    test "CF bg overrides manual bg; manual al always survives" do
      manual = %{"bg" => "#000000", "al" => "center"}
      cf = %{"bg" => "#ff0000"}
      assert CondFormat.compose(manual, cf) == %{"bg" => "#ff0000", "al" => "center"}
    end

    test "manual b survives when the rule sets only bg" do
      manual = %{"b" => true, "al" => "right"}
      cf = %{"bg" => "#00ff00"}
      assert CondFormat.compose(manual, cf) == %{"b" => true, "al" => "right", "bg" => "#00ff00"}
    end

    test "CF b/i override manual b/i when present" do
      manual = %{"b" => true, "i" => true}
      cf = %{"bg" => "#111111", "i" => true}
      assert CondFormat.compose(manual, cf) == %{"b" => true, "i" => true, "bg" => "#111111"}
    end

    test "a nil CF style leaves the manual style untouched" do
      assert CondFormat.compose(%{"al" => "left"}, nil) == %{"al" => "left"}
    end

    test "empty/absent manual composes to just the CF style" do
      assert CondFormat.compose(%{}, %{"bg" => "#abcdef"}) == %{"bg" => "#abcdef"}
      assert CondFormat.compose(nil, %{"bg" => "#abcdef"}) == %{"bg" => "#abcdef"}
    end

    test "nil manual and nil CF compose to an empty map" do
      assert CondFormat.compose(nil, nil) == %{}
    end
  end
end
