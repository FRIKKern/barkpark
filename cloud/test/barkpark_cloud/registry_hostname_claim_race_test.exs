defmodule BarkparkCloud.RegistryHostnameClaimRaceTest do
  @moduledoc """
  task-eb462b466363b1e8 — the three hostname claim doors (`add_site_domain/2`,
  `create_site/2`, `set_custom_host/2`) were check-then-write at stock READ
  COMMITTED with nothing serialising them, and the comment in
  `add_site_domain/2` claimed the `add_domain_cross_site_uniqueness` trigger was
  the race backstop. It is not: a plpgsql `EXISTS` inside a BEFORE ROW trigger
  takes its own READ COMMITTED snapshot and cannot see a concurrent uncommitted
  `sites` row, so two racers each read a free namespace and BOTH commit.

  ## Why this file does not use the sandbox

  The sibling `registry_barkpark_quota_race_test.exs` states its own limit
  plainly: under `Sandbox.mode({:shared, self()})` every spawned task borrows the
  OWNER'S SINGLE CONNECTION, so what it exhibits is the APPLICATION-level
  interleave, not a second backend being blocked. That shape is useless HERE and
  would be actively misleading: `pg_advisory_xact_lock` is a SESSION lock, so on
  one shared connection both racers acquire it re-entrantly and the test would
  stay red after the fix. A guard that cannot go green is not a guard.

  So this file runs `Sandbox.mode(Repo, :auto)` — real pooled connections, real
  transactions, real COMMITs — and deletes its own rows in `on_exit`. It is
  `async: false`; ExUnit runs sync tests only after every async test has
  finished, so no sandboxed peer is running while the mode is flipped.

  ## What the race proof actually proves

  The barrier is two-phase and carries NO sleep, so it is deterministic in both
  directions:

    1. Racer A opens its own transaction, runs the door (check passes, row is
       written) and then WAITS, uncommitted, holding whatever locks it took.
    2. Racer B is released only once A has written. It opens its OWN transaction
       on its OWN connection and runs the same door for the same hostname.
    3. The test waits for B's verdict with a bounded timeout, then tells A to
       commit either way.

  PRE-FIX, B is never blocked: its check runs under READ COMMITTED, cannot see
  A's uncommitted row, answers "free", and B writes. Its verdict arrives at once,
  both transactions commit, and TWO sites hold one hostname.

  POST-FIX, B blocks on `pg_advisory_xact_lock` inside `hostname_claimed?/2`
  before its first SELECT. Its verdict therefore does NOT arrive; the timeout
  fires, A commits and releases the lock, B wakes, and its check — now taking a
  fresh READ COMMITTED snapshot that DOES include A's committed row — refuses
  with `{:error, :domain_taken}`. The timeout is only ever reached in the fixed
  case, where it is measuring exactly the blocking the fix exists to produce.

  Every assertion is taken from the DATABASE, not from the racer return values,
  so a racer that dies on infrastructure cannot hide an overshoot: a dead racer
  committed nothing, and "exactly one owner" still fails if two rows landed.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, Site}

  # Every team this file creates is slugged with this prefix so `on_exit` can
  # delete them ALL. In `:auto` mode there is no sandbox rollback, so rows this
  # file commits would otherwise outlive it in a partition many suites share —
  # and a peer that does `Repo.all(Site)` would meet them.
  @slug_prefix "hcrace"

  # Racer B's verdict arrives in microseconds when it is NOT blocked, so this
  # bound is only ever spent in the fixed case. It is not a timing assertion:
  # neither outcome is decided by which side of it we land on — the assertions
  # below read the committed rows.
  @blocked_ms 3_000

  # A whole race is three round trips plus a commit.
  @racer_ms 30_000

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    n = System.unique_integer([:positive])
    host = "race-#{n}.example.com"

    on_exit(fn ->
      # Teams cascade (`on_delete: :delete_all`) to barkparks and to sites, so
      # this one delete reclaims every row the fixtures below committed.
      Repo.delete_all(from(t in Team, where: like(t.slug, ^(@slug_prefix <> "-%"))))
      Repo.delete_all(from(s in Site, where: fragment("? = ANY(?)", ^host, s.domains)))
      Repo.delete_all(from(b in Barkpark, where: b.custom_host == ^host))
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    %{host: host}
  end

  ## Fixtures — committed for real, so a second connection can see them.

  defp team_fixture do
    n = System.unique_integer([:positive])

    {:ok, team} =
      Accounts.create_team(%{name: "Team #{n}", slug: "#{@slug_prefix}-#{n}"})

    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp site_fixture(bp) do
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # How many rows across the WHOLE hostname namespace claim `host`? This is the
  # invariant: a hostname resolves to exactly ONE owning surface fleet-wide.
  defp owners(host) do
    sites =
      Repo.aggregate(
        from(s in Site, where: fragment("? = ANY(?)", ^host, s.domains)),
        :count,
        :id
      )

    boxes = Repo.aggregate(from(b in Barkpark, where: b.custom_host == ^host), :count, :id)
    sites + boxes
  end

  # Spawn UNLINKED. A racer that dies on a checkout timeout or a Postgres error
  # must be reported as that racer's outcome, never kill the test process.
  defp spawn_racer(fun) do
    parent = self()
    ref = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        result =
          try do
            fun.(parent, ref)
          rescue
            e -> {:infra, e}
          catch
            :exit, reason -> {:infra, reason}
          end

        send(parent, {ref, :done, result})
      end)

    %{pid: pid, mon: mon, ref: ref}
  end

  defp await_done(%{ref: ref, mon: mon}, timeout \\ @racer_ms) do
    receive do
      {^ref, :done, result} -> result
      {:DOWN, ^mon, :process, _, reason} -> {:infra, reason}
    after
      timeout -> {:infra, :timeout}
    end
  end

  describe "two concurrent claims of one hostname, each in its own transaction" do
    test "exactly one wins at the ATTACH door (add_site_domain/2)", %{host: host} do
      site_a = team_fixture() |> barkpark_fixture() |> site_fixture()
      site_b = team_fixture() |> barkpark_fixture() |> site_fixture()

      assert owners(host) == 0, "the hostname must start unclaimed"

      # A: write, then HOLD the transaction open until told to commit.
      a =
        spawn_racer(fn parent, ref ->
          Repo.transaction(
            fn ->
              result = Registry.add_site_domain(site_a, host)
              send(parent, {ref, :wrote, result})

              receive do
                {^ref, :commit} -> :ok
              after
                @racer_ms -> :ok
              end

              result
            end,
            timeout: @racer_ms
          )
        end)

      # A has written but NOT committed. This is the only interleave that matters.
      assert_receive {a_ref, :wrote, {:ok, %Site{}}}, @racer_ms
      ^a_ref = a.ref

      # B: the same hostname, a SECOND connection, a SECOND transaction.
      b =
        spawn_racer(fn parent, ref ->
          {:ok, result} =
            Repo.transaction(
              fn ->
                result = Registry.add_site_domain(site_b, host)
                send(parent, {ref, :verdict, result})
                result
              end,
              timeout: @racer_ms
            )

          result
        end)

      b_verdict_arrived? =
        receive do
          {ref, :verdict, _} when ref == b.ref -> true
        after
          @blocked_ms -> false
        end

      # Release A either way, so the fixed path can finish and the broken path
      # is not rescued by A never committing.
      send(a.pid, {a.ref, :commit})

      a_result = await_done(a)
      b_result = await_done(b)

      assert {:ok, {:ok, %Site{}}} = a_result,
             "racer A held the namespace first and must win (got #{inspect(a_result)})"

      # THE ASSERTION, taken from the committed rows and not from either racer.
      assert owners(host) == 1, """
      #{owners(host)} rows claim #{host}. Two concurrent claims both committed:
      the check-then-write in add_site_domain/2 is not serialised. The
      add_domain_cross_site_uniqueness trigger cannot catch this — its plpgsql
      EXISTS takes a READ COMMITTED snapshot that does not contain the racer's
      uncommitted row.

      A: #{inspect(a_result)}
      B: #{inspect(b_result)}
      B answered before A committed? #{b_verdict_arrived?}
      """

      assert b_result == {:error, :domain_taken},
             "the loser must get a clean refusal, not a crash or a second win " <>
               "(got #{inspect(b_result)})"

      refute b_verdict_arrived?, """
      racer B returned a verdict while racer A's transaction was still open, so
      B was never blocked. Even if exactly one row landed, nothing SERIALISED
      these two doors — that outcome is luck, not mutual exclusion.
      """
    end

    test "exactly one wins ACROSS doors: attach (site) vs custom_host (barkpark)", %{host: host} do
      site_a = team_fixture() |> barkpark_fixture() |> site_fixture()
      box_b = team_fixture() |> barkpark_fixture()

      assert owners(host) == 0

      a =
        spawn_racer(fn parent, ref ->
          Repo.transaction(
            fn ->
              result = Registry.add_site_domain(site_a, host)
              send(parent, {ref, :wrote, result})

              receive do
                {^ref, :commit} -> :ok
              after
                @racer_ms -> :ok
              end

              result
            end,
            timeout: @racer_ms
          )
        end)

      assert_receive {a_ref, :wrote, {:ok, %Site{}}}, @racer_ms
      ^a_ref = a.ref

      # The OTHER door. This pair is the cross-surface takeover vector: no index
      # and no trigger covers site-domain vs barkpark.custom_host at all, so
      # nothing but the shared lock can refuse it.
      b =
        spawn_racer(fn parent, ref ->
          {:ok, result} =
            Repo.transaction(
              fn ->
                result = Registry.set_custom_host(box_b, host)
                send(parent, {ref, :verdict, result})
                result
              end,
              timeout: @racer_ms
            )

          result
        end)

      b_verdict_arrived? =
        receive do
          {ref, :verdict, _} when ref == b.ref -> true
        after
          @blocked_ms -> false
        end

      send(a.pid, {a.ref, :commit})

      a_result = await_done(a)
      b_result = await_done(b)

      assert owners(host) == 1, """
      #{owners(host)} rows claim #{host} across the two surfaces. A site and a
      barkpark both took one hostname — the ask-gate would answer 200 for both
      owners and cert issuance becomes ambiguous. NO index and NO trigger covers
      this pair; only the shared per-hostname lock can.

      A (site attach): #{inspect(a_result)}
      B (custom_host): #{inspect(b_result)}
      B answered before A committed? #{b_verdict_arrived?}
      """

      assert b_result == {:error, :taken},
             "the custom_host door must refuse cleanly (got #{inspect(b_result)})"

      refute b_verdict_arrived?,
             "racer B was never blocked — the two doors do not share mutual exclusion"
    end
  end

  describe "the lock is issued, before the first SELECT, naming THIS hostname" do
    test "hostname_claimed?/2 emits pg_advisory_xact_lock ahead of every claim walk", %{
      host: host
    } do
      site = team_fixture() |> barkpark_fixture() |> site_fixture()

      sql = capture_sql(fn -> {:ok, _} = Registry.add_site_domain(site, host) end)
      queries = Enum.map(sql, &elem(&1, 0))

      lock = Enum.find_index(queries, &(&1 =~ "pg_advisory_xact_lock"))

      assert lock, """
      no advisory lock was issued. The check-then-write in add_site_domain/2 is
      back to being unserialised.

      statements: #{inspect(queries, limit: :infinity, printable_limit: :infinity)}
      """

      first_walk = Enum.find_index(queries, &(&1 =~ ~r/FROM "sites"/ and &1 =~ "LIMIT"))
      update = Enum.find_index(queries, &(&1 =~ ~r/UPDATE "sites"/))

      assert first_walk, "the claim walk must still run"
      assert update, "the row must still be written"

      assert lock < first_walk,
             "the lock must precede the first claim SELECT — locking after reading " <>
               "serialises nothing, the stale verdict is already in hand"

      assert lock < update, "the lock must precede the write"

      # PER-HOSTNAME SCOPE. A lock on anything else would serialise every domain
      # claim on the platform behind every other.
      {_q, params} = Enum.at(sql, lock)

      assert params == ["hostname:" <> host],
             "the lock must name THIS hostname (got #{inspect(params)})"
    end
  end

  # Collect every SQL statement the repo emits while `fun` runs. Lifted from
  # registry_barkpark_quota_race_test.exs, which proves its FOR UPDATE the same way.
  defp capture_sql(fun) do
    ref = make_ref()
    me = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:barkpark_cloud, :repo, :query],
      fn _event, _measure, meta, _cfg -> send(me, {ref, {meta.query, meta.params}}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain(ref, [])
  end

  defp drain(ref, acc) do
    receive do
      {^ref, entry} -> drain(ref, [entry | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
