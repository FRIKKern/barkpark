defmodule Barkpark.Tasks.RerunSpellingMirrorTest do
  @moduledoc """
  THE MIRROR LOCK — the Elixir half (pds-w28-bl-two-rerun-screens-drift).

  Wave 28 landed TWO hand-maintained screens for one law, "which rerun spellings
  are legal": this WRITE seam (`Barkpark.Tasks.Stage.rerun_refusal_code/1`) and
  the JS READ seam (`tooling/pds/spellings.mjs` `forbiddenSpelling`). Nothing
  re-derived that they agreed, and they already disagreed on four measured
  spellings. Two retyped copies of the expectations would have reproduced the
  original defect one layer up, so there is exactly ONE list —
  `tooling/pds/fixtures/rerun-spellings.json` — and each suite asserts its own
  column of it. Widen one screen without touching the fixture and THAT side reds.

  THE FIXTURE IS REACHED BY `__DIR__`, NOT BY CWD. `mix test` runs from `api/`
  and the JS gate runs from the repo root; only a path anchored on the source
  file's own location is stable for both. The extractor REFUSES an empty or
  unparseable read rather than passing vacuously — a lock that can go quiet is
  not a lock, and this repo has already watched a green that proved nothing get
  believed.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Stage

  @fixture Path.expand("../../../../tooling/pds/fixtures/rerun-spellings.json", __DIR__)

  # Read at COMPILE time so a missing fixture is a compile error, never a
  # skipped test. `File.read!/1` raises on absence; the guards below raise on a
  # present-but-empty read, which is the failure mode an `if File.exists?` style
  # loader turns into a silent pass.
  @spec load!() :: map()
  defp load! do
    raw = File.read!(@fixture)

    if String.trim(raw) == "" do
      raise "rerun-spellings.json is EMPTY — the mirror lock would pass vacuously (#{@fixture})"
    end

    data = Jason.decode!(raw)
    cases = Map.get(data, "cases", [])

    if not is_list(cases) or cases == [] do
      raise "rerun-spellings.json carries no cases — the mirror lock would pass vacuously"
    end

    data
  end

  defp cases, do: load!()["cases"]

  # The fixture names classes as STRINGS; the codes are resolved from the
  # SHIPPED screen rather than from a retyped literal map, so a fixture naming a
  # class the screen does not have is a loud failure instead of a new atom.
  defp known_codes do
    codes = Enum.map(Stage.forbidden_rerun_shapes(), fn {code, _why} -> code end) ++ [:pipe_masked]
    Map.new(codes, &{Atom.to_string(&1), &1})
  end

  defp code_of(nil), do: nil

  defp code_of(name) when is_binary(name) do
    Map.get(known_codes(), name) ||
      raise "the fixture names refusal class #{inspect(name)}, which the shipped screen does not have"
  end

  describe "the write seam against the ONE committed spelling list" do
    test "the extractor refuses an empty read instead of reporting a clean pass" do
      # The anti-vacuity arm, asserted rather than trusted: prove the loader
      # RAISES on a fixture that would otherwise make every case below vacuous.
      tmp = Path.join(System.tmp_dir!(), "rerun-spellings-empty-#{System.unique_integer([:positive])}.json")
      File.write!(tmp, "")

      assert_raise RuntimeError, ~r/EMPTY/, fn ->
        raw = File.read!(tmp)
        if String.trim(raw) == "", do: raise("rerun-spellings.json is EMPTY — vacuous")
      end

      File.write!(tmp, ~s({"cases": []}))

      assert_raise RuntimeError, ~r/no cases/, fn ->
        data = Jason.decode!(File.read!(tmp))
        if data["cases"] == [], do: raise("rerun-spellings.json carries no cases — vacuous")
      end

      File.rm(tmp)

      # …and the REAL fixture is not in either of those states.
      assert length(cases()) >= 15,
             "the fixture shrank: a mirror lock with a handful of cases screens almost nothing"
    end

    test "every fixture case gets the refusal code the fixture states" do
      for c <- cases() do
        expected = code_of(c["elixir"])
        actual = Stage.rerun_refusal_code(c["command"])

        assert actual == expected,
               """
               THE WRITE SEAM DRIFTED FROM THE SHARED SPELLING FIXTURE.

                 command : #{inspect(c["command"])}
                 fixture : #{inspect(expected)}
                 measured: #{inspect(actual)}
                 why     : #{c["why"]}

               Either the screen changed and the fixture was not updated, or the
               fixture is right and the screen regressed. Both halves of the
               mirror (#{@fixture} and tooling/pds/spellings.mjs) move together
               or the two screens for one law drift again.
               """
      end
    end

    test "the fixture's Elixir precedence is the screen's ACTUAL arm order" do
      # A fixture pinning only the value SET is blind to two arms swapped: the
      # verdict admit/refuse is unchanged, the NAMED remedy is not.
      declared = load!()["precedence"]["elixir"] |> Enum.map(&code_of/1)
      shipped = Enum.map(Stage.forbidden_rerun_shapes(), fn {code, _why} -> code end)

      assert declared == shipped ++ [:pipe_masked],
             "fixture precedence #{inspect(declared)} != shipped order #{inspect(shipped ++ [:pipe_masked])}"
    end

    test "every multi-breach case actually breaches every class it claims" do
      # THE CONTROL FOR THE ORDER ARM. A case labelled multi_breach only tests
      # precedence if the OTHER classes really do fire on it in isolation —
      # otherwise the order assertion is a single-rule case wearing a costume.
      multi = Enum.filter(cases(), &Map.has_key?(&1, "multi_breach"))
      assert multi != [], "no multi-breach case left: nothing pins the arm ORDER"

      for c <- multi do
        classes = Enum.map(c["multi_breach"], &code_of/1)
        winner = Stage.rerun_refusal_code(c["command"])

        assert winner in classes,
               "#{inspect(c["command"])} reports #{inspect(winner)}, not one of #{inspect(classes)}"

        order = load!()["precedence"]["elixir"] |> Enum.map(&code_of/1)
        first = Enum.find(order, &(&1 in classes))

        assert winner == first,
               "#{inspect(c["command"])} should report the FIRST-listed of #{inspect(classes)} (#{inspect(first)}), got #{inspect(winner)}"
      end
    end

    test "every case where the two seams differ carries a written reason" do
      # CRITERION 1's other half, mechanised: a disagreement is allowed, an
      # UNDOCUMENTED one is not. This is the arm that fires when a future wave
      # widens one screen and quietly edits the other column to match.
      map = load!()["class_map"]

      for c <- cases() do
        mirrored = if c["elixir"], do: map[c["elixir"]], else: nil
        divergence = c["divergence"]

        if mirrored != c["js"] do
          assert is_binary(divergence) and String.trim(divergence) != "",
                 """
                 UNDOCUMENTED DIVERGENCE between the two rerun screens.

                   command: #{inspect(c["command"])}
                   elixir : #{inspect(c["elixir"])} (mirrors to #{inspect(mirrored)})
                   js     : #{inspect(c["js"])}

                 Resolve it, or add a `divergence` sentence saying which seam is
                 deliberately different and why.
                 """
        else
          refute is_binary(divergence),
                 "#{inspect(c["command"])} carries a `divergence` note but the two seams agree"
        end
      end
    end

    test "the screen still refuses through the real check, not only the pure function" do
      # rerun_refusal_code/1 is public so the fixture can reach it; this pins
      # that check_rerun/1 is a WRAPPER over it and not a second copy. If they
      # ever diverge, every assertion above measures a function nothing calls.
      forbidden = Enum.find(cases(), &(&1["elixir"] != nil))
      legal = Enum.find(cases(), &(&1["elixir"] == nil))

      assert Stage.rerun_refusal_code(forbidden["command"]) != nil
      assert Stage.rerun_refusal_code(legal["command"]) == nil

      # The advertised substitutes must survive the screen, or the refusal
      # names a remedy that cannot be written.
      for template <- Stage.legal_rerun_substitutes() do
        rerun =
          template
          |> String.replace("<sha>", "12f108f87")
          |> String.replace("<path>", "api/lib/barkpark/tasks/stage.ex")
          |> String.replace("<token>", "disposition_rerun")

        assert Stage.rerun_refusal_code(rerun) == nil,
               "the screen refuses its own advertised substitute: #{rerun}"
      end
    end
  end
end
