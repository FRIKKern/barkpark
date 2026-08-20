defmodule Barkpark.Sites.DeployymlConnectorsPathfilterTest do
  @moduledoc """
  `.github/workflows/deploy.yml` must both START on and TARGET a merge under
  `scripts/connectors/**` — pinned on a lane that can actually BLOCK the change
  that would break it (charter D275, Connectors W35).

  THE GAP. `instance-deploy.sh` installs the cloud-sandbox-runner FROM
  `scripts/connectors/` onto the content instance. But that tree was listed in
  NEITHER `deploy.yml`'s `on.push.paths` NOR the `changes` job's instance
  regex, so a runner-only merge (a `.mjs` or preflight change) landed on `main`
  and never reached guerrilla — the host kept serving the old runner until an
  unrelated deploy-triggering merge rode by. It was byte-identical to prod only
  by that piggyback, never by its own deploy.

  TWO GUARDS, ONE REQUIRED. `scripts/check-deployyml-filters.sh` (the drift +
  required-path-presence gate) is the fast local half, but it rides
  `doc-gates.yml`, which is NOT a required status check — the required set is
  `Elixir gate`, `PR references an active task`, `Cloud gate`, `Console gate`
  (measured via the branch-protection API 2026-08-17). A shell-only guard is
  therefore advisory and cannot block a merge. This file is the durable half:
  it runs on the REQUIRED Elixir lane, which fires on `api/**` — so a PR that
  strips `scripts/connectors/**` from the workflow AND touches `api/**` still
  reds here. (The precedent is `deploy_runner_stage_names_test.exs`, which pins
  a deploy doctrine on this same lane for the same reason.)

  Every read below is FAIL-CLOSED: a moved workflow, a reshaped `on.push.paths`
  block, or an instance regex that no longer matches `scripts/connectors/…`
  reds this test rather than passing vacuously — that silent skip is exactly
  the failure mode this file exists to end.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @deploy_yml Path.join(@repo_root, ".github/workflows/deploy.yml")
  @required_path "scripts/connectors/**"

  defp read!(path) do
    assert File.exists?(path),
           "expected #{path} to exist — this test pins its contents, and a missing " <>
             "file must RED here, never silently skip (that silent skip is exactly " <>
             "the defect this file was added to close)"

    File.read!(path)
  end

  # The `on.push.paths` block only: from the `paths:` key under `on:` up to the
  # next top-level (`concurrency:`, column 0) key. Mirrors the shell gate's
  # awk boundary so a `paths:` elsewhere in the file cannot widen the set.
  defp push_paths_block(source) do
    assert [_, block] =
             Regex.run(~r/^\s+paths:\n(.*?)\n[a-z]/ms, source),
           "could not locate the on.push.paths block in #{@deploy_yml}; if `on:` was " <>
             "reshaped, update this pin deliberately — do not let it pass vacuously"

    block
  end

  # The regex feeding `instance=true` in the `changes` job — captured back so we
  # can RUN it against a sample path, not just string-match it.
  defp instance_regex(source) do
    assert [_, ere] =
             Regex.run(
               ~r/grep -qE '([^']+)';\s*then echo "instance=true"/,
               source
             ),
           "could not find the `grep -qE '…'; then echo \"instance=true\"` dispatch " <>
             "line in #{@deploy_yml}; if the changes job was reshaped, update this " <>
             "pin deliberately rather than let the guard go vacuous"

    ere
  end

  describe "scripts/connectors/** reaches the instance deploy" do
    test "on.push.paths lists scripts/connectors/** so a runner-only merge STARTS the workflow" do
      block = push_paths_block(read!(@deploy_yml))

      assert block =~ ~r/^\s*-\s*"scripts\/connectors\/\*\*"\s*$/m,
             """
             deploy.yml's on.push.paths no longer lists #{inspect(@required_path)}.

             instance-deploy.sh installs the cloud-sandbox-runner from
             scripts/connectors/, so a merge touching only that tree must START
             this workflow. Without the entry the merge lands on main and never
             deploys — the exact gap Connectors W35 (charter D275) closed.

             Restore the `- "#{@required_path}"` entry under on.push.paths, or, if
             this is intended, update this test and the charter.
             """
    end

    test "the changes-job instance regex TARGETS scripts/connectors/ (behavioural, exact-prefix)" do
      ere = instance_regex(read!(@deploy_yml))

      # The path glob's representative sample — what `git diff --name-only`
      # actually emits and the regex is run against in the workflow.
      {:ok, compiled} = Regex.compile(ere)

      assert Regex.match?(compiled, "scripts/connectors/cloud-sandbox-runner.mjs"),
             """
             the instance regex does not match a scripts/connectors/ change.

             regex: #{ere}

             Starting the workflow (on.push.paths) is only half the fix — the
             changes job's instance filter must also flip instance=true, or the
             run deploys NOTHING and still reports green. Add `scripts/connectors`
             to the alternation, e.g.
             ^(api|internal|deploy|connectors|templates|scripts/connectors)/.
             """

      # Exact-prefix proof: the entry is `scripts/connectors`, not bare
      # `scripts`, so an unrelated scripts/ change must NOT falsely deploy.
      refute Regex.match?(compiled, "scripts/other/thing.sh"),
             """
             the instance regex matches scripts/other/ — the prefix is too broad.

             regex: #{ere}

             It must be the exact prefix `scripts/connectors`, so scripts/other/
             (and any other scripts/ subtree) does NOT flip instance=true.
             """
    end

    test "the shell gate still carries scripts/connectors/** as a required path (both halves present)" do
      # The shell half is the fast local guard. It is unreachable from an
      # api/**-only PR, which is why THIS file exists — but if someone deletes
      # its required-path allowlist, that half is gone and this test should say
      # so rather than let the coverage quietly halve.
      gate = read!(Path.join(@repo_root, "scripts/check-deployyml-filters.sh"))

      assert gate =~ ~r/REQUIRED_PATHS=\([^)]*"scripts\/connectors\/\*\*"/s,
             "scripts/check-deployyml-filters.sh lost scripts/connectors/** from its " <>
               "REQUIRED_PATHS allowlist — the shell half of the W35 guard. Restore " <>
               "it or record the removal."
    end
  end
end
