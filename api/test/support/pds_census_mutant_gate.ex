defmodule Barkpark.PdsCensusMutantGate do
  @moduledoc """
  DOES THIS DIFF NEED THE PDS ELIXIR CENSUS'S MUTANT ARMS RE-PROVED?

  `Barkpark.PdsElixirCensusTest` spawns SIX arms, four of which are full
  842-file AST walks of `api/lib`. Two of those four are one-token MUTANTS
  (`FAIL  CLASSIFICATION-TOTAL` and `FAIL  D448-DRIFT-REFUSES`): they do not
  measure the tree, they prove the INSTRUMENT can red. On the 2-core GitHub
  runner the arms are CPU-bound, so each mutant arm is roughly half a core's
  worth of the module's ~43,6 s wall in the required `Elixir gate` Test job
  (measured on main run 33929386482, module header 23:41:47.8 -> first test
  line 23:42:31.5).

  The plain arm is the D448 drift gate and MUST run on every PR — it reads the
  live corpus, so any PR can move it. The two mutant arms read only the census
  script's own logic, so their proof needs re-earning exactly when the census
  script (or this gate, or the rider that drives it) changes.

  ## THE FAIL-SAFE DIRECTION, WHICH IS THE WHOLE DESIGN

  A skip happens ONLY on a positive, successful determination that none of the
  input globs appear in the changed set. Every other state falls through to
  RUN: a non-`pull_request` event (push to main re-proves the instrument), an
  unresolvable `HEAD^1`, a `git diff` that errors, an empty changed set. The
  failure mode of running is ~20 s of runner time; the failure mode of skipping
  wrongly is a mutation arm nobody ever watched fail — D26, the exact disease
  the rider exists to treat.

  AND A SKIP IS NEVER SILENT. `decide/1` returns the reason line the caller
  must PRINT, and that line carries the merge-base sha it was computed against,
  so a reader can reproduce the verdict with one `git diff` rather than trusting
  a green.

  ## WHY THE CHANGED SET IS DERIVED HERE AND NOT FROM A `paths:` KEY

  A workflow-level `paths:` filter would skip the JOB, which publishes a green
  required context nothing measured — the failure `.github/workflows/elixir.yml`
  documents at its dispatcher. This is the same derivation the path-escape
  ratchet's own scope step uses (elixir.yml, "Does this diff reach the
  harness?"): `HEAD^1` of the PR merge commit IS the base the PR is merged
  against, and `git diff --name-only HEAD^1 HEAD` is the changed set. `-z` and
  `--no-renames` are carried over from the dispatcher for the reasons written
  there: `--name-only` octal-escapes non-ASCII paths (a quoted path misses an
  anchored matcher and the arms are skipped for the wrong reason), and rename
  detection prints only the destination (a `git mv` of the census would read as
  "the census did not change").

  `scripts/elixir-impacted-tests.sh` was NOT reused: it reads a changed set on
  stdin and answers a different question (which ExUnit FILES to run); it does
  not derive a base. The derivation above is the ratchet's, verbatim in shape.
  """

  # THE INPUTS OF THE TWO MUTANT ARMS, AS GLOBS ON REPO-ROOT-RELATIVE PATHS.
  # `*` matches within one path segment only, so `tooling/pds/pds-census.exs`
  # does NOT match `scripts/pds-*census*` — an unanchored substring test would
  # re-arm the arms on files they do not read.
  @input_globs [
    "scripts/pds-*census*",
    "api/test/barkpark/pds_elixir_census_test.exs",
    "api/test/support/pds_census_mutant_gate.ex"
  ]

  @skip_prefix "mutant arms skipped"
  @run_prefix "mutant arms run"

  @doc "The glob set the mutant arms are gated on, in the order it is printed."
  def input_globs, do: @input_globs

  @doc "The literal prefix of a SKIP line. Asserted on, so it lives in one place."
  def skip_prefix, do: @skip_prefix

  @doc "The literal prefix of a RUN line."
  def run_prefix, do: @run_prefix

  @doc """
  `{:run, line}` or `{:skip, line}`. The line is one line and is meant to be
  printed by the caller — a skip that prints nothing is the silent green this
  gate is written to refuse.

  Options (all injectable, which is how the RUN/SKIP/git-failure arms of
  `Barkpark.PdsCensusMutantGateTest` are proved without a scratch repo):

    * `:event` — the CI event name; defaults to `GITHUB_EVENT_NAME`.
    * `:git`   — `(args :: [String.t()] -> {:ok, String.t()} | :error)`;
                 defaults to a real `git` in `:root`.
    * `:root`  — repo root for the default git runner.
  """
  def decide(opts \\ []) do
    event = Keyword.get_lazy(opts, :event, fn -> System.get_env("GITHUB_EVENT_NAME") end)
    root = Keyword.get(opts, :root, File.cwd!())
    git = Keyword.get_lazy(opts, :git, fn -> default_git(root) end)

    if event == "pull_request" do
      decide_from_diff(git)
    else
      {:run,
       "#{@run_prefix}: event #{inspect(event)} is not a pull_request — main and every " <>
         "non-PR event re-prove the instrument in full (#{globs_phrase()})"}
    end
  end

  defp decide_from_diff(git) do
    with {:ok, base_raw} <- git.(["rev-parse", "--verify", "--quiet", "HEAD^1"]),
         base = String.trim(base_raw),
         {:base, true} <- {:base, base != ""},
         {:ok, diff} <- git.(["diff", "-z", "--name-only", "--no-renames", base, "HEAD"]) do
      changed =
        diff
        |> String.split("\0", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      classify(base, changed)
    else
      _ ->
        {:run,
         "#{@run_prefix}: could not read the merge-base or the changed set from git — failing " <>
           "toward RUN, never toward a skip (#{globs_phrase()})"}
    end
  end

  defp classify(base, []) do
    {:run,
     "#{@run_prefix}: the changed set against merge-base #{base} is EMPTY (a revert pair or a " <>
       "branch-sync PR nets to nothing) — running rather than greening on a diff nobody " <>
       "measured (#{globs_phrase()})"}
  end

  defp classify(base, changed) do
    case Enum.filter(changed, &input?/1) do
      [] ->
        {:skip,
         "#{@skip_prefix}: no #{globs_phrase()} changed since merge-base #{base} — the two " <>
           "one-token mutant arms prove the census CAN red and only re-earn that proof when " <>
           "the instrument itself moves. The plain census arm (D448 drift) and the ARGV " <>
           "refusal arm ran."}

      hits ->
        {:run,
         "#{@run_prefix}: the changed set against merge-base #{base} touches the instrument — " <>
           Enum.join(hits, ", ")}
    end
  end

  defp globs_phrase, do: "input globs [" <> Enum.join(@input_globs, ", ") <> "]"

  defp input?(path), do: Enum.any?(@input_globs, &glob_match?(&1, path))

  # `*` matches any run of non-`/` bytes; everything else is literal. Anchored
  # at both ends, so a glob names a path, never a substring of one.
  defp glob_match?(glob, path) do
    pattern =
      glob
      |> String.split("*")
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("[^/]*")

    Regex.match?(Regex.compile!("\\A" <> pattern <> "\\z"), path)
  end

  defp default_git(root) do
    fn args ->
      # `git` absent from PATH RAISES rather than returning a code, and an
      # absent tool is an unreadable git state — which this gate answers with
      # RUN. The rescue lives INSIDE the closure: a rescue on the enclosing
      # function would only ever guard closure CONSTRUCTION, which cannot fail.
      try do
        case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
          {out, 0} -> {:ok, out}
          _ -> :error
        end
      rescue
        _ -> :error
      end
    end
  end
end
