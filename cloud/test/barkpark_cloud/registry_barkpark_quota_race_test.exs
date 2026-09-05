defmodule BarkparkCloud.RegistryBarkparkQuotaRaceTest do
  @moduledoc """
  acpc-bl-cloud-registry-barkpark-limit-toctou — `Registry.register_barkpark/2`
  was a count-then-compare quota TOCTOU:

      if Billing.barkpark_limit_reached?(team), do: {:error, :limit_reached},
        else: insert_barkpark(team, attrs)

  Check and insert were separate, uncoordinated calls with no transaction and no
  lock, so two registrations for the same team arriving at the ceiling both read
  the same count, both saw `false`, and both inserted. Unlike the api-side twin
  this guards a PAID plan boundary, so the overshoot is billable capacity given
  away — and it is reachable by any subscribed team through go-live, adopt and
  agent-register, with no admin required.

  ## Two proofs, because neither alone is enough

  **STRUCTURAL** (`the lock is issued...`): captures the repo's own query
  telemetry and asserts the emitted SQL is `BEGIN` → `SELECT ... FROM "teams"
  ... FOR UPDATE` → `INSERT INTO "barkparks"` → `COMMIT`, in that order. It is
  deterministic — no timing, no concurrency, no load sensitivity — and it fails
  the instant the lock or the transaction is removed. It cannot, by itself, show
  that the serialization has the effect anyone wants.

  **BEHAVIOURAL** (`concurrent registrations...`): fires racers at one free slot
  and asserts nothing overshoots. Read what this can and cannot exhibit: under
  `async: false` + `Sandbox.mode({:shared, self()})` every spawned task borrows
  the OWNER'S SINGLE CONNECTION (the same shape `accounts_test.exs`'s
  `failed_attempts` guard uses). So what is exhibited is the APPLICATION-level
  interleave — process A evaluates the count, yields, process B evaluates the
  same count — which is precisely the defect. What one shared connection CANNOT
  exhibit is `FOR UPDATE` blocking a second backend, because there is no second
  backend; the row lock is what carries this to a real pool across nodes.

  The behavioural test's assertions are therefore written as BOUNDS
  (`accepted <= 1`, `count == limit`) rather than as an exact tally of racer
  outcomes. A task that dies on a sandbox connection-checkout timeout — routine
  on a loaded host, since the fixed path holds the shared connection for a whole
  transaction — inserts nothing and so cannot hide an overshoot. Pre-fix the same
  assertions fail loudly: all 8 racers are accepted against a ceiling of 3.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Registry.Barkpark

  # `supporter` is 3 in config/config.exs — small enough to saturate cheaply.
  @plan "supporter"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp subscribed_team do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _sub} = Billing.subscribe(team, @plan)
    team
  end

  defp register(team) do
    n = System.unique_integer([:positive])
    Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
  end

  defp count(team), do: Repo.aggregate(where(Barkpark, team_id: ^team.id), :count, :id)

  # A racer that survives sandbox infrastructure failure. `Task.async_stream`
  # LINKS its tasks, so an unrescued `DBConnection.ConnectionError` kills the test
  # process outright instead of being reported as one racer's outcome — and on a
  # loaded host that error is routine here, because the fixed path holds the
  # single shared sandbox connection for a whole transaction while seven peers
  # queue behind it.
  #
  # THIS CANNOT MASK THE DEFECT IT TESTS FOR. A racer that dies on checkout never
  # reached `insert_barkpark/2`, so it inserted nothing; the `count(team) ==
  # limit` assertion below is taken from the DATABASE, not from these results, and
  # an overshoot survives any number of `:infra` samples. Pre-fix there are none
  # at all — with no transaction to hold the connection, all 8 racers complete and
  # all 8 are accepted.
  defp racer(team) do
    register(team)
  rescue
    e in DBConnection.ConnectionError -> {:infra, e}
  end

  # Collect every SQL statement the repo emits while `fun` runs.
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

  describe "the invariant is enforced by the database" do
    test "the lock is issued, on the TEAM row, BEFORE the count and inside the insert's transaction" do
      team = subscribed_team()

      captured = capture_sql(fn -> {:ok, _} = register(team) end)
      sql = Enum.map(captured, &elem(&1, 0))

      lock =
        Enum.find_index(sql, fn q ->
          q =~ ~r/FROM "teams"/ and q =~ "FOR UPDATE"
        end)

      assert lock, """
      no `FOR UPDATE` on "teams" was issued. The quota check and the insert are
      back to being two uncoordinated statements, and two concurrent
      registrations at the ceiling will both pass it.

      statements: #{inspect(sql, limit: :infinity, printable_limit: :infinity)}
      """

      begin = Enum.find_index(sql, &(&1 == "begin"))
      count_q = Enum.find_index(sql, &(&1 =~ ~r/SELECT count\(.*FROM "barkparks"/))
      insert = Enum.find_index(sql, &(&1 =~ ~r/INSERT INTO "barkparks"/))
      commit = Enum.find_index(sql, &(&1 == "commit"))

      assert begin, "the check and the insert must share a transaction"
      assert count_q, "the quota count must still be taken"
      assert insert, "the row must still be inserted"
      assert commit, "the transaction must commit"

      assert begin < lock,
             "the lock must be taken inside the transaction, or it is released before the insert"

      assert lock < count_q,
             "the lock must precede the COUNT — locking after reading the count " <>
               "serializes nothing, because the stale count is already in hand"

      assert count_q < insert and insert < commit,
             "count → insert → commit, one atomic act"

      # PER-TEAM SCOPE, proved where it CAN be proved. A shared-connection
      # sandbox cannot exhibit two teams failing to contend (there is only one
      # connection, so they contend regardless), but the lock's own parameter
      # settles it: it names THIS team's row, so it is a row lock and not a table
      # lock or a global gate. A lock taken on anything else would serialize every
      # registration on the platform behind every other.
      {_q, params} = Enum.at(captured, lock)

      assert params == [Ecto.UUID.dump!(team.id)] or params == [team.id],
             "the FOR UPDATE must name THIS team's row (got #{inspect(params)})"
    end

    test "a team with no active subscription is not locked into a quota it does not have" do
      # The entitlement gate (402) is what stops an unsubscribed team, not this
      # ceiling — `barkpark_limit_reached?/1` returns false for them. The lock
      # still runs (it is unconditional), but nothing here may start refusing.
      n = System.unique_integer([:positive])
      {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

      assert {:ok, %Barkpark{}} = register(team)
      assert {:ok, %Barkpark{}} = register(team)
    end
  end

  describe "concurrent registrations" do
    test "cannot overshoot the plan ceiling when racing for ONE free slot" do
      team = subscribed_team()
      limit = Map.fetch!(Billing.limits(), @plan)

      # Saturate to limit-1, so exactly ONE registration may legally succeed.
      for _ <- 1..(limit - 1), do: {:ok, _} = register(team)
      assert count(team) == limit - 1

      racers = 8

      results =
        1..racers
        |> Task.async_stream(fn _ -> racer(team) end,
          max_concurrency: racers,
          ordered: false,
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, r} -> r
          {:exit, reason} -> {:infra, reason}
        end)

      accepted = Enum.count(results, &match?({:ok, %Barkpark{}}, &1))

      assert accepted <= 1,
             "at most one racer may take the last slot; #{accepted} were accepted"

      assert count(team) == limit,
             "the team must hold exactly its plan ceiling — an overshoot here is " <>
               "billable capacity given away (holds #{count(team)}, ceiling #{limit})"
    end

    test "a team already AT the ceiling refuses every concurrent registration" do
      team = subscribed_team()
      limit = Map.fetch!(Billing.limits(), @plan)

      for _ <- 1..limit, do: {:ok, _} = register(team)

      1..6
      |> Task.async_stream(fn _ -> racer(team) end,
        max_concurrency: 6,
        ordered: false,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Stream.run()

      assert count(team) == limit, "not one row may be added past a saturated ceiling"
    end
  end

  test "a unique-constraint failure still returns a CHANGESET, not :rollback" do
    # THE SAVEPOINT GUARD. `insert_barkpark/2` now runs inside the quota
    # transaction, so without `mode: :savepoint` a constraint violation aborts the
    # transaction and `Repo.transaction` answers `{:error, :rollback}` instead of
    # `{:error, %Ecto.Changeset{}}`. That is not cosmetic: it is exactly the value
    # `insert_with_url_reservation/4` matches on to decide the clean-label ->
    # suffixed-FQDN fallback, so losing it would silently break go-live's
    # subdomain reservation for every collided label.
    team = subscribed_team()
    {:ok, _} = Registry.register_barkpark(team, %{name: "One", slug: "dup-slug"})

    assert {:error, %Ecto.Changeset{} = cs} =
             Registry.register_barkpark(team, %{name: "Two", slug: "dup-slug"})

    assert "is already taken by another Barkpark on this team" in errors_on(cs).slug
  end
end
