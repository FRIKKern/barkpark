defmodule Barkpark.Tasks.TransitionsTest do
  @moduledoc """
  Exhaustive 7×7 legality matrix for the charter D7 transition table. The
  expected legal set is transcribed here INDEPENDENTLY of the implementation
  (a second copy, on purpose) so the matrix assertion catches any drift in
  `Barkpark.Tasks.Transitions.legal?/2` — including a wrong-cell flip that a
  spot-check would miss.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Transitions

  @statuses ~w(considering researching open in_progress blocked done cancelled)

  # The legal `{from, to}` pairs with `from != to`, from charter D7 — an
  # independent transcription (NOT read from the module under test).
  @legal_non_noop MapSet.new([
                    {"considering", "researching"},
                    {"researching", "considering"},
                    {"considering", "open"},
                    {"considering", "cancelled"},
                    {"researching", "open"},
                    {"researching", "cancelled"},
                    {"open", "considering"},
                    {"open", "blocked"},
                    {"open", "cancelled"},
                    {"blocked", "open"},
                    {"blocked", "cancelled"},
                    {"in_progress", "blocked"},
                    {"in_progress", "open"},
                    {"done", "open"},
                    {"cancelled", "open"}
                  ])

  defp expected_legal?(from, to) do
    from == to or MapSet.member?(@legal_non_noop, {from, to})
  end

  describe "legal?/2 — exhaustive 7×7 matrix" do
    test "every from×to pair matches the independently-transcribed D7 table" do
      for from <- @statuses, to <- @statuses do
        assert Transitions.legal?(from, to) == expected_legal?(from, to),
               "legal?(#{inspect(from)}, #{inspect(to)}) = #{Transitions.legal?(from, to)} " <>
                 "but expected #{expected_legal?(from, to)}"
      end
    end

    test "exactly 22 of the 49 pairs are legal (15 non-noop + 7 same→same)" do
      legal_count =
        for(from <- @statuses, to <- @statuses, Transitions.legal?(from, to), do: {from, to})
        |> length()

      assert legal_count == 22
    end
  end

  describe "the refused sets (charter D7)" do
    test "any → done is refused (done reached only through close), except done→done noop" do
      for from <- @statuses -- ["done"] do
        refute Transitions.legal?(from, "done"), "#{from} → done must be illegal"
      end

      assert Transitions.legal?("done", "done"), "done → done is the same→same no-op"
    end

    test "any → in_progress is refused (claim mints it), except in_progress→in_progress noop" do
      for from <- @statuses -- ["in_progress"] do
        refute Transitions.legal?(from, "in_progress"), "#{from} → in_progress must be illegal"
      end

      assert Transitions.legal?("in_progress", "in_progress")
    end

    test "done|cancelled → considering|researching is refused (terminals don't re-enter thought)" do
      for from <- ["done", "cancelled"], to <- ["considering", "researching"] do
        refute Transitions.legal?(from, to), "#{from} → #{to} must be illegal"
      end
    end
  end

  describe "the legal set (charter D7 spot checks)" do
    test "thought ⇄ thought both ways" do
      assert Transitions.legal?("considering", "researching")
      assert Transitions.legal?("researching", "considering")
    end

    test "thought → open|cancelled" do
      assert Transitions.legal?("considering", "open")
      assert Transitions.legal?("considering", "cancelled")
      assert Transitions.legal?("researching", "open")
      assert Transitions.legal?("researching", "cancelled")
    end

    test "open re-weigh / block / discard" do
      assert Transitions.legal?("open", "considering")
      assert Transitions.legal?("open", "blocked")
      assert Transitions.legal?("open", "cancelled")
    end

    test "done → open stays legal (the false-done reopen recipe depends on it)" do
      assert Transitions.legal?("done", "open")
    end

    test "cancelled → open reopens a discarded task" do
      assert Transitions.legal?("cancelled", "open")
    end

    test "every same → same is a legal no-op" do
      for s <- @statuses, do: assert(Transitions.legal?(s, s))
    end
  end

  describe "non-status inputs" do
    test "an unknown value has no legal edge in either direction" do
      refute Transitions.legal?("bogus", "open")
      refute Transitions.legal?("open", "bogus")
      refute Transitions.legal?("bogus", "bogus")
    end

    test "non-binary inputs are refused, not crashed" do
      refute Transitions.legal?(nil, "open")
      refute Transitions.legal?("open", nil)
      refute Transitions.legal?(:open, :done)
    end
  end
end
