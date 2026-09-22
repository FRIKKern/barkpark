defmodule Barkpark.SharedTestDb do
  @moduledoc """
  Answer "is this red MINE?" mechanically, at suite start, before a single
  assertion has run (task-71dd1eb49e334fbb).

  ## The disease

  `api/test` runs against ONE Postgres database — `barkpark_test<partition>` —
  and the partition suffix comes from `MIX_TEST_PARTITION` (`config/test.exs`).
  With the variable unset, every concurrently running agent shares
  `barkpark_test`. Four builders in one lead-api session (r21n) each spent part
  of their budget proving, by hand, that a specific and plausible red belonged to
  another agent's rows rather than to their own diff. One whole-directory run
  read `12902 tests, 18 failures`; all 18 were shared-database pollution, and the
  same five files on a fresh partition were `112 tests, 0 failures`.

  `MIX_TEST_PARTITION` is the remedy and it WORKS. The residue is that the
  unpartitioned path is still reachable, and when taken it produces a CONFIDENT,
  SPECIFIC, PLAUSIBLE red instead of a visibly absent one. A builder who has not
  been told reads 18 named failures and investigates them.

  ## Why a BANNER and not a refusal

  Acceptance criterion 0 offered both shapes. This module prints; it never
  raises, never exits, never changes an exit code. Three reasons:

    1. **CI runs unpartitioned on purpose.** `.github/workflows/elixir.yml` gives
       the job its own ephemeral `postgres:15` service and sets no
       `MIX_TEST_PARTITION` (`DATABASE_URL: …/barkpark_test`). A refusal keyed on
       "unpartitioned" reds the REQUIRED Elixir gate on every PR in the repo.
    2. **This is the harness every other lane's gate runs through**, and it is
       being changed while those lanes are running. A refusal whose predicate is
       slightly wrong reds every lane at once; a banner whose predicate is
       slightly wrong costs one scroll.
    3. **Every input here is a live query against a database we do not own.**
       `pg_stat_activity` visibility, a missing table, a revoked GRANT — any of
       them turns a refusal into an outage. Every probe below is wrapped: a
       failed probe degrades to `:unavailable` and is REPORTED as unavailable,
       never inferred to be clean and never raised.

  The banner carries the literal token `BARKPARK-SHARED-TEST-DB` so a builder can
  grep a capture for it and quote the line.

  ## What it looks at, and why each one is a RULE and not a list

  `observe/2` gathers, `assess/1` judges. They are split so the judgment is a
  pure function of an observation map and can be driven from both directions in
  a test without a database.

    * **`:residue`** — a bounded `count(*)` over a census of content tables,
      taken BEFORE `Sandbox.mode(:manual)`, i.e. outside any test transaction.
      A non-zero count at suite start is a row NO test in this run created: it
      was COMMITTED by someone else (`Sandbox.unboxed_run/2` commits — see
      `Barkpark.ChatSessionResidue`) and every count assertion in this run meets
      it. This is the class measured as "73 leftover `epic_assignments` rows".
      The count is capped (`LIMIT` inside a subquery) so a polluted developer box
      cannot make suite start slow.

    * **`:migration_drift`** — the set of `schema_migrations.version` rows in the
      live database, diffed against the set of versions in
      `priv/repo/migrations/`. This is deliberately a PREDICATE, not a column
      list: "a stale `share_links.token` column" is one instance of "this
      database's applied-migration set is not this checkout's". A DB the branch
      is ahead of, a DB another branch migrated further, a DB mid-`down` from
      another partition's migration test — all three are the same finding, and a
      hard-coded list of known-bad columns would have caught only the one
      instance somebody already hit.

    * **`:concurrent_backends`** — other live Postgres backends on OUR database
      that were opened BEFORE THIS BEAM STARTED. A connection cannot predate the
      OS process that opened it, so a backend older than our runtime is
      necessarily somebody else's: that is an IDENTITY, not an estimate.

      IT WAS AN AGE HEURISTIC AND THE HEURISTIC WAS WRONG. The first shape of
      this probe counted backends more than `:backend_age_seconds` (30) older
      than THE CONNECTION ASKING THE QUESTION, on the premise that "our whole
      pool connects within a moment of each other at app boot". Under
      `Ecto.Adapters.SQL.Sandbox` the pool does NOT connect at boot — an
      ownership pool opens connections as tests check them out, across the whole
      run. So the reference instant MOVED with the asker, and in a long suite a
      late-opened connection read its own 19 pool siblings as a foreign suite.
      MEASURED: green in a 1.6s single-file run, red at minute 23 of the CI
      suite (run 35676197841, job 106583201638) with the message "our own pool
      is being counted as a foreign suite at the shipped threshold". A wider
      threshold would only have moved the duration at which it lies.

      The BEAM's start instant is fixed for the life of the run, so the verdict
      cannot drift as the suite gets longer. It is computed IN DATABASE TIME
      (`clock_timestamp() - uptime`), so no app-host/db-host clock comparison
      happens and no skew tolerance constant is needed.

      `backend_type = 'client backend'` keeps an autovacuum worker or another
      background worker from ever being read as a peer suite.

      LIMIT OF THIS PROBE, stated plainly: a peer whose suite starts AFTER ours
      is not caught — its backends are younger than our runtime. It is the
      weakest of the three and it is the one the other two do not need.

    * **`:sibling_partitions`** — other `barkpark_test%` databases with live
      backends. Evidence, not a verdict: it says other agents are running
      partitioned right now, which is the moment sharing the unpartitioned DB is
      most expensive.

  ## The quiet arm is a real negative

  On a fresh partition every probe RUNS, returns real rows, and finds nothing —
  see `shared_test_db_test.exs`, which asserts the census actually inspected
  tables and that `schema_migrations` returned a non-empty version set BEFORE it
  asserts there are no findings. A probe that silently returned `:unavailable`
  would also produce "no findings", so the test refuses to accept a clean verdict
  it cannot show was measured.
  """

  @token "BARKPARK-SHARED-TEST-DB"

  @doc "The literal string a builder greps a capture for."
  def token, do: @token

  # The census. Small on purpose: tables whose committed residue is known to
  # change another test's answer. Adding one is cheap; this is not an attempt at
  # completeness, and `assess/1` does not care which tables are in it.
  @census_tables ~w(epic_assignments share_links documents)

  @residue_cap 1000

  # `:erlang.statistics(:wall_clock)` counts milliseconds since THIS BEAM
  # started. Subtracting it from the database's own clock names the instant our
  # runtime came up, in the database's time base. Fixed for the whole run.
  defp runtime_uptime_ms, do: :erlang.statistics(:wall_clock) |> elem(0)

  @doc """
  Run the probes against a live repo. Returns an observation map. NEVER raises:
  a probe that fails is recorded as `:unavailable` and judged as unavailable.

  Options:

    * `:tables` — census table list (default `#{inspect(@census_tables)}`)
    * `:runtime_uptime_ms` — milliseconds this BEAM has been up; a backend
      opened before that is not ours (default `:erlang.statistics(:wall_clock)`).
      Passing `0` moves the reference to NOW and makes EVERY other live backend
      count — that is how the test proves the statement can see backends at all.
    * `:migrations_path` — where the checkout's migrations live
  """
  def observe(repo, opts \\ []) do
    tables = Keyword.get(opts, :tables, @census_tables)
    uptime_ms = Keyword.get(opts, :runtime_uptime_ms, runtime_uptime_ms())
    migrations_path = Keyword.get(opts, :migrations_path, default_migrations_path())

    %{
      database: probe(fn -> scalar(repo, "SELECT current_database()") end),
      partition: partition(),
      residue: probe(fn -> residue(repo, tables) end),
      tables_inspected: tables,
      applied_versions: probe(fn -> applied_versions(repo) end),
      checkout_versions: probe(fn -> checkout_versions(migrations_path) end),
      concurrent_backends: probe(fn -> concurrent_backends(repo, uptime_ms) end),
      sibling_partitions: probe(fn -> sibling_partitions(repo) end)
    }
  end

  @doc """
  Judge an observation. Pure. Returns `{:ok, findings}` where findings is a list
  of tagged tuples — empty means nothing to say.
  """
  def assess(obs) when is_map(obs) do
    findings =
      residue_findings(obs) ++
        drift_findings(obs) ++
        backend_findings(obs) ++
        sibling_findings(obs) ++
        unavailable_findings(obs)

    {:ok, findings}
  end

  defp residue_findings(%{residue: :unavailable}), do: []

  defp residue_findings(%{residue: residue}) when is_list(residue) do
    for {table, count} <- residue, count > 0, do: {:residue, table, count}
  end

  defp residue_findings(_), do: []

  defp drift_findings(%{applied_versions: a, checkout_versions: c})
       when is_list(a) and is_list(c) do
    applied = MapSet.new(a)
    checkout = MapSet.new(c)

    extra = applied |> MapSet.difference(checkout) |> Enum.sort()
    missing = checkout |> MapSet.difference(applied) |> Enum.sort()

    # NOT `List.wrap(cond && finding)`: `List.wrap(false)` is `[false]`, not
    # `[]` — it only special-cases nil and lists. The first run of this module
    # emitted a `false` finding into `explain/1` and the banner rescued itself.
    ahead = if extra == [], do: [], else: [{:migration_drift, :db_ahead_of_checkout, extra}]
    behind = if missing == [], do: [], else: [{:migration_drift, :db_behind_checkout, missing}]

    ahead ++ behind
  end

  defp drift_findings(_), do: []

  defp backend_findings(%{concurrent_backends: n}) when is_integer(n) and n > 0,
    do: [{:concurrent_backends, n}]

  defp backend_findings(_), do: []

  defp sibling_findings(%{sibling_partitions: [_ | _] = siblings, partition: nil}),
    do: [{:sibling_partitions, siblings}]

  defp sibling_findings(_), do: []

  defp unavailable_findings(obs) do
    for key <- [:residue, :applied_versions, :checkout_versions, :concurrent_backends],
        Map.get(obs, key) == :unavailable,
        do: {:probe_unavailable, key}
  end

  @doc """
  The banner text for an observation, or `nil` when there is nothing to say.
  """
  def banner(obs) do
    {:ok, findings} = assess(obs)
    banner(obs, findings)
  end

  def banner(_obs, []), do: nil

  def banner(obs, findings) do
    """

    ================================================================
    #{@token}: this run's database is not exclusively yours
    ================================================================

      database:  #{inspect(obs[:database])}
      partition: #{partition_line(obs[:partition])}

    #{Enum.map_join(findings, "\n", &("  - " <> explain(&1)))}

    WHAT THIS MEANS FOR A RED IN THIS RUN. A failure below may belong to
    another agent's committed rows rather than to your diff. Before you
    investigate one, re-run the SAME files on a partition of your own:

      MIX_TEST_PARTITION=<your-lane> scripts/mix-test-strict.sh <files>

    If the failure survives a fresh partition it is yours. If it does not,
    it was never a finding — quote this banner and move on.
    ================================================================
    """
  end

  defp partition_line(nil),
    do: "(none — MIX_TEST_PARTITION is unset, so this is the SHARED database)"

  defp partition_line(p), do: inspect(p)

  defp explain({:residue, table, count}),
    do:
      "#{table}: #{count_text(count)} committed row(s) present BEFORE any test ran. " <>
        "No test in this run created them; every count assertion over #{table} meets them."

  defp explain({:migration_drift, :db_ahead_of_checkout, versions}),
    do:
      "the database has applied #{length(versions)} migration(s) this checkout does not have " <>
        "(#{preview(versions)}). Its schema is some other branch's — a column you expect gone may still be there."

  defp explain({:migration_drift, :db_behind_checkout, versions}),
    do:
      "the database is MISSING #{length(versions)} migration(s) this checkout has " <>
        "(#{preview(versions)}). Run `mix ecto.migrate`, or another partition's up/down test is mid-flight against it."

  defp explain({:concurrent_backends, n}),
    do:
      "#{n} other Postgres backend(s) are live on this database and were opened BEFORE this BEAM started. " <>
        "They cannot be ours. Another suite is running here right now."

  defp explain({:sibling_partitions, siblings}),
    do:
      "other partitioned test databases are live (#{Enum.join(siblings, ", ")}) while you are on the SHARED one. " <>
        "Other agents are working; you are the one without a fence."

  defp explain({:probe_unavailable, key}),
    do:
      "probe #{inspect(key)} could not run, so this banner CANNOT tell you the database is clean on that axis."

  # Total on purpose. A banner is a diagnostic; an unrecognised finding shape
  # must print SOMETHING rather than take the whole run down through
  # `report!/2`'s rescue, which would swallow every other finding with it.
  defp explain(other), do: "unrecognised finding shape: #{inspect(other)}"

  defp count_text(n) when n >= @residue_cap, do: ">=#{n}"
  defp count_text(n), do: Integer.to_string(n)

  defp preview(versions) do
    versions |> Enum.take(3) |> Enum.map_join(", ", &to_string/1)
  end

  @doc """
  Observe, assess, and print the banner to stderr. Returns the observation.
  Called from `test_helper.exs`. Cannot fail the suite.
  """
  def report!(repo, opts \\ []) do
    obs = observe(repo, opts)

    case banner(obs) do
      nil -> :ok
      text -> IO.puts(:stderr, text)
    end

    obs
  rescue
    # Belt and braces. `observe/2` already wraps each probe; this catches a
    # failure in the BANNER itself. A formatting bug here must never be the
    # reason 12000 tests do not run.
    e -> IO.puts(:stderr, "#{@token}: banner itself failed (#{Exception.message(e)})")
  end

  # ── probes ────────────────────────────────────────────────────────────────

  defp probe(fun) do
    fun.()
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp partition do
    case System.get_env("MIX_TEST_PARTITION") do
      nil -> nil
      "" -> nil
      p -> p
    end
  end

  defp residue(repo, tables) do
    for table <- tables do
      count =
        scalar(repo, """
        SELECT count(*) FROM (SELECT 1 FROM #{quote_ident(table)} LIMIT #{@residue_cap}) s
        """)

      {table, count}
    end
  end

  # A table name from the census constant, never from user input; this is a
  # belt-and-braces identifier quote so the interpolation above cannot be read
  # as an injection shape by a reviewer or a scanner.
  defp quote_ident(name) do
    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name) do
      ~s("#{name}")
    else
      raise ArgumentError, "census table name is not a bare identifier: #{inspect(name)}"
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
    Application.app_dir(:barkpark, "priv/repo/migrations")
  rescue
    _ -> "priv/repo/migrations"
  end

  @doc """
  The foreign-backend statement, as SQL, taking the BEAM uptime in milliseconds
  as `$1`.

  Public so a test can run the SAME statement from a connection OTHER than the
  pool's — which is exactly the situation that broke the age-based shape. A
  predicate whose answer depends on WHICH of our own connections asks it is not
  an identity, and the only way to show this one does not is to ask it twice,
  from two different connections, and get the same number.
  """
  def concurrent_backends_sql do
    """
    SELECT count(*)
      FROM pg_stat_activity a
     WHERE a.datname = current_database()
       AND a.pid <> pg_backend_pid()
       AND a.backend_type = 'client backend'
       AND a.backend_start < #{runtime_start_expr()}
    """
  end

  @doc """
  The SQL expression naming the instant this BEAM started, in the database's own
  time base, from the uptime in `$1`. THE INVARIANT LIVES HERE: `clock_timestamp()`
  and the uptime advance together, so this expression names a FIXED instant no
  matter how long the run has been going. Public so a test can assert that
  directly on the shipped expression rather than on a copy of it.
  """
  def runtime_start_expr, do: "clock_timestamp() - ($1::bigint * interval '1 millisecond')"

  defp concurrent_backends(repo, uptime_ms) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(repo, concurrent_backends_sql(), [uptime_ms])

    count
  end

  defp sibling_partitions(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT DISTINCT datname
          FROM pg_stat_activity
         WHERE datname LIKE 'barkpark\\_test%'
           AND datname <> current_database()
        """,
        []
      )

    rows |> Enum.map(fn [d] -> d end) |> Enum.sort()
  end

  defp scalar(repo, sql) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(repo, sql, [])
    value
  end
end
