defmodule Barkpark.DocBudgetCapTest do
  @moduledoc """
  The doc byte caps in `scripts/check-doc-budgets.sh` had NO BLOCKING READER,
  and a capped file went over on main because of it.

  MEASURED on origin/main b54cb063d (2026-09-13): `docs/setup/TASK-SYSTEM.md` was
  16_043 B against the 16_000 B cap its own table declares, and
  `docs/api/error-codes.md` 2_154 B against 1_900 B. Both arrived through merged
  PRs (TASK-SYSTEM via #17878 f072865bb 15_947 -> 16_450, #17984 9843bb2bc ->
  16_532, #17979 746e39ebd -> 16_043) and nothing refused any of them.

  RE-MEASURED on origin/main e029337793 (2026-09-13, after #18126 921500955 and
  #18143 50ceb5f67 trimmed both docs): `bash scripts/check-doc-budgets.sh` exits 0
  with no FAIL line, TASK-SYSTEM.md is 15_270 B and error-codes.md 1_791 B, and
  this case is GREEN (4 tests, 0 failures). The breaches are gone; the hole that
  let them land is not. This guard is therefore preventive, so each of its arms is
  proven by a mutation rather than by a live breach -- see the arm notes below.

  ## Why HERE and not in doc-gates.yml

  The caps ARE checked -- by `Doc budgets + anchors`, which cannot block. From
  `.github/required-checks.json`:

      { "context": "Doc budgets + anchors",
        "reason": "S4 PATHS-FILTERED: doc-gates.yml only runs on matching paths,
                   so on other PRs this name is ABSENT - a required absent
                   context never reports" }

  The required set is exactly four names (Cloud gate, Console gate, Elixir gate,
  PR references an active task). A guard that lives only in a paths-filtered
  advisory workflow can never refuse a merge, so the caps were documentation
  wearing a gate's name. This case rides the already-required `Elixir gate`
  without touching a byte of `.github/` -- the same route, for the same reason,
  as `api/test/barkpark/pds_meter_rider_test.exs` next door.

  ## The `../../../scripts/check-doc-budgets.sh` STRING LITERAL is load-bearing

  `scripts/elixir-path-escape-check.sh` resolves exactly these literals to build
  its census of repo-root reads and reds unless each is declared in a dispatched
  path set. A path one binding away from its `Path.join` is invisible to that
  scanner. Written inline, the declaration and the read are provably the same
  path. It is declared in ELIXIR_TEST_ONLY_PATHS, not ELIXIR_COMPILE_PATHS,
  because nothing here is an `@external_resource`: the table is read at TEST
  RUNTIME by `File.read!/1`. Putting a runtime-only read in the compile set
  would be a lie in the other direction, and putting a compile-time resource in
  the test-only set would let an edit skip the compile lane and green vacuously.

  ## Three arms, and why the third exists

    * `refuses a vacuous parse` -- the row count is asserted NON-ZERO and equal
      to the script's own hand-pinned `CAPS_ROWS_EXPECTED`. A broken heredoc
      makes both sides of a naive walk zero and the check agrees with itself;
      that is the exact shape this repo has been bitten by repeatedly.
    * `every capped doc is within its cap` -- the invariant itself.
    * `every capped path is dispatched on` -- WITHOUT THIS THE LOCK IS FAKE.
      elixir.yml's `mix-test` job carries `if: needs.changes.outputs.test ==
      'true'`, so a PR touching only an undeclared doc SKIPS this suite, and a
      skipped job counts as PASSING for a required context. The cap table would
      then be enforced on every PR except the ones that edit a capped doc. So
      the test set must be a SUPERSET of the cap table, and this arm is what
      keeps a newly added cap row from silently landing outside the dispatch.

  ## Each arm was RED under its own mutation on e029337793 (2026-09-13)

  Baseline on the rebased branch: 4 tests, 0 failures. Then, one mutation at a
  time, reverted after each:

    * cap arm -- appended 911 B to `docs/cheatsheets/bp.md` (2_387 -> 3_298 B
      against a 2_400 B cap): 4 tests, 1 failure, naming
      "docs/cheatsheets/bp.md: 3298 B > cap 2400 B (over by 898 B)".
    * vacuity floor -- renamed the heredoc opener to `done <<'CAPSX'` so the
      walker matches nothing: 4 tests, 1 failure on "parsed ZERO budget rows",
      NOT a green zero-violation report. The cap arm passed vacuously in that
      run, which is precisely what the floor exists to catch.
    * row-count -- deleted the `docs/cheatsheets/papers.md 2400` row, left
      `CAPS_ROWS_EXPECTED=39`: 4 tests, 1 failure on "parsed 38 budget row(s)
      but the script pins CAPS_ROWS_EXPECTED=39".
    * dispatch arm -- added a `docs/setup/SETUP.md 99999` row and bumped the pin
      to 40: 4 tests, 1 failure naming `docs/setup/SETUP.md` as not matched by
      any dispatched path set.
    * the declaration itself -- deleted `scripts/check-doc-budgets.sh` from
      ELIXIR_TEST_ONLY_PATHS: `bash scripts/elixir-path-escape-check.sh` exits 1
      with "UNCOVERED repo-root read: scripts/check-doc-budgets.sh / read from:
      api/test/barkpark/doc_budget_cap_test.exs".

  ## What this case does NOT lock

  `check-doc-budgets.sh` enforces two things. The `CAPS` heredoc (39 rows) is
  what this case reads. Its OTHER arm -- header discovery, which walks
  `docs/**.md` and enforces each file's own `budget: Ntok` header -- is not read
  here and stays advisory-only. `docs/api/conflict-409-resolution.md` (added by
  #18143) is a discovery-only doc: it carries no `CAPS` row, which is why the
  36 declared doc paths and `CAPS_ROWS_EXPECTED=39` did not move for it.
  """
  use ExUnit.Case, async: true

  @budgets_rel "../../../scripts/check-doc-budgets.sh"
  @dispatch_rel "../../../scripts/elixir-path-escape-check.sh"

  setup_all do
    root = Path.expand("../../..", __DIR__)

    budgets_source = @budgets_rel |> Path.expand(__DIR__) |> File.read!()
    dispatch_source = @dispatch_rel |> Path.expand(__DIR__) |> File.read!()

    {:ok,
     root: root,
     rows: parse_caps_table(budgets_source),
     expected_rows: parse_expected_row_count(budgets_source),
     dispatch_globs: parse_dispatch_globs(dispatch_source)}
  end

  describe "the doc byte-cap table" do
    test "refuses a vacuous parse", ctx do
      assert ctx.expected_rows > 0,
             "CAPS_ROWS_EXPECTED did not parse out of #{@budgets_rel}; " <>
               "a guard that cannot find the pin cannot police the table."

      assert length(ctx.rows) > 0,
             "parsed ZERO budget rows out of #{@budgets_rel}. A parse that " <>
               "yields nothing reports zero violations and exits green — that " <>
               "is the vacuous pass this arm exists to refuse."

      assert length(ctx.rows) == ctx.expected_rows,
             "parsed #{length(ctx.rows)} budget row(s) but the script pins " <>
               "CAPS_ROWS_EXPECTED=#{ctx.expected_rows}. Either this parser " <>
               "went blind to part of the table, or a cap row was added or " <>
               "removed without bumping the pin."
    end

    test "every capped doc is within its cap", ctx do
      over =
        for {path, cap} <- ctx.rows,
            size = file_size(ctx.root, path),
            is_integer(size),
            size > cap,
            do: "  #{path}: #{size} B > cap #{cap} B (over by #{size - cap} B)"

      assert over == [],
             "capped doc(s) OVER budget:\n" <>
               Enum.join(over, "\n") <>
               "\n\nThe remedy is to split to the owning contract/runbook or " <>
               "retire content — never raise the cap (repo-root CLAUDE.md, " <>
               "Doc contract). The cap table lives in #{@budgets_rel}."
    end

    test "every capped path is dispatched on, so this suite actually runs", ctx do
      undispatched =
        for {path, _cap} <- ctx.rows,
            not Enum.any?(ctx.dispatch_globs, &glob_matches?(&1, path)),
            do: "  #{path}"

      assert undispatched == [],
             "capped doc(s) NOT in any dispatched path set of #{@dispatch_rel}:\n" <>
               Enum.join(undispatched, "\n") <>
               "\n\nelixir.yml's mix-test job carries " <>
               "`if: needs.changes.outputs.test == 'true'`, and a skipped job " <>
               "counts as PASSING for a required context. A PR that edits only " <>
               "one of these paths would skip this suite entirely, so the cap " <>
               "would not be enforced on exactly the change that breaks it. " <>
               "Declare the path in ELIXIR_TEST_ONLY_PATHS."
    end

    test "the missing doc is a red, not a skip", ctx do
      missing = for {path, _cap} <- ctx.rows, file_size(ctx.root, path) == nil, do: "  #{path}"

      assert missing == [],
             "cap row(s) naming a file that does not exist:\n" <>
               Enum.join(missing, "\n") <>
               "\n\nA cap on a deleted file is a row that can never fail; " <>
               "remove the row and bump CAPS_ROWS_EXPECTED."
    end
  end

  # --- parsing -------------------------------------------------------------
  #
  # The table is a quoted heredoc (`<<'CAPS'` … `CAPS`) fed to a `while read -r
  # path cap` loop, and the loop itself skips empty lines. This parser mirrors
  # that contract exactly, so "what the parser walked" and "what the gate
  # verdicts on" are the same set — which is what makes the CAPS_ROWS_EXPECTED
  # comparison above meaningful rather than two numbers agreeing by luck.

  defp parse_caps_table(source) do
    source
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "done <<'CAPS'"))
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 != "CAPS"))
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), ~r/\s+/, trim: true) do
        [path, cap] ->
          case Integer.parse(cap) do
            {n, ""} -> [{path, n}]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  defp parse_expected_row_count(source) do
    case Regex.run(~r/^CAPS_ROWS_EXPECTED=(\d+)$/m, source) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  # Both declared sets count: ELIXIR_COMPILE_PATHS is a strict subset of what
  # `--dispatch test` emits (the script prints COMPILE ++ TEST_ONLY for the test
  # lane), so a path in either one dispatches mix-test.
  defp parse_dispatch_globs(source) do
    ~w(ELIXIR_COMPILE_PATHS ELIXIR_TEST_ONLY_PATHS)
    |> Enum.flat_map(fn var ->
      case Regex.run(~r/^#{var}='([^']*)'/m, source) do
        [_, body] -> String.split(body, "\n", trim: true)
        _ -> []
      end
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # `**` is the only wildcard these sets use, and it always terminates the
  # pattern (`api/**`, `web/lib/**`). Anything else is an exact path.
  defp glob_matches?(glob, path) do
    case String.split(glob, "/**") do
      [prefix, ""] -> path == prefix or String.starts_with?(path, prefix <> "/")
      _ -> glob == path
    end
  end

  defp file_size(root, rel) do
    case File.stat(Path.join(root, rel)) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> nil
    end
  end
end
