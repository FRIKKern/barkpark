defmodule BarkparkCloud.Templates.StandaloneExportTest do
  @moduledoc """
  Puts `scripts/export-template-repo.test.mjs` (dwb-2) under the REQUIRED
  `Cloud gate`.

  The exporter turns the `create-barkpark-app` starters into the trees of the
  standalone `template-blog` / `template-website` repositories the Vercel clone
  handoff and the deploy worker clone (templates/STANDALONE-REPOS.md). Its
  inputs — `js/packages/create-barkpark-app/templates/**`, `templates/**`,
  `scripts/**` — are all in cloud.yml's dispatched path set
  (`scripts/cloud-path-escape-check.sh` CLOUD_PATHS), so a PR that edits a
  starter runs this and learns on THAT PR whether the standalone tree still
  holds: deterministic, schema-valid manifest, vercel.json consistent with the
  framework, nothing escaping the tree, no `workspace:` specifier.

  The node suite does the asserting; this module runs it and PINS THE EXACT
  PASS COUNT. `# fail 0` alone would read green on a suite that silently ran
  fewer tests (a deleted template, a loop that iterated nothing); an exact
  count cannot. Change `@expected_pass` in the same commit that changes the
  suite, and say why.
  """
  use ExUnit.Case, async: true

  # 6 whole-run tests + 5 per template x 2 templates.
  @expected_pass 16

  # A module attribute on purpose: scripts/selftest-wiring-census.sh (route R4)
  # finds this door by an `@…_path` line naming the suite's basename.
  @suite_path Path.expand("../../../../scripts/export-template-repo.test.mjs", __DIR__)

  test "the standalone template export suite passes with its exact test count" do
    node = System.find_executable("node")

    # A guard that cannot run must RED, never skip. cloud.yml installs node
    # with actions/setup-node@v4 for this job.
    assert node, "node is not on PATH — the standalone template export gate cannot run"

    script = @suite_path

    assert File.exists?(script), "the export gate is missing at #{script}"

    {out, status} = System.cmd(node, [script], stderr_to_stdout: true)

    pass = count(out, ~r/^# pass (\d+)$/m)
    fail = count(out, ~r/^# fail (\d+)$/m)

    assert status == 0 and fail == 0,
           "export-template-repo.test.mjs failed (exit #{status}, #{fail} failing):\n#{out}"

    assert pass == @expected_pass,
           "export-template-repo.test.mjs passed #{inspect(pass)} tests, pinned #{@expected_pass} — " <>
             "a test was added or silently lost:\n#{out}"
  end

  defp count(out, re) do
    case Regex.run(re, out) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end
end
