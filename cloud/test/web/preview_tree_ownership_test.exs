defmodule BarkparkCloud.Web.PreviewTreeOwnershipTest do
  @moduledoc """
  `cloud/priv/static/__preview__/` — the dev-only SPA preview harness — was for
  months claimed by NO charter: it is neither the `app.js` surface nor
  `__fixtures__/`, and the two epics that work in it had each ruled on the
  neighbours and on nothing else. The deploy-reliability charter's D402 settled
  it by cession ("the fence that IS real: `cloud/priv/static/app.js` +
  `__app.test.mjs` + `__preview__/*`", ceded to console), and
  `scenarios.mjs` now carries the console side of that ruling as an `@owner`
  stamp, so the fact is legible from inside the tree it governs.

  This test keeps the stamp honest. It is deliberately a PREDICATE, not an
  enumeration of stamped files: a second file may carry the stamp, but a second
  EPIC may not, and the tree may never end up with no owner at all.

  Pure file reading — no DB, no router.
  """
  use ExUnit.Case, async: true

  @owner "cloud-console-hardening"
  @stamp_re ~r/@owner\s+epic:([a-z0-9][a-z0-9-]*)/

  defp preview_dir do
    Path.expand("../../priv/static/__preview__", __DIR__)
  end

  defp stamps do
    preview_dir()
    |> Path.join("**/*.mjs")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> then(&Regex.scan(@stamp_re, &1))
      |> Enum.map(fn [_, epic] -> {Path.relative_to(path, preview_dir()), epic} end)
    end)
  end

  test "the preview tree carries an owner stamp at all" do
    found = stamps()

    refute found == [],
           "no `@owner epic:<slug>` stamp anywhere in cloud/priv/static/__preview__/. " <>
             "That is the undecided-cession state this test exists to prevent: the tree " <>
             "belongs to #{@owner} by the deploy-reliability charter's D402 cession, and " <>
             "scenarios.mjs must say so. Restore the OWNERSHIP block in its header."
  end

  test "scenarios.mjs is where the ruling is written" do
    scenarios = Enum.filter(stamps(), fn {file, _} -> file == "scenarios.mjs" end)

    assert [{"scenarios.mjs", @owner}] == scenarios,
           "scenarios.mjs must carry exactly one `@owner epic:#{@owner}` stamp — the file " <>
             "the cession row named. Found: #{inspect(scenarios)}"
  end

  test "the tree has exactly ONE owning epic — a second epic is the failure, a second file is not" do
    owners = stamps() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

    assert owners == [@owner],
           "cloud/priv/static/__preview__/ is stamped for more than one epic: " <>
             "#{inspect(owners)}. Exactly one epic owns this tree (#{@owner}, by the " <>
             "deploy-reliability charter's D402 cession). Two owners is the same " <>
             "unowned-in-practice state as zero: whoever is adding the second stamp must " <>
             "amend the cession in both charters first, not fork it here.\n" <>
             "Stamps found: #{inspect(stamps())}"
  end
end
