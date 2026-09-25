defmodule BarkparkCloud.SharedTestDb do
  @moduledoc """
  Say which database a cloud test run used, and make a schema-version drift red
  name the version AND the database (task-b169445c9f0031b3).

  The cloud port of `api/test/support/shared_test_db.ex` (#20107). It carries
  only the half cloud needed: the per-checkout database line and the
  migration-drift predicate. api's residue census, concurrent-backend probe and
  sibling-partition probe are not ported — their tables and failure history are
  api's — but every function here has the same name, shape and wording as its
  api twin, so reading one explains the other.

  ## The disease

  `cloud/test` runs against ONE Postgres database — `barkpark_cloud_test<suffix>`.
  Until this task the suffix came only from `MIX_TEST_PARTITION`, so with the
  variable unset every worktree on a box shared `barkpark_cloud_test`, and each
  inherited whatever schema the last worktree migrated it to. A console builder
  read `DeliveryRecipientIndexTest` red because #20298's index was missing from
  that shared database: a CONFIDENT, SPECIFIC, PLAUSIBLE red with no fault in
  the builder's diff. Since then an unset variable means a PER-CHECKOUT database
  (`config/test.exs`, `:test_db_partition`); only CI and an explicit
  `MIX_TEST_PARTITION=` (empty) land on the shared one.

  ## Why the drift probe stays

  A per-checkout database can still drift from its checkout: a `git switch`
  inside one worktree, or two checkouts opted into one partition on purpose.
  `ecto.migrate` (run by the `test` alias) repairs a database that is BEHIND;
  nothing repairs one that is AHEAD, because a migration this checkout does not
  have cannot be rolled back from it. So the predicate is the set of
  `schema_migrations.version` rows diffed against `priv/repo/migrations/`, and
  a difference is reported as ONE sentence naming every version and the
  database it was measured in (`drift_report/1`).

  ## Why a printed line and a test, not a refusal

  Same reasons as api: CI runs on the unpartitioned database on purpose, and a
  refusal whose predicate is slightly wrong would red the required Cloud gate on
  every PR. `report!/2` prints and never raises; the red is
  `BarkparkCloud.SharedTestDbTest`'s REAL drift test, whose failure message is
  `drift_report/1`.
  """

  @which_token "BARKPARK-CLOUD-TEST-DB"

  @doc "The literal string a builder greps a capture for."
  def which_token, do: @which_token

  @doc """
  Run the probes against a live repo. Returns an observation map. NEVER raises:
  a probe that fails is recorded as `:unavailable`.

  Options:

    * `:migrations_path` — where the checkout's migrations live
  """
  def observe(repo, opts \\ []) do
    migrations_path = Keyword.get(opts, :migrations_path, default_migrations_path())

    %{
      database: probe(fn -> scalar(repo, "SELECT current_database()") end),
      partition: partition(),
      partition_source: partition_source(),
      applied_versions: probe(fn -> applied_versions(repo) end),
      checkout_versions: probe(fn -> checkout_versions(migrations_path) end)
    }
  end

  @doc """
  Judge an observation. Pure. Returns `{:ok, findings}`; empty means nothing to
  say.
  """
  def assess(obs) when is_map(obs) do
    {:ok, drift_findings(obs) ++ unavailable_findings(obs)}
  end

  defp drift_findings(%{applied_versions: a, checkout_versions: c})
       when is_list(a) and is_list(c) do
    applied = MapSet.new(a)
    checkout = MapSet.new(c)

    extra = applied |> MapSet.difference(checkout) |> Enum.sort()
    missing = checkout |> MapSet.difference(applied) |> Enum.sort()

    # Not `List.wrap(cond && finding)`: `List.wrap(false)` is `[false]`.
    ahead = if extra == [], do: [], else: [{:migration_drift, :db_ahead_of_checkout, extra}]
    behind = if missing == [], do: [], else: [{:migration_drift, :db_behind_checkout, missing}]

    ahead ++ behind
  end

  defp drift_findings(_), do: []

  defp unavailable_findings(obs) do
    for key <- [:applied_versions, :checkout_versions],
        Map.get(obs, key) == :unavailable,
        do: {:probe_unavailable, key}
  end

  defp partition_line(nil),
    do: "(none — this is the unpartitioned, SHARED barkpark_cloud_test database)"

  defp partition_line(p), do: inspect(p)

  @doc """
  One line naming the database a run used and WHY that one — printed at the top
  of every run so a capture always says where its reds happened.
  """
  def which_line(obs) do
    "#{@which_token}: database #{inspect(obs[:database])}, " <>
      "partition #{partition_line(obs[:partition])}, " <>
      "chosen by #{source_text(obs[:partition_source])}"
  end

  defp source_text(:explicit), do: "MIX_TEST_PARTITION (set explicitly)"
  defp source_text(:ci), do: "CI (CI is set and MIX_TEST_PARTITION is not)"

  defp source_text(:worktree_default),
    do: "the per-checkout default (MIX_TEST_PARTITION unset; derived from the checkout path)"

  defp source_text(other), do: "unknown source #{inspect(other)}"

  @doc """
  The migration-drift findings of an observation as ONE sentence that names
  every offending version AND the database/partition it was measured in, or
  `nil` when there is no drift. A drift red must read "migration X from another
  branch in database Y", never a bare list of integers.
  """
  def drift_report(obs) do
    {:ok, findings} = assess(obs)

    case for({:migration_drift, _, _} = f <- findings, do: f) do
      [] ->
        nil

      drift ->
        "database #{inspect(obs[:database])} (partition #{partition_line(obs[:partition])}, " <>
          "chosen by #{source_text(obs[:partition_source])}): " <>
          Enum.map_join(drift, "; ", &drift_sentence/1)
    end
  end

  defp drift_sentence({:migration_drift, :db_ahead_of_checkout, versions}),
    do:
      "has applied migration(s) #{Enum.join(versions, ", ")} that this checkout " <>
        "(priv/repo/migrations) does not have — another branch migrated this database"

  defp drift_sentence({:migration_drift, :db_behind_checkout, versions}),
    do:
      "is missing migration(s) #{Enum.join(versions, ", ")} that this checkout has — " <>
        "run `mix ecto.migrate`, or another suite is mid-way through an up/down test here"

  @doc """
  Observe, print the which-database line (and the drift sentence, if any) to
  stderr, and return the observation. Called from `test_helper.exs`. Cannot
  fail the suite.
  """
  def report!(repo, opts \\ []) do
    obs = observe(repo, opts)

    IO.puts(:stderr, which_line(obs))

    case drift_report(obs) do
      nil -> :ok
      text -> IO.puts(:stderr, "#{@which_token}: SCHEMA DRIFT — #{text}")
    end

    obs
  rescue
    # A formatting bug here must never be the reason the suite does not run.
    e -> IO.puts(:stderr, "#{@which_token}: report itself failed (#{Exception.message(e)})")
  end

  # ── probes ────────────────────────────────────────────────────────────────

  defp probe(fun) do
    fun.()
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  # The suffix config/test.exs actually chose (`:test_db_partition`), NOT the
  # raw env var: with the per-checkout default an unset MIX_TEST_PARTITION is a
  # partitioned run.
  defp partition do
    suffix =
      case Application.get_env(:barkpark_cloud, :test_db_partition) do
        %{suffix: s} -> s
        _ -> System.get_env("MIX_TEST_PARTITION")
      end

    case suffix do
      nil -> nil
      "" -> nil
      p -> p
    end
  end

  defp partition_source do
    case Application.get_env(:barkpark_cloud, :test_db_partition) do
      %{source: source} -> source
      _ -> :unknown
    end
  end

  defp applied_versions(repo) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(repo, "SELECT version FROM schema_migrations", [])
    Enum.map(rows, fn [v] -> v end)
  end

  defp checkout_versions(path) do
    path
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.map(&(&1 |> String.split("_", parts: 2) |> hd()))
    |> Enum.filter(&Regex.match?(~r/\A\d+\z/, &1))
    |> Enum.map(&String.to_integer/1)
  end

  defp default_migrations_path do
    Application.app_dir(:barkpark_cloud, "priv/repo/migrations")
  rescue
    _ -> "priv/repo/migrations"
  end

  defp scalar(repo, sql) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(repo, sql, [])
    value
  end
end
