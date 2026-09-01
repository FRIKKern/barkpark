defmodule Barkpark.Sites.DeployRunnerStageNamesTest do
  @moduledoc """
  The `@stage_names` doctrine (charter D327/D346), pinned on a lane that can
  actually BLOCK the change that would break it.

  Both deploy engines already assert this — `deploy/site-deploy.sh` and
  `deploy/site-deploy-node.sh` grep the attribute out of `deploy_runner.ex`
  during `--self-test`, and the assertion works: adding `ROUTE` reds it. But
  those rows ride `.github/workflows/deploy-harnesses.yml`, whose `paths:`
  filter is `deploy/**` only. A PR that adds `ROUTE` to `@stage_names` touches
  no `deploy/**` path, so the only guard on the doctrine NEVER FIRES on the
  exact change it exists to catch — and `Deploy harnesses` is not a required
  status check anyway (the required set is `Elixir gate`, `PR references an
  active task`, `Cloud gate`, `Console gate`), so it could not block a merge
  even when it did run.

  This file is the durable half FOR THE `@stage_names` ATTRIBUTE ONLY — it
  runs on the REQUIRED Elixir lane, which fires on `api/**`, the very tree the
  attribute lives in. It is NOT the durable half for the two engines' own
  `--self-test` assertions: those still ride only
  `.github/workflows/deploy-harnesses.yml` (`deploy/**`-filtered, not a
  required check), unchanged by anything here. What this file's `@engines`
  reads (`deploy/site-deploy.sh`, `deploy/site-deploy-node.sh`, both via the
  `Path.expand(@repo_root, __DIR__)` root-anchor idiom above) DOES buy: until
  `elixir-path-escape-check.sh` learned to see that idiom, those two reads —
  plus `.github/workflows/deploy.yml` and `scripts/check-deployyml-filters.sh`
  read by this file's sibling `deployyml_connectors_pathfilter_test.exs` —
  were UNDECLARED to the REQUIRED Elixir gate's dispatcher: a PR touching only
  `deploy/site-deploy.sh` could skip the suite and still report green, with
  neither this pin nor the engines' own self-test able to fire. Declaring the
  four paths in `ELIXIR_TEST_ONLY_PATHS` makes THIS file's own pins durable
  against changes to the files they read — it does not make the shell
  engines' internal self-tests required; that remains advisory via
  deploy-harnesses.yml. The cost: every `deploy/**` PR now runs the full
  Elixir suite (9m31s-16m29s per that workflow's own note) — paid once here,
  for a doctrine whose only other guard could not block a merge at all.

  The four-path declaration is a LOWER BOUND, not a closed set: it covers the
  literal + root-anchor idioms `elixir-path-escape-check.sh` can see. An
  interpolated anchor (`Path.expand("../\#{x}", __DIR__)`), the list form
  `Path.join([root, a, b])`, and an execution-cwd read via
  `System.cmd(_, cd: root)` (used by
  `api/test/barkpark/pds_door_census_test.exs`, a separate class this
  widening does not close) remain invisible to it.

  WHY THE DOCTRINE MATTERS. `ROUTE` is a REPORT, not a verdict. Both engines
  emit `BPSTAGE name=ROUTE …` on a real deploy; `parse_stage_line/2` folds a
  line into `stages` only when its name is in `@stage_names`, and a folded
  failed stage reaches `stage_exit_code/1`, whose catch-all is `-1`. So the day
  `ROUTE` joins that whitelist, an unarmed Caddy route stops being a loud
  report on a green run and starts turning green deploys red through the
  fallthrough exit code — a verdict change nobody asked for.

  This is a SOURCE pin, deliberately: `@stage_names` is a compile-time module
  attribute with no runtime accessor, and `parse_stage_line/2` is private, so
  the attribute's value cannot be read back from the loaded module without
  editing `deploy_runner.ex` itself. Every read below is FAIL-CLOSED — a moved
  file or a reshaped attribute reds this test rather than passing vacuously,
  which is the whole failure mode this file was written to end.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @runner_ex Path.join(@repo_root, "api/lib/barkpark/sites/deploy_runner.ex")
  @engines [
    Path.join(@repo_root, "deploy/site-deploy.sh"),
    Path.join(@repo_root, "deploy/site-deploy-node.sh")
  ]

  defp read!(path) do
    assert File.exists?(path),
           "expected #{path} to exist — this test pins its contents, and a missing " <>
             "file must RED here, never silently skip (that silent skip is exactly " <>
             "the defect this file was added to close)"

    File.read!(path)
  end

  describe "@stage_names whitelist" do
    test "is exactly the six stages the engines fold, in order" do
      source = read!(@runner_ex)

      scan = Regex.scan(~r/^\s*@stage_names\s+~w\(([^)]*)\)\s*$/m, source)

      assert match?([[_, _]], scan),
             "expected exactly ONE `@stage_names ~w(...)` line in #{@runner_ex}; " <>
               "if the attribute was renamed or reshaped, this pin (and the two " <>
               "deploy engines' self-test rows that grep the same line) must be " <>
               "updated deliberately, not deleted (got #{inspect(scan)})"

      [[line, names]] = scan

      assert String.split(names) == ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE),
             """
             @stage_names changed.

             got:      #{inspect(String.split(names))}
             expected: #{inspect(~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE))}
             line:     #{String.trim(line)}

             Only stages that are a VERDICT belong here. A name added to this
             whitelist starts being folded by parse_stage_line/2 into `stages`,
             and a failed folded stage reaches stage_exit_code/1 — whose
             catch-all returns -1. Adding a report-only stage (ROUTE) therefore
             converts a loud report on a green run into a red deploy.

             If this change is intended, update this test, both deploy engines'
             self-test rows, and say so in the charter.
             """
    end

    test "does not contain ROUTE — the arm report must never become a verdict" do
      names =
        read!(@runner_ex)
        |> then(
          &Regex.run(~r/^\s*@stage_names\s+~w\(([^)]*)\)\s*$/m, &1, capture: :all_but_first)
        )

      assert [captured] = names
      refute "ROUTE" in String.split(captured)
    end

    test "the doctrine has teeth: both engines really emit a ROUTE stage line" do
      for engine <- @engines do
        source = read!(engine)

        assert source =~ ~r/^\s*emit ROUTE /m,
               "#{engine} no longer emits a ROUTE stage line. If ROUTE is gone from " <>
                 "the wire the @stage_names pin above is inert — either restore the " <>
                 "emitter or retire the doctrine deliberately."
      end
    end

    test "the deploy engines still carry their own copy of this assertion" do
      # The shell rows are the fast, local half (they run on `--self-test` on a
      # laptop). They are unreachable from an api/**-only PR, which is why this
      # file exists — but if someone deletes them, that half is gone and this
      # test should say so rather than let the coverage quietly halve.
      for engine <- @engines do
        assert read!(engine) =~ "@stage_names .*ROUTE",
               "#{engine} lost its `@stage_names` self-test row — the shell half of " <>
                 "the D327 doctrine guard. Restore it or record the removal."
      end
    end
  end
end
