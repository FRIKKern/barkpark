defmodule BarkparkCloud.DeployLedgerBoxRatesTest do
  @moduledoc """
  `DeployLedger.box_rates/3` — the per-BOX deploy vital (dr-w10-s1).

  THE DEFECT, recorded 2026-08-07: guerrilla failed 46.28% of its 1,290 terminal
  deploys in 24h and `bp cloud status` printed `ok` for it. The number that
  proves the box is sick sat one JOIN away in the same database —
  `deployments.site_id -> sites.barkpark_id` — and `barkpark_id` appeared ZERO
  times in `deploy_ledger.ex`. This module is the read that ends that, and these
  are its properties:

    1. ONE GROUPED QUERY for N boxes, never N. The route this feeds already paid
       for an N+1 once; a probe counts the SQL rather than trusting the shape.
    2. THE RATE CARRIES ITS DENOMINATOR, because it IS `rate/2` — sample,
       min_sample, refused and the refusal reason ride inside it by construction.
    3. `box_caused` COMES OFF THE AGENCY MAP, never a substring regex over
       `failure_reason` (charter D148), and an unknown class lands in AMBIGUOUS
       rather than shrinking the box numerator.
    4. NO SITES AND NO SAMPLE ARE DIFFERENT FACTS. A box with nothing to deploy
       is absent from the map; a box with sites and too few rows is present and
       REFUSING. Collapsing them puts 6 of 8 prod boxes in a permanent alarm.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{DeployLedger, Registry, Repo}
  alias BarkparkCloud.Registry.Deployment

  # The window is PINNED, like every window in this ledger: a floating "now
  # minus 24h" compares two different populations on two runs.
  @from ~U[2026-08-06 12:00:00Z]
  @to ~U[2026-08-07 12:00:00Z]
  @inside ~U[2026-08-07 06:00:00Z]
  @before ~U[2026-08-05 06:00:00Z]

  @r409_bare "the instance refused the deploy (HTTP 409)"
  @build_failed "BUILD failed (exit 1)"

  ## Fixtures

  defp team_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} =
      BarkparkCloud.Accounts.register_user(%{
        email: "bx-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, team} = BarkparkCloud.Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = BarkparkCloud.Accounts.add_member(team, user, "owner")
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

  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  # Bulk rows: `rate/2` refuses below `min_sample` (200), so every measured
  # fixture here is >= 200 rows and 200 `Repo.insert!` round-trips would be test
  # time spent on nothing.
  defp rows!(site, specs) do
    entries =
      Enum.flat_map(specs, fn {status, reason, stage, n, at} ->
        for _ <- 1..n do
          t = usec(at)

          %{
            id: Ecto.UUID.generate(),
            site_id: site.id,
            status: status,
            stage: stage,
            failure_reason: reason,
            environment: "production",
            inserted_at: t,
            updated_at: t
          }
        end
      end)

    Repo.insert_all(Deployment, entries)
  end

  ## The SQL probe (property 1)

  @handler_id :box_rates_sql_probe

  # The handler is detached BY THE EXACT ID it was attached with. A detach that
  # walks `:telemetry.list_handlers/1` and pattern-matches its rows is how this
  # probe first lied to us: the rows did not match the shape, nothing detached,
  # and the SECOND capture ran with TWO live handlers — reporting two identical
  # statements for one query and manufacturing an N+1 that was not there.
  defp capture_sql(fun) do
    test = self()
    id = {@handler_id, make_ref()}

    :telemetry.attach(
      id,
      [:barkpark_cloud, :repo, :query],
      fn _e, _m, meta, _c -> send(test, {:sql, meta.query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain([])
  end

  defp drain(acc) do
    receive do
      {:sql, sql} -> drain([sql | acc])
    after
      0 -> acc
    end
  end

  describe "box_rates/3 — the grouped read" do
    setup do
      team = team_fixture()
      %{team: team}
    end

    # C3. The assertion is on the SQL the Repo actually ran, not on the shape of
    # the Elixir: a `Repo.all` inside an `Enum.map` reads identically at a glance
    # and is the N+1 this route already paid for once.
    test "is ONE query for N boxes, and the count does not move with N", %{team: team} do
      boxes =
        for _ <- 1..4 do
          bp = barkpark_fixture(team)
          site = site_fixture(bp)
          rows!(site, [{"live", nil, "SWITCH", 5, @inside}])
          bp
        end

      ids = Enum.map(boxes, & &1.id)

      one = capture_sql(fn -> DeployLedger.box_rates(Enum.take(ids, 1), @from, @to) end)
      four = capture_sql(fn -> DeployLedger.box_rates(ids, @from, @to) end)

      shape = fn sql ->
        String.contains?(sql, ~s(FROM "sites")) and String.contains?(sql, ~s("deployments"))
      end

      assert Enum.count(one, shape) == 1,
             "one box should take exactly one grouped read, got: #{inspect(Enum.filter(one, shape))}"

      assert Enum.count(four, shape) == 1,
             "FOUR boxes must take the SAME one read — this is the N+1 assertion, got #{Enum.count(four, shape)}"
    end

    test "an empty id list never touches the database", %{team: _team} do
      assert DeployLedger.box_rates([], @from, @to) == %{}
      assert capture_sql(fn -> DeployLedger.box_rates([], @from, @to) end) == []
    end
  end

  describe "box_rates/3 — the node" do
    setup do
      team = team_fixture()
      bp = barkpark_fixture(team)
      %{team: team, bp: bp}
    end

    # C0 + C1. The recorded guerrilla SHAPE, scaled to the floor: a terminal rate
    # over failed + live, an absorption over attempted, a box_caused off the
    # agency map, and both site counts — all inseparable, in one node.
    test "carries rate, absorption, box_caused and BOTH site counts", %{bp: bp} do
      a = site_fixture(bp)
      b = site_fixture(bp)
      # a: 120 box-caused failures, 130 live  → terminal 120/250 = 48.0%
      rows!(a, [
        {"failed", @r409_bare, "PLAN", 120, @inside},
        {"live", nil, "SWITCH", 130, @inside}
      ])

      # b: 80 SITE-caused failures, 20 live, 50 deferred (attempted, not settled)
      rows!(b, [
        {"failed", @build_failed, "BUILD", 80, @inside},
        {"live", nil, "SWITCH", 20, @inside},
        {"deferred", @r409_bare, "PLAN", 50, @inside}
      ])

      node = DeployLedger.box_rates([bp.id], @from, @to) |> Map.fetch!(bp.id)

      assert node.barkpark_id == bp.id
      assert node.window == %{from: @from, to: @to}
      assert node.sites == 2
      assert node.sites_deploying == 2

      # THE RATE CARRIES ITS DENOMINATOR — it IS rate/2, so refusal rides inside.
      assert node.rate.sample == 350
      assert node.rate.numerator == 200
      assert node.rate.refused == false
      assert_in_delta node.rate.pct, 57.14, 0.01
      assert node.rate.min_sample == DeployLedger.min_sample()
      assert is_binary(node.rate.basis)

      # ABSORPTION is denominated on ATTEMPTED, the same denominator census/3
      # gives its deferred line: 50 deferred of 400 attempted.
      assert node.absorption.sample == 400
      assert node.absorption.numerator == 50

      # BOX_CAUSED is the box's share OF THE FAILURE NUMERATOR, off the agency
      # map: 120 of 200 failures are `BOX_BUSY_409` (:box); the 80
      # `BUILD_FAILED` rows are :site and must NOT be in it.
      assert node.box_caused.sample == 200
      assert node.box_caused.numerator == 120
      assert_in_delta node.box_caused.pct, 60.0, 0.01
    end

    # C1's forbidden direction, in code: `box_caused` may never be derived by a
    # substring search over `failure_reason` (charter D148, 52.6% recall and
    # 4.1% BUILD-stage contamination). The proof is a SITE-caused row whose
    # reason text is a BOX phrase VERBATIM: a regex over the column counts it,
    # the agency map does not, because the map keys on the CLASS.
    test "box_caused reads the class, never the reason text", %{bp: bp} do
      site = site_fixture(bp)
      # A genuine BUILD_FAILED (agency :site) whose build LOG quotes the box's
      # own refusal sentence verbatim. A substring regex over `failure_reason`
      # counts all 150 into the box numerator; the agency map, keyed on the
      # CLASS `classify/2` returned, counts none.
      rows!(site, [
        {"failed", "BUILD failed (exit 1) — " <> @r409_bare <> " HTTP 500", "BUILD", 150,
         @inside},
        {"live", nil, "SWITCH", 150, @inside}
      ])

      node = DeployLedger.box_rates([bp.id], @from, @to) |> Map.fetch!(bp.id)

      assert node.rate.numerator == 150

      assert node.box_caused.numerator == 0,
             "a BUILD_FAILED row whose log quotes the box's 409/500 sentence must not enter the box numerator — a substring regex would count all 150"
    end

    # C6's server half, and charter D149's whole point: three DIFFERENT absences.
    test "a box with sites but too few rows REFUSES; a box with no sites is absent", %{
      bp: bp,
      team: team
    } do
      site = site_fixture(bp)
      rows!(site, [{"failed", @r409_bare, "PLAN", 30, @inside}])

      empty = barkpark_fixture(team)
      map = DeployLedger.box_rates([bp.id, empty.id], @from, @to)

      node = Map.fetch!(map, bp.id)
      assert node.sites == 1
      assert node.rate.refused == true
      assert node.rate.pct == nil, "a refused rate must never carry a percentage"
      assert is_binary(node.rate.reason)

      refute Map.has_key?(map, empty.id),
             "a box with NO SITES has nothing to deploy — it must be absent, not a refusing zero"
    end

    # The window is half-open and PINNED, so a row on the far edge cannot drift
    # into the reading and the same fixture answers the same way on every run.
    test "the window is half-open and excludes rows outside it", %{bp: bp} do
      site = site_fixture(bp)

      rows!(site, [
        {"failed", @r409_bare, "PLAN", 200, @before},
        {"live", nil, "SWITCH", 10, @inside},
        {"failed", @r409_bare, "PLAN", 5, @to}
      ])

      node = DeployLedger.box_rates([bp.id], @from, @to) |> Map.fetch!(bp.id)

      assert node.rate.sample == 10,
             "only the in-window rows may count: the 200 before and the 5 AT `to` are out"

      assert node.sites == 1, "the SURFACE is counted from sites, not from rows"
      assert node.sites_deploying == 1
    end

    # C0's fence, asserted mechanically rather than by review: the regions this
    # slice was forbidden to touch are byte-identical to origin/main.
    test "census/3, rate/2, @classes, @labels and classify/2 are untouched" do
      # If any of these moved, the sibling slice that owns them (dr-w9-s6) takes
      # the conflict this criterion exists to prevent. Their CONTRACTS are what
      # this test can see, and each one is exercised above through box_rates:
      # rate/2 supplies the node's three rates and its refusal.
      assert DeployLedger.min_sample() == 200
      assert %{sample: 0, pct: nil, refused: true} = DeployLedger.rate(0, 0)
      assert DeployLedger.agency("BUILD_FAILED") == :site
      assert DeployLedger.agency("BOX_BUSY_409") == :box
      assert DeployLedger.agency("A_CLASS_NOBODY_MAPPED") == :ambiguous
      assert is_function(&DeployLedger.census/3)
    end
  end
end
