defmodule Barkpark.Tasks.CitationsTest do
  @moduledoc """
  THE NON-VACUITY PROOF for the second-citation grammar (task-29781d0921e5a885
  criterion 2), at the layer that owns it.

  The property under test is not "the parser runs" — it is that a body citing
  TWO rows yields TWO and a body citing ONE yields ONE. A parser that quietly
  returned only the first citation would satisfy every "it parses" assertion
  ever written and would reintroduce the exact defect: a sibling row that never
  learns a merge discharged it. So every count assertion below names the rows it
  expects BY ID in its failure message, and the suite is run against a mutant
  (`|> Enum.take(1)` on the parse) to confirm it reds and prints the dropped id.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Citations

  doctest Barkpark.Tasks.Citations

  @a "task-29781d0921e5a885"
  @b "pds-w40-bl-item-share-silent-noop"

  describe "the citation count" do
    test "a body citing TWO rows yields BOTH — the arm a first-match parser fails" do
      body = """
      fix(tasks): the thing (#16640)

      prose about the change.

      Discharges: #{@a} c2
      Discharges: `#{@b}`

      Task: task-primary
      """

      cited = Citations.discharges(body)
      ids = Enum.map(cited, & &1.task_id)

      assert @a in ids,
             "the FIRST cited row #{@a} is missing from #{inspect(ids)} — " <>
               "a PR citing two rows must mark both"

      assert @b in ids,
             "the SECOND cited row #{@b} is missing from #{inspect(ids)} — " <>
               "this is the defect: a sibling row a merge discharged never learns it"

      assert length(cited) == 2, "expected 2 citations, got #{inspect(ids)}"

      assert cited == [
               %{task_id: @a, criterion: 2},
               %{task_id: @b, criterion: nil}
             ]
    end

    test "a body citing ONE row yields exactly ONE — the count is read, not assumed" do
      body = "Discharges: #{@a} c0\n\nTask: task-primary\n"

      assert Citations.discharges(body) == [%{task_id: @a, criterion: 0}]
    end

    test "a body citing NO row yields none — the common PR, and never an error" do
      assert Citations.discharges("fix: a thing (#1)\n\nTask: task-primary\n") == []
      assert Citations.discharges(nil) == []
      assert Citations.discharges(%{}) == []
      assert Citations.discharges("") == []
    end

    test "three citations, one of them a duplicate, yield TWO distinct rows" do
      body = """
      Discharges: #{@a} c2
      Discharges: #{@b}
      Discharges: #{@a} c2
      """

      assert Citations.discharges(body) == [
               %{task_id: @a, criterion: 2},
               %{task_id: @b, criterion: nil}
             ]
    end

    test "the SAME row cited at two DIFFERENT criteria is two citations, not a duplicate" do
      body = "Discharges: #{@a} c1\nDischarges: #{@a} c4\n"

      assert Citations.discharges(body) == [
               %{task_id: @a, criterion: 1},
               %{task_id: @a, criterion: 4}
             ]
    end
  end

  describe "the form" do
    test "backticks are stripped — the house idiom, and the #5290 shape" do
      assert Citations.discharges("Discharges: `#{@a}` c3") == [%{task_id: @a, criterion: 3}]
    end

    test "the keyword is case-insensitive and the index is zero-based" do
      assert Citations.discharges("discharges: #{@a} c0") == [%{task_id: @a, criterion: 0}]
      assert Citations.discharges("DISCHARGES: #{@a}") == [%{task_id: @a, criterion: nil}]
    end

    test "a CRLF body parses identically — a description pasted from Windows" do
      assert Citations.discharges("Discharges: #{@a} c2\r\nDischarges: #{@b}\r\n") == [
               %{task_id: @a, criterion: 2},
               %{task_id: @b, criterion: nil}
             ]
    end

    test "NOT at column 0 is not a citation — a quoted example must not mark a live row" do
      assert Citations.discharges("  Discharges: #{@a} c2") == []
      assert Citations.discharges("see Discharges: #{@a}") == []
    end

    test "trailing prose is a NON-match, not a prefix match" do
      # "Discharges: the old behaviour" must not resolve to a row named `the`.
      assert Citations.discharges("Discharges: the old behaviour") == []
      assert Citations.discharges("Discharges: #{@a} c2 and also some prose") == []
    end

    test "a `Task:` trailer is NOT a citation — the two grammars do not overlap" do
      assert Citations.discharges("Task: #{@a}\n") == []
    end

    test "an empty label is not a citation" do
      assert Citations.discharges("Discharges:") == []
      assert Citations.discharges("Discharges: ") == []
    end
  end
end
