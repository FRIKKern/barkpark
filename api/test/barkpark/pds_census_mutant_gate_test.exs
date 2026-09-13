defmodule Barkpark.PdsCensusMutantGateTest do
  @moduledoc """
  THE GATE PROVED IN BOTH DIRECTIONS, AND IN EVERY FAILING DIRECTION.

  `Barkpark.PdsCensusMutantGate` decides whether `Barkpark.PdsElixirCensusTest`
  spawns its two expensive one-token mutant arms. A gate that only ever RAN
  would be untested in the direction that costs money, and a gate that only ever
  SKIPPED would be a hole in a required context. So every arm below pins one
  branch of the decision, with the git layer injected — no scratch repository, no
  network, milliseconds.

  THE ASYMMETRY IS THE POINT AND IT IS ASSERTED, NOT ASSUMED: exactly ONE input
  shape produces `:skip` (a pull_request whose successfully-read, non-empty
  changed set matches none of the input globs). Every other shape — a push, an
  unreadable `HEAD^1`, an empty `HEAD^1`, a failed `git diff`, an empty changed
  set — produces `:run`. The failing-toward-run arms are the ones that matter:
  they are what stops a broken git state from greening a mutation arm nobody
  watched fail (D26).
  """
  use ExUnit.Case, async: true

  alias Barkpark.PdsCensusMutantGate, as: Gate

  @census "scripts/pds-elixir-receipt-census.exs"
  @rider "api/test/barkpark/pds_elixir_census_test.exs"
  @gate_file "api/test/support/pds_census_mutant_gate.ex"
  @base "9374e456b1945c70a1925b44136474d9ffd42b5c"

  # A git stub: `HEAD^1` resolves to @base and the diff is whatever the caller
  # names. Returning the changed paths NUL-separated is not cosmetic — the gate
  # asks git for `-z` output, so a stub that returned newlines would be proving a
  # parser the real gate never uses.
  defp git_with(changed) do
    fn
      ["rev-parse" | _] -> {:ok, @base <> "\n"}
      ["diff" | _] -> {:ok, Enum.join(changed, "\0")}
    end
  end

  defp decide(changed), do: Gate.decide(event: "pull_request", git: git_with(changed))

  describe "the diff reaches the instrument -> RUN" do
    test "the census script itself" do
      assert {:run, line} = decide([@census, "README.md"])
      assert line =~ Gate.run_prefix()
      assert line =~ @census
      assert line =~ @base
    end

    test "ANY scripts/pds-*census* program, not only the elixir receipt census" do
      for path <- [
            "scripts/pds-door-census.sh",
            "scripts/pds-ledger-census.sh",
            "scripts/pds-draft-only-task-census.sh"
          ] do
        # BOUND FIRST, THEN ASSERTED ON A BOOLEAN. `assert pattern = expr, message`
        # raises MatchError before assert/2 is ever called, so the authored message
        # is dead on exactly the path it was written for
        # (scripts/unreachable-assert-message-check.sh).
        result = decide([path])

        assert match?({:run, _}, result),
               "#{path} is in scripts/pds-*census* and must re-arm the mutant arms, got " <>
                 inspect(result)

        {:run, line} = result
        assert line =~ path
      end
    end

    test "the rider test file itself re-arms the arms" do
      assert {:run, line} = decide(["api/lib/barkpark/tasks.ex", @rider])
      assert line =~ @rider
    end

    test "the gate module itself re-arms the arms" do
      assert {:run, line} = decide([@gate_file])
      assert line =~ @gate_file
    end
  end

  describe "the diff does not reach the instrument -> SKIP, loudly" do
    test "a diff of unrelated files skips and the line names the rule and the merge-base" do
      assert {:skip, line} =
               decide(["api/lib/barkpark/tasks.ex", "js/sdk/src/index.ts", "docs/api-v1.md"])

      assert String.starts_with?(line, Gate.skip_prefix())

      assert line =~ "merge-base #{@base}",
             "a skip line with no merge-base sha cannot be reproduced by a reader"

      for glob <- Gate.input_globs() do
        assert line =~ glob, "the skip line must name every glob it checked, missing #{glob}"
      end

      assert length(String.split(line, "\n")) == 1,
             "the reason is ONE line — it is printed into a test log where a paragraph is noise"
    end

    test "the globs are anchored: a pds census OUTSIDE scripts/ does not re-arm" do
      assert {:skip, _} = decide(["tooling/pds/pds-elixir-receipt-census.exs"])
      assert {:skip, _} = decide(["api/lib/pds-census-notes.ex"])
    end

    test "the glob does not cross a path separator" do
      assert {:skip, _} = decide(["scripts/pds-sub/dir-census.sh"])
    end
  end

  describe "every unreadable state fails toward RUN" do
    test "a non-pull_request event runs all arms and never consults git" do
      exploding_git = fn _ -> flunk("git must not be consulted on a push event") end

      assert {:run, line} = Gate.decide(event: "push", git: exploding_git)
      assert line =~ "not a pull_request"
    end

    test "an absent GITHUB_EVENT_NAME (a local run) runs all arms" do
      assert {:run, _} = Gate.decide(event: nil, git: fn _ -> flunk("git not consulted") end)
    end

    test "an unreadable HEAD^1 runs" do
      git = fn
        ["rev-parse" | _] -> :error
        ["diff" | _] -> flunk("the diff must not be attempted without a base")
      end

      assert {:run, line} = Gate.decide(event: "pull_request", git: git)
      assert line =~ "could not read the merge-base"
    end

    test "an EMPTY HEAD^1 (git rev-parse --quiet prints nothing on a miss) runs" do
      git = fn
        ["rev-parse" | _] -> {:ok, "\n"}
        ["diff" | _] -> flunk("the diff must not be attempted against an empty base")
      end

      assert {:run, line} = Gate.decide(event: "pull_request", git: git)
      assert line =~ "could not read the merge-base"
    end

    test "a failing git diff runs" do
      git = fn
        ["rev-parse" | _] -> {:ok, @base}
        ["diff" | _] -> :error
      end

      assert {:run, line} = Gate.decide(event: "pull_request", git: git)
      assert line =~ "could not read the merge-base or the changed set"
    end

    test "an EMPTY changed set runs — never skips" do
      assert {:run, line} = decide([])
      assert line =~ "EMPTY"
      assert line =~ @base
    end
  end

  test "SKIP is reachable from exactly one shape, and that is what makes the arms above a control" do
    shapes = [
      {"pull_request, unrelated diff", fn -> decide(["api/lib/barkpark/tasks.ex"]) end},
      {"pull_request, census touched", fn -> decide([@census]) end},
      {"pull_request, empty diff", fn -> decide([]) end},
      {"push", fn -> Gate.decide(event: "push", git: git_with([])) end},
      {"no base", fn -> Gate.decide(event: "pull_request", git: fn _ -> :error end) end}
    ]

    skips = for {name, f} <- shapes, match?({:skip, _}, f.()), do: name

    assert skips == ["pull_request, unrelated diff"],
           "exactly one input shape may skip; got #{inspect(skips)}"
  end

  test "the gate's real git runner answers about THIS repo without raising" do
    # NOT an assertion about which verdict this checkout produces — a worktree's
    # HEAD^1 is whatever it is. What is asserted is that the default runner is
    # wired to a real git, returns one of the two shapes, and never raises.
    root = Path.expand("../../..", __DIR__)

    assert {decision, line} = Gate.decide(event: "pull_request", root: root)
    assert decision in [:run, :skip]
    assert is_binary(line) and line != ""
  end
end
