defmodule BarkparkCloud.Web.RouterAuditDiscardCensusTest do
  @moduledoc """
  A SOURCE CENSUS over the shape of every `Accounts.record_audit/1` call site,
  so the silent-discard idiom cannot come back.

  ## The idiom this file exists to keep out

  A call site written as a bare match against the throwaway binding —

      _ =
        Accounts.record_audit(%{...})

  — throws `{:error, changeset}` on the floor. `AuditEvent`'s changeset refuses
  an undeclared verb (`validate_inclusion` over the closed `actions/0` list), a
  missing required field, and either assoc constraint. On any of those the
  request still answers its success code, the console still receives its
  `"audit"` push, and the row NEVER EXISTS. That is how `site.rolled_back`
  was lost while the console's Activity empty state promised removals and site
  changes would show up there.

  ## Why a single-line grep says the problem is not there

  The idiom is TWO LINES. `grep '_ = Accounts.record_audit'` over the router
  returns ZERO on a tree carrying eight of them, because the formatter breaks
  after the `=`. An earlier reader concluded from that zero that the finding had
  been refuted. The census below therefore matches the PAIR — a line whose code
  is exactly `_ =` followed by a line opening `Accounts.record_audit(` — and
  never a single line.

  ## The two arms

    * ARM (a), tree-wide over `cloud/lib`: the pair appears ZERO times. Any
      module, not just the router — a new discard in a worker is the same bug.
    * ARM (b), router-scoped: EVERY `Accounts.record_audit(%{` call site in
      `router.ex` opens with `case `, so its `{:error, _}` has somewhere to go.
      Arm (a) alone is defeated by a fresh discard spelling (`_ignored =`, or a
      bare call in statement position); arm (b) is keyed on the ONE accepted
      shape rather than on the shapes we happened to think of.

  Arm (b) is deliberately NOT tree-wide. `Registry.record_deprovision_audit/3`
  calls `record_audit/1` in TAIL position inside `succeed_deprovision_job/2`'s
  transaction: the value is RETURNED to a caller that rolls the delete back on
  `{:error, _}`. That is the fail-closed discipline, not a discard, and a
  `case`-only rule would red on the strictest call site in the tree.

  ## Limits, stated so nobody over-reads a green run

    * It is a TEXT-SHAPE scan, not a call graph. It proves the error value is
      BOUND, not that the handler does anything useful with it.
    * Comment stripping is whole-line only (`#` in column N with nothing but
      whitespace before it). Every non-call mention of the function in the
      router today is written `record_audit/1`, with no `(%{`, so no comment
      reaches either regex. A future comment that pastes a call literally would
      be counted; rewrite it in arity form.
    * A floor (`@router_call_sites`) is asserted so a broken extractor REDS
      instead of reporting a clean tree. Nine call sites and a typo in the
      regex look identical without it.

  ## MUTATION (run before trusting the green)

  Re-introduce one discard — in `router.ex`, replace the `case ` opening the
  `site.deleted` call site with the two-line `_ =` form and delete its two
  result arms plus the `end`. Both arms red and both name the file:

      1) test the two-line discard idiom is extinct across cloud/lib
         Assertion with == failed
         left:  ["barkpark_cloud/web/router.ex"]
         right: []

      2) test every record_audit call site in the router is case-gated
         Assertion with == failed
         left:  13
         right: 14

  Restore, and both go green.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)
  @router Path.join(@lib_root, "barkpark_cloud/web/router.ex")

  # The number of `Accounts.record_audit(%{` call sites in the router. A floor
  # AND a ceiling: this is a census, so a new call site is a deliberate edit
  # that re-reads this file rather than a number that drifts.
  @router_call_sites 14

  defp lib_files, do: Path.wildcard(Path.join(@lib_root, "**/*.ex"))

  # Whole-line comments only — see the moduledoc's limits.
  defp code_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(fn line -> if String.starts_with?(String.trim(line), "#"), do: "", else: line end)
  end

  defp discard_pairs(path) do
    lines = code_lines(path)

    lines
    |> Enum.zip(Enum.drop(lines, 1))
    |> Enum.count(fn {a, b} ->
      String.trim(a) == "_ =" and String.starts_with?(String.trim(b), "Accounts.record_audit(")
    end)
  end

  test "the two-line discard idiom is extinct across cloud/lib" do
    offenders =
      for path <- lib_files(),
          discard_pairs(path) > 0,
          do: Path.relative_to(path, @lib_root)

    assert offenders == [],
           "these modules bind a record_audit error to `_` and drop it: #{inspect(offenders)}"
  end

  test "the single-line discard spelling is extinct too" do
    hits =
      for path <- lib_files(),
          line <- code_lines(path),
          String.contains?(line, "_ = Accounts.record_audit"),
          do: Path.relative_to(path, @lib_root)

    assert hits == []
  end

  test "every record_audit call site in the router is case-gated" do
    lines = code_lines(@router)

    all = Enum.count(lines, &String.contains?(&1, "Accounts.record_audit(%{"))
    gated = Enum.count(lines, &String.contains?(&1, "case Accounts.record_audit(%{"))

    # Non-vacuity: the extractor found the sites it is supposed to be judging.
    assert all == @router_call_sites,
           "expected #{@router_call_sites} record_audit call sites in the router, found #{all} — " <>
             "a call site was added or removed, or the extractor broke"

    assert gated == @router_call_sites
  end
end
