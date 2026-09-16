defmodule BarkparkCloud.DeployLedgerDrainDistributionTest do
  @moduledoc """
  THE RE-TAKE, PROVED IN BOTH DIRECTIONS
  (dr-w13-bl-waiting-alert-population-is-empty, charter D190/D211(b)).

  Wave 13 found the WAITING alert scoped against a population of ZERO. That is a
  claim about the WORLD and it rots, so the artefact is a re-taker, not a
  threshold. This file holds it to the bar a re-taker has to clear: every fact it
  asserts has an arm that makes it FALSE, because a verdict that only ever comes
  out one way is a constant wearing a measurement's clothes.

      fact asserted                      the arm that can flip it
      ─────────────────────────────────  ────────────────────────────────────
      "population is empty"              a chain served 2h30m later rules
                                         THRESHOLD DERIVABLE off the same reader
      "a young unserved row is censored"  the same row, aged past the fence,
                                         is counted and flips the ruling
      "rows and chains are one number"   40 rows on one 2,500s wait vs 1 head
      "the two clock keys agree"         a backfilled became_live_at moves p50
      "24h is 24h"                       a 12h13m window refuses to rule at all

  It reads the RENDERED lines wherever the claim is one an operator makes, since
  a correct map nobody can see is not a report.

  NOTHING HERE IS A LIVE READING. The live 24h/72h re-take needs the production
  database, which this suite cannot reach; wave 13's figures live in
  `inherited_reading/0`, labelled, and the last test in this file proves the
  reader never quotes them as its own.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.DeployLedger.DrainDistribution
  alias BarkparkCloud.Registry.Deployment

  @password "correct-horse-battery"

  # The D179 boundary + 25h40m: past the 24h mark the criterion asks for, so the
  # reader is allowed to rule at all.
  @to ~U[2026-08-08 00:00:00Z]
  @r409 "the instance refused the deploy (HTTP 409)"

  describe "the ruling, both ways" do
    test "a fleet that drains inside the hour rules POPULATION EMPTY" do
      site = site_fixture()
      seed_chain(site, at: ~U[2026-08-07 06:00:00Z], rounds: 5, every: 60, served_after: 212)

      text = DrainDistribution.report(to: @to, site_id: site.id) |> Enum.join("\n")

      assert text =~ "DRAIN DISTRIBUTION — post-regime deferral wait"
      assert text =~ "deferrals     5 (5 uncensored, 0 censored"
      assert text =~ "chains        1 heads"
      assert text =~ "POPULATION EMPTY — 0 of 1 chain heads waited 1h0m"
      refute text =~ "THRESHOLD DERIVABLE"
    end

    # THE ARM. Same reader, same window, one chain the fleet took 2h30m to serve.
    test "a chain served past the hour rules THRESHOLD DERIVABLE off the same reader" do
      site = site_fixture()
      seed_chain(site, at: ~U[2026-08-07 06:00:00Z], rounds: 5, every: 60, served_after: 9_000)

      text = DrainDistribution.report(to: @to, site_id: site.id) |> Enum.join("\n")

      assert text =~ "THRESHOLD DERIVABLE — 1 of 1 chain heads waited 1h0m"
      # The candidate names its UNIT, its WINDOW and its REGIME — charter D191.
      assert text =~ "per CHAIN HEAD over"
      assert text =~ "post-D179 regime only"
      refute text =~ "POPULATION EMPTY"
    end

    # A deferral nobody ever served is not a mystery: past the censoring fence it
    # is a row that waited longer than the alert's threshold, and it rules.
    test "a never-served uncensored deferral counts as waited, not as missing data" do
      site = site_fixture()
      deferrals!(site, [{~U[2026-08-07 06:00:00Z], "box_at_capacity"}])

      text = DrainDistribution.report(to: @to, site_id: site.id) |> Enum.join("\n")

      assert text =~ "THRESHOLD DERIVABLE — 1 of 1 chain heads waited"
      assert text =~ "p50=n/a"
    end
  end

  describe "right-censoring" do
    # WAVE 13'S WHOLE FALSE ALARM. Its eight "unserved" rows were 0-17 minutes
    # old — they had not been OBSERVED for an hour, so they could not be said to
    # have waited one. Delete the censor fence in `summarize/1` and this test
    # reds on both lines: the censored count goes to 0 and the ruling flips.
    test "a deferral younger than the fence is counted OUT of the sample and named" do
      site = site_fixture()
      seed_chain(site, at: ~U[2026-08-07 06:00:00Z], rounds: 3, every: 60, served_after: 212)
      # 10 minutes before `to`, never served: right-censored, not a long wait.
      deferrals!(site, [{DateTime.add(@to, -600, :second), "box_at_capacity"}])

      text = DrainDistribution.report(to: @to, site_id: site.id) |> Enum.join("\n")

      assert text =~ "deferrals     4 (3 uncensored, 1 censored: younger than 1h0m)"
      assert text =~ "POPULATION EMPTY — 0 of 1 chain heads"
    end

    # THE CONTROL FOR THE CONTROL: the same row, older than the fence, is inside
    # the sample and flips the ruling. Without this the test above would pass on
    # a reader that dropped every unserved row, censored or not.
    test "the same row, aged past the fence, is inside the sample and rules" do
      site = site_fixture()
      seed_chain(site, at: ~U[2026-08-07 06:00:00Z], rounds: 3, every: 60, served_after: 212)
      deferrals!(site, [{DateTime.add(@to, -7_200, :second), "box_at_capacity"}])

      text = DrainDistribution.report(to: @to, site_id: site.id) |> Enum.join("\n")

      assert text =~ "deferrals     4 (4 uncensored, 0 censored"
      assert text =~ "THRESHOLD DERIVABLE — 1 of 2 chain heads"
    end
  end

  describe "the unit" do
    # ~40 rows ride one 2,500-second wait, so a row-keyed p95 describes a chain
    # and calls it a fleet. Both units are computed and both are rendered.
    test "rows and chain heads are different numbers over the same fleet" do
      site = site_fixture()
      seed_chain(site, at: ~U[2026-08-07 02:00:00Z], rounds: 40, every: 60, served_after: 2_500)

      # Six short, separate publishes — each its own chain head (gaps > 300s).
      Enum.each(0..5, fn i ->
        seed_chain(site,
          at: DateTime.add(~U[2026-08-07 10:00:00Z], i * 3_600, :second),
          rounds: 1,
          every: 60,
          served_after: 200
        )
      end)

      s = DrainDistribution.summarize(to: @to, site_id: site.id)
      rows = Enum.find(s.rows, &(&1.cause == "ALL"))
      chains = Enum.find(s.chains, &(&1.cause == "ALL"))

      assert rows.n == 46
      assert chains.n == 7
      # The row unit is dragged up by the 40-row chain; the chain unit is not.
      assert rows.p50 > chains.p50
      assert s.population.chains == 7

      text = DrainDistribution.report(s) |> Enum.join("\n")
      assert text =~ "  per rows:"
      assert text =~ "  per chains:"
      assert text =~ "chains        7 heads (a gap over 300s opens one)"
    end

    test "the cause split uses the ledger's own class names" do
      site = site_fixture()
      seed_chain(site, at: ~U[2026-08-07 06:00:00Z], rounds: 2, every: 60, served_after: 212)

      # A codeless bare 409 is the busy slug, not the capacity cap.
      deferrals!(site, [{~U[2026-08-07 08:00:00Z], nil}])
      lives!(site, [~U[2026-08-07 08:05:00Z]])

      text = DrainDistribution.report(to: @to, site_id: site.id) |> Enum.join("\n")

      assert text =~ "BOX_AT_CAPACITY_DEFERRED"
      assert text =~ "BOX_BUSY_DEFERRED"
    end
  end

  describe "the clock key" do
    # The two keys are a CROSS-CHECK, so they must be able to disagree. A live row
    # whose published mark trails its insert by four minutes moves the reading.
    test "became_live_at and inserted_at are different readings of the same rows" do
      site = site_fixture()
      deferrals!(site, [{~U[2026-08-07 06:00:00Z], "box_at_capacity"}])

      lives!(site, [{~U[2026-08-07 06:01:00Z], ~U[2026-08-07 06:05:00Z]}])

      by_live = DrainDistribution.summarize(to: @to, site_id: site.id, key: :became_live_at)
      by_insert = DrainDistribution.summarize(to: @to, site_id: site.id, key: :inserted_at)

      assert Enum.find(by_live.rows, &(&1.cause == "ALL")).p50 == 300.0
      assert Enum.find(by_insert.rows, &(&1.cause == "ALL")).p50 == 60.0
      assert DrainDistribution.report(by_insert) |> Enum.join("\n") =~ "clock key     inserted_at"
    end

    # A NULL published mark is NOT silently defaulted to the insert instant —
    # that would make the two keys one measurement and destroy the cross-check.
    test "a live row with no published mark carries no mark under that key" do
      site = site_fixture()
      deferrals!(site, [{~U[2026-08-07 06:00:00Z], "box_at_capacity"}])
      lives!(site, [{~U[2026-08-07 06:01:00Z], nil}])

      by_live = DrainDistribution.summarize(to: @to, site_id: site.id, key: :became_live_at)
      by_insert = DrainDistribution.summarize(to: @to, site_id: site.id, key: :inserted_at)

      assert Enum.find(by_live.rows, &(&1.cause == "ALL")).no_live_1h == 1
      assert Enum.find(by_insert.rows, &(&1.cause == "ALL")).no_live_1h == 0
    end
  end

  describe "the regime" do
    # Every wave-13 figure was taken 12h13m past the boundary. The criterion asks
    # for 24h. The reader says so instead of ruling off a half-grown window.
    test "a window younger than 24h refuses to rule" do
      site = site_fixture()
      seed_chain(site, at: ~U[2026-08-07 02:00:00Z], rounds: 3, every: 60, served_after: 212)

      young = DateTime.add(DrainDistribution.regime_boundary(), 43_995, :second)
      text = DrainDistribution.report(to: young, site_id: site.id) |> Enum.join("\n")

      assert text =~ "WINDOW TOO YOUNG — 12h13m past the regime boundary"
      refute text =~ "POPULATION EMPTY"
      assert DrainDistribution.retake_marks() == [{"24h", 86_400}, {"72h", 259_200}]
    end

    test "a window starting before the boundary says it blends two regimes" do
      site = site_fixture()
      seed_chain(site, at: ~U[2026-08-07 06:00:00Z], rounds: 2, every: 60, served_after: 212)

      text =
        DrainDistribution.report(from: ~U[2026-08-01 00:00:00Z], to: @to, site_id: site.id)
        |> Enum.join("\n")

      assert text =~ "WINDOW STRADDLES THE BOUNDARY: this blends two regimes"

      quiet = DrainDistribution.report(to: @to, site_id: site.id) |> Enum.join("\n")
      refute quiet =~ "STRADDLES"
    end

    test "the default window starts at the D179 boundary, not at an arbitrary date" do
      assert DrainDistribution.regime_boundary() == ~U[2026-08-06 22:19:52.000000Z]
      assert DrainDistribution.summarize(to: @to).from == DrainDistribution.regime_boundary()
    end
  end

  describe "inherited numbers" do
    # THE TRAP THIS MODULE EXISTS TO CLOSE. Wave 13's figures are somebody else's
    # measurement at an earlier date. They are available, labelled, and they never
    # appear in a reading.
    test "wave 13's reading is labelled inherited and never answers for a fresh one" do
      inherited = DrainDistribution.inherited_reading()

      assert inherited.provenance == "inherited"
      assert inherited.n == 1_110
      assert inherited.taken_at == ~U[2026-08-07 10:31:00Z]
      assert inherited.caveat =~ "12h13m past the regime boundary"

      # An empty fleet reads EMPTY. It does not read 1,110.
      s = DrainDistribution.summarize(to: @to)
      assert Enum.find(s.rows, &(&1.cause == "ALL")).n == 0
      assert s.population.uncensored == 0

      text = DrainDistribution.report(s) |> Enum.join("\n")
      assert text =~ "NO SAMPLE"
      refute text =~ "1110"
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  # One deferral chain plus the live row that serves it.
  defp seed_chain(site, opts) do
    at = Keyword.fetch!(opts, :at)
    rounds = Keyword.fetch!(opts, :rounds)
    every = Keyword.fetch!(opts, :every)
    served = Keyword.fetch!(opts, :served_after)

    deferrals!(
      site,
      Enum.map(0..(rounds - 1), fn i ->
        {DateTime.add(at, i * every, :second), "box_at_capacity"}
      end)
    )

    lives!(site, [DateTime.add(at, served, :second)])
  end

  defp deferrals!(site, stamps) do
    insert_all!(
      site,
      Enum.map(stamps, fn {at, code} ->
        %{
          status: "deferred",
          inserted_at: at,
          failure_reason: @r409,
          box_refusal_code: code,
          became_live_at: nil
        }
      end)
    )
  end

  defp lives!(site, marks) do
    insert_all!(
      site,
      Enum.map(marks, fn
        {inserted_at, became_live_at} ->
          %{status: "live", inserted_at: inserted_at, became_live_at: became_live_at}

        at ->
          %{status: "live", inserted_at: at, became_live_at: at}
      end)
    )
  end

  # Struct inserts, not changesets: the instant and the status have to be pinned
  # exactly, and `Deployment.changeset/2` refuses to cast `status`.
  defp insert_all!(site, rows) do
    entries =
      Enum.map(rows, fn r ->
        at = usec(Map.fetch!(r, :inserted_at))

        %{
          id: Ecto.UUID.generate(),
          site_id: site.id,
          status: Map.fetch!(r, :status),
          environment: "production",
          failure_reason: Map.get(r, :failure_reason),
          box_refusal_code: Map.get(r, :box_refusal_code),
          became_live_at: r |> Map.get(:became_live_at) |> maybe_usec(),
          inserted_at: at,
          updated_at: at
        }
      end)

    entries
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Repo.insert_all(Deployment, &1))
  end

  defp site_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} = Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  defp maybe_usec(nil), do: nil
  defp maybe_usec(dt), do: usec(dt)

  defp usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}
end
