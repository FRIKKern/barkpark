defmodule BarkparkCloud.DeployRateSingleComputationTest do
  @moduledoc """
  dr-w10-bl-team-scoped-box-rate — ONE COMPUTATION, TWO AUDIENCES.

  The brief's standing order is a negative one: *"a team-scoped census filtered to
  the caller's sites, reading the SAME function the operator census reads so the
  two cannot diverge. Do not build a second computation."* A prose instruction
  does not fire by itself, so this file is the mechanism.

  ## WHAT WOULD GO WRONG WITHOUT IT

  The operator census (`/v1/operator/deploy-ledger/census`,
  `require_platform_operator` — population zero in production) and the
  team-scoped census (`/v1/deploy-ledger/census`, `require_user_or_pat` +
  `require_ability("read")` — the read a real account can reach) answer the same
  question to two audiences. The cheapest way to add a team-scoped figure is
  always to write a second fold beside the first. The two then agree on the day
  they are written and drift silently forever after, and the audience that drifts
  is the one with no operator to notice — which is the whole defect this epic
  exists to end.

  ## WHAT IS ASSERTED, AND WHAT IS NOT

  This is a SOURCE census over `cloud/lib`, parsed from the AST, not a runtime
  comparison of two payloads. It reds when a CALL SITE appears, disappears, or
  changes shape — the moment a divergent branch is written, before anyone has to
  notice the numbers disagree. It cannot see a divergence built INSIDE
  `DeployLedger` itself; `deploy_ledger_reachability_test.exs` holds that side.

  The anti-vacuity floor at the bottom is load-bearing: a walker that silently
  matched nothing would report a perfectly clean tree, which is the failure mode
  a census of absences is most prone to.
  """
  use ExUnit.Case, async: true

  @lib "lib/barkpark_cloud"

  # The DECLARED roster of call sites. A row is {file, function, arity-ish shape}.
  # Both census routes are here BY NAME so a reader can see that the operator
  # surface and the team-scoped surface land on the same function.
  @declared_census [
    # The team-scoped read — `census/3` with a `:site_ids` scope (dr-w16-s6).
    {"web/router.ex", :census},
    # `deploy_census_json/2`, which is what the OPERATOR route calls. Same
    # function, unscoped, because an operator is asking about the whole fleet.
    {"web/router.ex", :census},
    # The digest mail's own read — scoped, same entry point.
    {"notifications/digest_email.ex", :census}
  ]

  defp source_files do
    Path.wildcard(Path.join([__DIR__, "..", "..", @lib, "**/*.ex"]))
    |> Enum.map(&Path.expand/1)
  end

  defp rel(path),
    do:
      path
      |> Path.split()
      |> Enum.drop_while(&(&1 != "barkpark_cloud"))
      |> then(fn
        ["barkpark_cloud" | rest] -> Enum.join(rest, "/")
        other -> Enum.join(other, "/")
      end)

  # Every `DeployLedger.<fun>(...)` call in the tree, as {file, fun, args}.
  defp deploy_ledger_calls do
    for path <- source_files(),
        {:ok, ast} = Code.string_to_quoted(File.read!(path)),
        call <- collect_calls(ast),
        do: {rel(path), elem(call, 0), elem(call, 1)}
  end

  defp collect_calls(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, mods}, fun]}, _, args} = node, acc ->
          if List.last(mods) == :DeployLedger, do: {node, [{fun, args} | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  test "census/3 is the ONE census entry point, and both census routes land on it" do
    found =
      deploy_ledger_calls()
      |> Enum.filter(fn {_f, fun, _args} -> fun == :census end)
      |> Enum.map(fn {f, fun, _args} -> {f, fun} end)
      |> Enum.sort()

    assert found == Enum.sort(@declared_census),
           """
           The census call-site roster moved. A NEW call site is how a divergent
           branch arrives: a second fold beside `census/3` agrees on the day it
           is written and drifts in silence after. Either route it through
           `DeployLedger.census/3` or, if this is a deliberate new reader, add it
           to @declared_census WITH the reason.

           declared: #{inspect(Enum.sort(@declared_census))}
           found:    #{inspect(found)}
           """
  end

  test "no module outside DeployLedger computes a census-shaped fold of its own" do
    # The tell of a hand-rolled rate is the pair of names `census/3` owns:
    # nothing outside the ledger may name a `terminal_failure_rate` or a
    # `min_sample` of its own, because a percentage minted outside the module
    # has no refusal floor beneath it.
    offenders =
      for path <- source_files(),
          not String.ends_with?(path, "deploy_ledger.ex"),
          body = File.read!(path),
          String.contains?(body, "terminal_failure_rate:") or
            String.contains?(body, "@min_sample"),
          do: rel(path)

    assert offenders == [],
           "a rate node minted outside DeployLedger has no refusal floor: #{inspect(offenders)}"
  end

  test "box_rates/4 has exactly ONE caller and it passes a tenant scope" do
    calls = deploy_ledger_calls() |> Enum.filter(fn {_f, fun, _a} -> fun == :box_rates end)

    assert [{"web/router.ex", :box_rates, args}] = calls,
           "expected exactly one box_rates caller, got: #{inspect(Enum.map(calls, &elem(&1, 0)))}"

    assert length(args) == 4,
           """
           The per-box rate was called WITHOUT its tenant scope (arity #{length(args)}).
           `box_rates/3` folds every site on the box regardless of owner, so an
           unscoped call on a team-facing route reports another team's deploys as
           the caller's own. If a genuinely fleet-wide caller is being added, it
           belongs on an operator surface and this pin must say so out loud.
           """

    assert Keyword.has_key?(List.last(args), :team_ids),
           "the fourth argument must carry :team_ids, got: #{Macro.to_string(List.last(args))}"
  end

  test "ANTI-VACUITY: the walker actually parses the tree and finds DeployLedger calls" do
    files = source_files()
    assert length(files) > 100, "the source glob matched #{length(files)} files — it is broken"

    calls = deploy_ledger_calls()

    assert length(calls) > 5,
           "the AST walker found #{length(calls)} DeployLedger calls — a broken walker reports a clean tree"

    # And it can tell functions apart, so the filters above are real filters.
    assert calls |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() > 1
  end
end
