defmodule BarkparkCloud.FailureCopyScrubLockTest do
  @moduledoc """
  THE CLOUD HALF OF THE CROSS-APP SCRUB LOCK.

  `cloud/priv/secret-scrub.exs` is the ONE secret-pattern set, compiled by two
  OTP apps that cannot depend on each other: this app's display boundary
  (`BarkparkCloud.FailureCopy`) and the box's recorded-log write boundary
  (`Barkpark.Sites.BuildLogScrub`, `api/`). The sibling of this file is
  `api/test/barkpark/sites/build_log_scrub_lock_test.exs`, and it asserts the
  same two things against the same bytes.

  WHAT EACH ARM ACTUALLY CATCHES — stated, because one of them is weaker than it
  looks:

    * THE SET ARM (source/opts/replacement identity) is inert against an edit to
      the fixture: the fixture recompiles the module, so both sides move
      together. It catches the ONE thing it is for — a table re-inlined into the
      module, i.e. the second, drifting copy this lock exists to forbid.

    * THE VECTOR ARM is the behaviour lock and is NOT inert: the fixture carries
      expected OUTPUT bytes, so deleting or weakening a clause reds here (and
      reds identically in the api suite, which is what makes the two engines
      provably agree rather than merely share a table).
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.FailureCopy

  @fixture Path.expand("../../priv/secret-scrub.exs", __DIR__)

  setup_all do
    {:ok, scrub: @fixture |> Code.eval_file() |> elem(0)}
  end

  defp shape(patterns) do
    Enum.map(patterns, fn {regex, replacement} ->
      {Regex.source(regex), Regex.opts(regex), replacement}
    end)
  end

  test "the fixture is not empty — the control on every assertion below", %{scrub: scrub} do
    # An empty table would make the identity arm pass vacuously and every
    # negative vector pass by doing nothing. Print the sizes into the failure.
    assert length(scrub.patterns) >= 6,
           "the shared pattern set shrank: #{inspect(scrub.patterns)}"

    assert scrub.vectors != []
    assert scrub.redaction == "[redacted]"
    assert String.contains?(scrub.ansi_run, "\x1B")
  end

  test "the compiled set IS the file's set — no second table in this module", %{scrub: scrub} do
    assert shape(FailureCopy.compiled_secret_patterns()) == shape(scrub.patterns)
    assert FailureCopy.compiled_ansi_run() == scrub.ansi_run
  end

  test "every shared vector folds to the shared expected bytes", %{scrub: scrub} do
    for {label, input, expected} <- scrub.vectors do
      assert FailureCopy.raw(input) == expected, "vector: #{label}"
    end
  end

  test "the vectors are a real corpus — one of them carries our own PAT shape", %{scrub: scrub} do
    # Named so a future edit cannot quietly reduce the corpus to negatives, which
    # would leave the behaviour arm green while redacting nothing.
    assert Enum.any?(scrub.vectors, fn {_label, input, expected} ->
             String.contains?(input, "bppat_") and String.contains?(expected, "[redacted]")
           end)
  end
end
