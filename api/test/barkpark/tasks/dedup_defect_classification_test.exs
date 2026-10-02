defmodule Barkpark.Tasks.DedupDefectClassificationTest do
  @moduledoc """
  THE LOCK for the DEFECT/OUTAGE split.

  `Barkpark.Tasks.Dedup` and `Barkpark.Content.DedupWall` are two doors onto the
  same decision — "did OUR code raise, or did the database fail?" — and they
  answer it from two private `@code_error_modules` lists, because neither module
  may reach into the other's private classifier (the wall is kernel
  `Barkpark.Content`; the task gate is not, and the wall's file is owned by a
  different lane's open PR).

  A comment saying "mirrors the wall" is not a lock: it stays true-looking while
  one side gains `Enum.EmptyError` and the other does not, and the drift is
  invisible until a live exception reads as an outage on one path and a defect
  on the other.

  So this test reads BOTH FILES' SOURCE, evaluates both lists, and asserts they
  are term-identical. It reds on the first module that appears in one and not
  the other, in either direction.
  """
  use ExUnit.Case, async: true

  @wall_path Path.expand("../../../lib/barkpark/content/dedup_wall.ex", __DIR__)
  @tasks_path Path.expand("../../../lib/barkpark/tasks/dedup.ex", __DIR__)

  # One DECLARATION per file — `^\s*@code_error_modules\s+\[` — so a prose
  # mention of the attribute inside a comment can never be mistaken for it.
  @declaration ~r/^[ \t]*@code_error_modules[ \t]+\[/m

  defp source(path) do
    assert File.exists?(path), "#{path} does not exist — this test is measuring nothing"
    File.read!(path)
  end

  defp code_error_modules(path) do
    src = source(path)

    assert length(Regex.scan(@declaration, src)) == 1,
           "#{path} must declare @code_error_modules exactly once; the extractor below " <>
             "reads the first match and would silently read the wrong one otherwise"

    [_, list] = Regex.run(~r/@code_error_modules[ \t]+(\[[^\]]*\])/, src)
    {mods, _binding} = Code.eval_string(list)
    mods
  end

  test "the extractor actually extracts — both lists are non-empty and hold known code errors" do
    # THE PRECONDITION. A regex that matched nothing would return `[]` from both
    # files and the agreement assertion below would pass vacuously, green,
    # forever. Assert the instrument works before trusting its verdict.
    wall = code_error_modules(@wall_path)
    tasks = code_error_modules(@tasks_path)

    for {label, list} <- [{"DedupWall", wall}, {"Tasks.Dedup", tasks}] do
      assert length(list) > 5, "#{label}'s list came back as #{inspect(list)} — extractor broken"
      assert FunctionClauseError in list, "#{label}'s list omits FunctionClauseError"
      assert MatchError in list, "#{label}'s list omits MatchError"
      assert Enum.all?(list, &is_atom/1), "#{label}'s list is not a list of modules"
      refute DBConnection.ConnectionError in list, "#{label} classifies an OUTAGE as a defect"
    end
  end

  test "Tasks.Dedup and Content.DedupWall classify the SAME exception modules" do
    wall = code_error_modules(@wall_path)
    tasks = code_error_modules(@tasks_path)

    assert Enum.sort(tasks) == Enum.sort(wall),
           """
           The two dedup doors disagree about what a code DEFECT is.

           only in Tasks.Dedup:   #{inspect(tasks -- wall)}
           only in DedupWall:     #{inspect(wall -- tasks)}

           Both lists must move together — see the moduledoc above.
           """

    # Term-identical, not merely same-set: the two files are read the same way
    # by a human, so keep the ORDER honest too.
    assert tasks == wall
  end
end
