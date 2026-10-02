defmodule Barkpark.Content.Papers.ClearBlocksHandRolledTripwireTest do
  @moduledoc """
  The third `clear_blocks` re-inline shape (task-238372352173b2b9): a NEW call
  site that skips `BlockOps.clear_blocks?/1` entirely and hand-rolls its own
  truthiness (`clear in [true, "true"]`, `x == "true"`) on the param.
  `clear_blocks_predicate_parity_test.exs` fences the other two shapes; nothing
  fenced this one.

  WHAT THIS DOES — a grep-sized tripwire over `api/lib`, nothing more:

    * Rule A: code (comments and heredocs stripped) that mentions `clear_blocks`
      or a `clear` variable next to a truthiness literal (`"true"`, `[true`,
      `== true`) is an offence — except the canonical predicate's own clauses,
      excluded by name: `def clear_blocks?(` in `content/papers/block_ops.ex`.
    * Rule B: every line that READS the param (`["clear_blocks"]`,
      `Map.get(_, "clear_blocks")`, `"clear_blocks" => value`) must hand it to
      `clear_blocks?(` or `put_or_clear_blocks(` on that line, or be one of the
      two pass-through shapes enumerated in `@pass_through` (fail-closed: a new
      pass-through is a deliberate edit to this list).

  WHAT IT DOES NOT ATTEMPT: data-flow analysis. A value read into a variable on
  one line and hand-compared ten lines later with an unusual spelling can slip
  Rule A. That is the size security set (lead-security-12, #16662): reaching
  this shape needs a NEW content writer, itself a reviewed fence change; this
  file makes the common spellings red rather than relying on memory.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../../lib", __DIR__)
  @canonical "barkpark/content/papers/block_ops.ex"

  # The only reads allowed to move the raw value without judging it.
  @pass_through [
    # the ingest controller copies the param into the attrs map verbatim
    ~r/"clear_blocks"\s*=>\s*params\["clear_blocks"\]/
  ]

  @truthy ~r/"true"|\[\s*true\b|==\s*true\b|===\s*true\b/
  @names ~r/clear_blocks|\bclear\b/
  @reads ~r/\["clear_blocks"\]|Map\.(get|fetch!?)\([^,]+,\s*"clear_blocks"|"clear_blocks"\s*=>\s*[^,}\s]/
  @judged ~r/clear_blocks\?\(|put_or_clear_blocks\(/

  @doc false
  def scan(files) do
    Enum.flat_map(files, fn {rel, source} ->
      source
      |> code_lines()
      |> Enum.flat_map(fn {line, n} ->
        canonical_def? = rel == @canonical and line =~ ~r/^\s*def clear_blocks\?\(/

        a =
          if not canonical_def? and line =~ @names and line =~ @truthy,
            do: [{rel, n, :hand_rolled_truthiness, String.trim(line)}],
            else: []

        b =
          if line =~ @reads and not (line =~ @judged) and
               not Enum.any?(@pass_through, &(line =~ &1)),
             do: [{rel, n, :unjudged_read, String.trim(line)}],
             else: []

        a ++ b
      end)
    end)
  end

  @doc false
  def reads(files) do
    for {rel, source} <- files, {line, n} <- code_lines(source), line =~ @reads, do: {rel, n}
  end

  # Source lines with comments and heredoc bodies blanked (messages and docs
  # quote the param freely); line numbers kept.
  defp code_lines(source) do
    {lines, _} =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map_reduce(false, fn {line, n}, in_heredoc ->
        toggles = length(Regex.scan(~r/"""|'''/, line))
        blank? = in_heredoc or toggles > 0
        next = if rem(toggles, 2) == 1, do: not in_heredoc, else: in_heredoc
        code = if blank?, do: "", else: String.replace(line, ~r/(^|\s)#.*$/, "")
        {{code, n}, next}
      end)

    lines
  end

  defp lib_files do
    Path.wildcard(Path.join(@lib, "**/*.ex"))
    |> Enum.map(&{Path.relative_to(&1, @lib), File.read!(&1)})
  end

  test "no code in api/lib hand-rolls clear_blocks truthiness or reads the param unjudged" do
    offences = scan(lib_files())

    assert offences == [],
           "clear_blocks must be judged by BlockOps.clear_blocks?/1 only:\n" <>
             Enum.map_join(offences, "\n", fn {f, n, kind, l} -> "  #{f}:#{n} #{kind}: #{l}" end)
  end

  test "positive control: the scan reaches the files it guards" do
    files = lib_files()
    assert length(files) > 500, "the wildcard found #{length(files)} files — a blind scan"
    hit = files |> reads() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

    # the three real readers today; a scan that matches nothing would pass forever
    for rel <- [
          "barkpark/content/papers/block_ops.ex",
          "barkpark/content/papers/mixed_write_guard.ex",
          "barkpark/plugins/bulldocs/web/bulldocs_ingest_controller.ex"
        ] do
      assert rel in hit,
             "expected the scan to find the clear_blocks read in #{rel}; found #{inspect(hit)}"
    end

    assert Enum.any?(files, fn {rel, src} ->
             rel == @canonical and src =~ "def clear_blocks?(true)"
           end),
           "the canonical predicate moved — update @canonical by name"
  end

  test "mutation control: a second call site that hand-rolls the check reds" do
    planted = """
    defmodule Planted do
      def clear?(attrs), do: attrs["clear_blocks"] in [true, "true"]
      def other(clear), do: clear == "true"
      def copy(params), do: %{"clear_blocks" => params["clear"]}
    end
    """

    kinds = [{"barkpark/planted.ex", planted}] |> scan() |> Enum.map(&elem(&1, 2))
    assert :hand_rolled_truthiness in kinds
    assert :unjudged_read in kinds
    assert length(kinds) >= 3

    # and the canonical clauses are excluded ONLY in their own file, by name
    canonical_copy = ~s|  def clear_blocks?("true"), do: true|
    assert scan([{@canonical, canonical_copy}]) == []

    assert [{_, _, :hand_rolled_truthiness, _}] =
             scan([{"barkpark/elsewhere.ex", canonical_copy}])
  end
end
