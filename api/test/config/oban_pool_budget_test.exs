defmodule Barkpark.Config.ObanPoolBudgetTest do
  @moduledoc """
  api/'s half of the pool arithmetic (`jpf-bl-oban-pool-partition`), pinned
  the way `cloud/test/barkpark_cloud/oban_pool_budget_test.exs` pins the
  control plane's: every number is read off the CONFIG SOURCES, and a change
  to any of them reds here until a human re-reads the decision.

  ## The decision this pins

  Oban job bodies run on their own pool (`OBAN_POOL_SIZE`, default 4), never on
  the `POOL_SIZE` pool (default 10) HTTP uses. So the share of the web pool the
  29 declared queue slots can take is ZERO — that is the property that makes
  "background work can no longer exhaust the web pool" true, and the first
  test reds the moment the default partition is switched off.

  A cap alone was not available: OSS Oban has no global limit, so the floor of
  the aggregate is one slot per queue — 9 of 10 web connections. Measured
  before/after with `scripts/mutate-load` under 29 saturated slots: see
  `Barkpark.Repo.job_pool_child_specs/0` and the note above `repo_opts` in
  `config/runtime.exs`.

  ## The numbers that are NOT in this tree

  `@max_connections` and `@other_clients` were MEASURED on guerrilla by the
  cp-ops `guerrilla-db-probe` arm (run 36119486090, 2026-09-25T09:41Z):
  `max_connections = 100`; pg_stat_activity active 1 + idle 13 client
  backends with one slot live = 14, of which 11 are this app (POOL_SIZE 10 +
  Oban's LISTEN notifier) and 3 are something else (the probe's own psql among
  them). `@superuser_reserved` is Postgres' default
  `superuser_reserved_connections`, NOT measured. If the box changes, re-probe
  and move them here.
  """
  use ExUnit.Case, async: true

  @config_exs "config/config.exs"
  @runtime_exs "config/runtime.exs"

  # Measured (see @moduledoc).
  @max_connections 100
  @superuser_reserved 3
  @other_clients 3
  # Per slot, beyond its two pools: Oban's Postgres notifier holds one
  # dedicated LISTEN connection, and a workspace export opens a 1-connection
  # pool for its duration (`:export_pool_size`).
  @per_slot_extra 1 + 1

  # THE RECORDED DECISION: declared job slots minus the job pool. These jobs
  # wait for a job-pool connection among themselves (60 s client timeout, see
  # `Barkpark.Repo.job_pool_child_specs/0`) instead of taking HTTP's. An
  # EQUALITY on purpose, as in cloud/: it reds when a queue is widened or added
  # (more waiting than was accepted) AND when the gap closes.
  @accepted_job_queueing 25

  test "the partition is ON by default: Oban's share of the web pool is zero" do
    assert oban_pool_default() > 0, """
    OBAN_POOL_SIZE's default in #{@runtime_exs} is #{oban_pool_default()}.

    At 0 every Oban job body runs on the POOL_SIZE pool again, so the
    #{declared_slots()} declared queue slots can take all #{pool_size_default()} web
    connections — measured locally: 1-25 of 200 create+publish rounds landed
    while 29 slots were busy, against 200/200 with the partition on.
    """
  end

  test "declared job slots exceed the job pool by exactly the accepted amount" do
    declared = declared_slots()
    job_pool = oban_pool_default()

    assert declared - job_pool == @accepted_job_queueing, """
    The Oban declared-concurrency / job-pool budget moved.

      declared job slots : #{declared}   (#{inspect(prod_queues())})
      OBAN_POOL_SIZE     : #{job_pool}
      queueing           : #{declared - job_pool}
      accepted (pinned)  : #{@accepted_job_queueing}

    Re-read #{inspect(__MODULE__)}'s @moduledoc, decide, then move
    @accepted_job_queueing.
    """
  end

  test "a blue/green flip fits under max_connections with both pools" do
    per_slot = pool_size_default() + oban_pool_default() + @per_slot_extra
    flip = 2 * per_slot + @other_clients
    ceiling = @max_connections - @superuser_reserved

    assert flip <= ceiling, """
    A blue/green flip would need #{flip} client connections:
      2 x (POOL_SIZE #{pool_size_default()} + OBAN_POOL_SIZE #{oban_pool_default()} + #{@per_slot_extra}) + #{@other_clients} other
    against #{ceiling} available (max_connections #{@max_connections} - #{@superuser_reserved} reserved).
    """
  end

  test "the reader reads real numbers (control)" do
    assert pool_size_default() == 10
    assert length(prod_queues()) >= 9
    assert declared_slots() > oban_pool_default()
  end

  test "runtime.exs does not re-declare Oban's queues (the reader would miss it)" do
    oban_configs =
      collect(ast(@runtime_exs), fn
        {:config, _, [:barkpark, {:__aliases__, _, [:Oban]} | _]} -> {:ok, :oban}
        _ -> :skip
      end)

    assert oban_configs == [],
           "runtime.exs now configures Oban; teach prod_queues/0 to merge it " <>
             "(cloud/'s pin shows how) before trusting the slot count"
  end

  # ── reading the numbers off the config sources ──────────────────────────────

  defp prod_queues do
    @config_exs
    |> Config.Reader.read!(env: :prod)
    |> Keyword.fetch!(:barkpark)
    |> Keyword.fetch!(Oban)
    |> Keyword.fetch!(:queues)
  end

  defp declared_slots, do: prod_queues() |> Keyword.values() |> Enum.sum()

  defp pool_size_default, do: env_default!("POOL_SIZE")
  defp oban_pool_default, do: env_default!("OBAN_POOL_SIZE")

  # The `System.get_env("<VAR>") || "<n>"` literal in runtime.exs, by AST.
  defp env_default!(var) do
    defaults =
      collect(ast(@runtime_exs), fn
        {:||, _, [{{:., _, [{:__aliases__, _, [:System]}, :get_env]}, _, [^var]}, default]}
        when is_binary(default) ->
          {:ok, String.to_integer(default)}

        _ ->
          :skip
      end)

    case defaults do
      [n] ->
        n

      other ->
        flunk(
          "expected exactly one `System.get_env(#{inspect(var)}) || \"<n>\"` default in " <>
            "#{@runtime_exs}, found #{length(other)}: #{inspect(other)}"
        )
    end
  end

  defp ast(path), do: path |> File.read!() |> Code.string_to_quoted!()

  defp collect(ast, matcher) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case matcher.(node) do
          {:ok, value} -> {node, [value | acc]}
          :skip -> {node, acc}
        end
      end)

    Enum.reverse(acc)
  end
end
