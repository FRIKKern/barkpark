defmodule Barkpark.Sites.PrebuiltArtifactCodeCensusTest do
  @moduledoc """
  The taxonomy is two hand-written lists, and a list is a SNAPSHOT — it cannot
  notice a code added after it was written. This is the predicate that turns it
  back into a rule: it reads the extractor's SOURCE, takes every `E_*` literal
  the module can actually emit, and demands the two halves account for exactly
  that set.

  That is the drift this row was filed about, read from the other direction: the
  door's moduledoc had been a hand-kept copy of the same set and had gone stale
  by three codes — and the three it dropped were precisely the ones whose status
  class was wrong. A new code that nobody classifies now reds HERE, before it
  can reach a caller wearing the wrong status.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Sites.PrebuiltArtifact

  @source Path.expand("../../../lib/barkpark/sites/prebuilt_artifact.ex", __DIR__)
  @external_resource @source

  test "every E_* literal in the source is classified as caller-fault or internal" do
    assert File.exists?(@source),
           "the census reads #{@source}; a move makes this test vacuous, not passing"

    emitted =
      @source
      |> File.read!()
      # Only QUOTED codes — the two `~w(...)` taxonomy lists in the same file
      # carry their codes bare, so the census can never read its own answer
      # back out of the thing it is checking.
      |> then(&Regex.scan(~r/"(E_[A-Z0-9_]+)"/, &1))
      |> Enum.map(fn [_, code] -> code end)
      |> Enum.uniq()
      |> Enum.sort()

    # A CONTROL on the reader itself: an empty or tiny scan would make every
    # assertion below trivially true. 22 codes on the tree this landed on.
    assert length(emitted) >= 20,
           "read only #{length(emitted)} codes out of the source — the regex stopped matching"

    assert emitted == PrebuiltArtifact.codes()
  end

  test "the two halves are disjoint and neither is empty" do
    caller = PrebuiltArtifact.caller_fault_codes()
    internal = PrebuiltArtifact.internal_failure_codes()

    assert length(caller) > 0
    assert MapSet.disjoint?(MapSet.new(caller), MapSet.new(internal))
    assert length(caller) + length(internal) == length(PrebuiltArtifact.codes())

    # The box-side half WRITTEN OUT rather than counted. A bare `length == N` is
    # satisfied by swapping one code for another, which is the exact drift this
    # file exists to catch; and a loop over `internal_failure_codes/0` asserting
    # `internal_failure?/1` would be reading the answer back out of the thing
    # under test. So: the literal set, and a reason is owed for every edit to it.
    assert Enum.sort(internal) ==
             ~w(E_EXTRACT_EXHAUSTED E_STAGING_FAILED E_SWAP_FAILED E_WRITE_FAILED)
  end

  test "internal_failure?/1 answers for the box-side codes and NOT for the refusals" do
    for code <- ~w(E_EXTRACT_EXHAUSTED E_STAGING_FAILED E_SWAP_FAILED E_WRITE_FAILED) do
      assert PrebuiltArtifact.internal_failure?(code), "#{code} must be a BOX fault"
    end

    for code <- PrebuiltArtifact.caller_fault_codes() do
      refute PrebuiltArtifact.internal_failure?(code), "#{code} must stay a CALLER fault (400)"
    end

    # An unclassified code is NOT silently promoted to a 5xx — it keeps the old
    # 400 behaviour, and the census test above is what catches it existing.
    refute PrebuiltArtifact.internal_failure?("E_NOT_A_REAL_CODE")
  end
end
