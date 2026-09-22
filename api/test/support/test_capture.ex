defmodule Barkpark.TestCapture do
  @moduledoc """
  Refuse to read an ExUnit capture that cannot be read
  (task-71dd1eb49e334fbb, acceptance criterion 2).

  ## The second failure mode, which is NOT pollution

  The same session that measured shared-database pollution also measured
  something different and worse. A run of `test/barkpark/content/` printed

      1911 tests, 2 failures

  into an output file that carried NO `Randomized with seed …` line and NO
  failure bodies — a capture garbled under a shared build. A clean re-run of the
  SAME directory read `1764 tests, 0 failures`. The 2 failures were never
  explained, because there was nothing in the file to explain them WITH.

  That is not a run that found two problems. It is a MEASUREMENT THAT CANNOT BE
  READ, and on the terminal it is indistinguishable from a real two-failure
  result: same summary line, same shape, same plausibility. A builder reads "2
  failures" and starts looking for two bugs.

  ## The rule

  An ExUnit run emits a seed line — `Running ExUnit with seed: N, max_cases: M`
  at the TOP of the run in this project's version, or `Randomized with seed N`
  at the BOTTOM in others — then one numbered body per failure
  (`  1) test … `), then one summary (`N tests, M failures`). Three consistency
  facts follow, and each is checked here:

    1. A summary with NO seed line is a capture that lost its head. ExUnit prints
       a seed line on every run; `--seed 0` disables the shuffle but still prints
       it. Its absence means bytes are missing, and the bytes that are missing
       are not necessarily only the ones before the seed.

       BOTH SPELLINGS ARE MATCHED, and that is not pedantry: a reader that knew
       only `Randomized with seed` would call EVERY capture from this repo
       unusable. That is the same defect as calling a garbled capture usable,
       pointed the other way, and the first live run of this module is what
       showed which spelling this ExUnit actually emits.
    2. `M failures` with fewer than M numbered failure bodies is a capture that
       lost its middle. You cannot attribute a failure you cannot see.
    3. NO summary line at all is a capture that lost its tail — the run may not
       have finished.

  In all three cases `read/1` returns `{:unusable, reasons}`. It never returns a
  failure count it cannot stand behind. The caller's correct move is to re-run,
  not to investigate.

  ## Using it on a capture file

      cd api
      MIX_ENV=test mix run -e \\
        'IO.puts(Barkpark.TestCapture.describe(File.read!("/tmp/run.txt")))'

  `describe/1` prints one line starting with `USABLE` or `UNUSABLE`, which is
  what a PR body or a task-criterion evidence string should quote.
  """

  # TWO spellings, both real. This project's ExUnit prints
  # `Running ExUnit with seed: 343107, max_cases: 8` at the TOP of the run;
  # older/other configurations print `Randomized with seed 343107` at the
  # BOTTOM. A reader that knew only one of them would call every capture from
  # this repo unusable — which is the same defect as calling a garbled one
  # usable, pointed the other way.
  @seed_re ~r/^(?:Running ExUnit with seed: |Randomized with seed )(\d+)/m
  # ExUnit's summary may be prefixed with doctest/property counts
  # ("5 doctests, 1911 tests, 2 failures") and suffixed with excluded/skipped
  # counts. Anchor on the `N tests, M failures` pair only.
  @summary_re ~r/^.*?(\d+) tests?, (\d+) failures?/m
  @body_re ~r/^\s*\d+\) (?:test|doctest|property) /m

  @doc """
  Classify a capture. Returns `{:ok, %{tests:, failures:, seed:, bodies:}}` or
  `{:unusable, reasons}` where reasons is a non-empty list of atoms.
  """
  def read(text) when is_binary(text) do
    summary = Regex.run(@summary_re, text)
    seed = Regex.run(@seed_re, text)
    bodies = length(Regex.scan(@body_re, text))

    # NOT `List.wrap(cond && reason)`. `List.wrap(false)` is `[false]`, not
    # `[]` — it only special-cases nil and lists — so every usable capture came
    # back `{:unusable, [false, false]}`. The tests caught it here and the same
    # mistake in `Barkpark.SharedTestDb.drift_findings/1`; it is written out
    # because it fails in the direction that looks like a working detector.
    reasons =
      Enum.reject(
        [
          summary == nil && :no_summary_line,
          seed == nil && :no_seed_line,
          missing_bodies(summary, bodies)
        ],
        &(&1 in [nil, false])
      )

    case reasons do
      [] ->
        [_, tests, failures] = summary
        [_, seed_value] = seed

        {:ok,
         %{
           tests: String.to_integer(tests),
           failures: String.to_integer(failures),
           seed: String.to_integer(seed_value),
           bodies: bodies,
           exit_cause: exit_cause(text)
         }}

      reasons ->
        {:unusable, reasons}
    end
  end

  # A capture can be perfectly READABLE and still not explain its own exit code.
  # `test_helper.exs` arms `System.at_exit(exit {:shutdown, 1})` on a leaked
  # node-global, so a run prints `0 failures` and exits 1. That is not a garbled
  # measurement — the counts are real — so it is not `:unusable`. It is a
  # summary that must not be quoted ALONE, and `describe/1` refuses to quote it
  # alone.
  @exit_cause_markers [
    {~r/^NODE-GLOBAL LEAK: :barkpark, :boot_mode/m,
     "a NODE-GLOBAL LEAK banner (`:barkpark, :boot_mode`) — the run exits non-zero whatever the failure count says"},
    {~r/^EXIT-CAUSE: /m,
     "an EXIT-CAUSE line naming a non-zero exit the failure count does not explain"}
  ]

  defp exit_cause(text) do
    Enum.find_value(@exit_cause_markers, fn {re, why} ->
      if Regex.match?(re, text), do: why
    end)
  end

  defp missing_bodies(nil, _bodies), do: nil

  defp missing_bodies([_, _tests, failures], bodies) do
    failures = String.to_integer(failures)
    if failures > 0 and bodies < failures, do: {:failure_bodies_missing, bodies, failures}
  end

  @doc """
  A single quotable line. Starts with `USABLE` or `UNUSABLE`.
  """
  def describe(text) do
    case read(text) do
      {:ok, %{tests: t, failures: f, seed: s, exit_cause: nil}} ->
        "USABLE: #{t} tests, #{f} failures (seed #{s})"

      {:ok, %{tests: t, failures: f, seed: s, exit_cause: why}} ->
        "USABLE BUT THE EXIT CODE IS NOT THE FAILURE COUNT: #{t} tests, #{f} failures (seed #{s}) — " <>
          "this capture also carries #{why}. Quote both or neither."

      {:unusable, reasons} ->
        "UNUSABLE: #{Enum.map_join(reasons, "; ", &reason_text/1)} — " <>
          "this capture carries no result. Re-run; do not investigate its failure count."
    end
  end

  defp reason_text(:no_seed_line),
    do:
      "no ExUnit seed line (`Running ExUnit with seed:` / `Randomized with seed`), " <>
        "so this capture lost bytes and any count in it is unattributable"

  defp reason_text(:no_summary_line),
    do: "no `N tests, M failures` summary, so the run did not finish or its tail is missing"

  defp reason_text({:failure_bodies_missing, got, want}),
    do: "summary claims #{want} failure(s) but the capture carries #{got} failure body/bodies"
end
