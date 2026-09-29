defmodule BarkparkCloud.DeployLedgerDeferralPacingTest do
  @moduledoc """
  THE READER THAT SHIPS WITH THE RECORDER (dr-bl-deferral-scheduled-vs-actual-gap,
  charter D401-S3).

  `Sites.Deploy.defer/3` now records `deferral_scheduled_s` beside
  `deferral_actual_gap_s`. A recorder with no human caller is the failure class
  this epic exists to delete, so this file reads what a HUMAN reads: the RENDERED
  BYTES of `DeferralPacing.report/1`, never the map behind them.

  ## The fixture is the 2026-08 corpus shape, deliberately

  `seed_band/2` seeds the shape the wave-23 hand measurement found — gaps
  clustered in the 55-75 s band against a 60 s scheduled window — so the same
  figures the task quotes come out of the RECORDED COLUMNS by one command
  instead of a session's SQL.

  ## What this file does NOT claim

  It does not reproduce the LIVE 61.6 s p50 over 2,262 rows. It cannot: both
  columns are NULL on every row written before the recorder landed and are never
  backfilled. The criterion is that the figures are re-DERIVABLE from the
  recorded fields going forward, and the `unmeasured` line below is the honest
  statement of that limit — an operator reading the report can never mistake
  "no row carries the fields yet" for "the gaps are zero".
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.DeployLedger.DeferralPacing
  alias BarkparkCloud.Registry.Deployment

  @password "correct-horse-battery"

  # PINNED, and it is the post-door window the 2,262-deferral measurement used.
  @from ~U[2026-08-06 22:29:27Z]
  @to ~U[2026-08-09 00:00:00Z]

  describe "the rendered report" do
    # IT CAN LOSE: delete the `"  ratio         "` line from `report/1` and this
    # test reds on the missing byte string, while `summarize/1` keeps returning
    # a perfectly correct ratio nobody can see. That asymmetry is the whole
    # reason this reads bytes.
    test "renders the scheduled-vs-actual RATIO over a pinned window, as bytes" do
      site = site_fixture()
      seed_band(site, gaps: [55, 58, 61, 64, 75], scheduled: 60)

      lines = DeferralPacing.report(from: @from, to: @to, site_id: site.id)
      text = Enum.join(lines, "\n")

      assert text =~ "DEFERRAL PACING — scheduled window vs actual gap"

      # THE RATIO IS RENDERED, not left for the reader to divide. p50 actual is
      # the nearest-rank 61 s of the five gaps; the scheduled window is 60 s.
      assert text =~ "p50 scheduled 60.0s"
      assert text =~ "p50 actual    61.0s"
      assert text =~ "ratio         1.02× actual/scheduled"

      # And the report names the LEVER, which is the decision the two columns
      # exist to settle.
      assert text =~ "CLOCK-PACED — the lever is our own backoff ladder"

      # The band the historical measurement pinned, counted off the same field.
      assert text =~ "band 55-75s  5 inside, 0 below"
      assert text =~ "scope         #{site.id}"
    end

    # THE OTHER DIRECTION, and it must be provable or the verdict is a constant.
    # Same reader, same window, gaps far past the window the ladder asked for.
    test "a BOX-PACED chain renders the opposite verdict off the same two columns" do
      site = site_fixture()
      seed_band(site, gaps: [240, 300, 360], scheduled: 60)

      text = DeferralPacing.report(from: @from, to: @to, site_id: site.id) |> Enum.join("\n")

      assert text =~ "p50 actual    300.0s"
      assert text =~ "ratio         5.0× actual/scheduled"
      assert text =~ "BOX-PACED — the wait is real contention"
      assert text =~ "band 55-75s  0 inside, 0 below"
    end

    # THE LIMIT OF THE CLAIM, RENDERED. Rows written before the recorder landed
    # carry NULL in both columns and are never backfilled. The report must say
    # so rather than dividing them away — a window of pre-recorder deferrals
    # that printed "CLOCK-PACED" would be a verdict about nothing.
    test "pre-recorder rows are counted as UNMEASURED, never as a zero gap" do
      site = site_fixture()

      # Three deferrals with NULL pacing — exactly the shape of every row on the
      # live control plane today.
      deployments!(site, [
        %{status: "deferred", inserted_at: ~U[2026-08-07 01:00:00Z]},
        %{status: "deferred", inserted_at: ~U[2026-08-07 01:01:00Z]},
        %{status: "deferred", inserted_at: ~U[2026-08-07 01:02:00Z]}
      ])

      text = DeferralPacing.report(from: @from, to: @to, site_id: site.id) |> Enum.join("\n")

      assert text =~ "deferrals     3 (0 measured, 3 unmeasured)"
      assert text =~ "p50 actual    n/a"
      assert text =~ "ratio         n/a"
      assert text =~ "NOT MEASURED — no deferral in this window carries both fields"
      refute text =~ "CLOCK-PACED"
    end

    # A row carrying ONE column without the other cannot contribute to a ratio,
    # and counting it on one side would tilt exactly the comparison the report
    # exists to make.
    test "a half-stamped row is UNMEASURED on both sides, not counted on one" do
      site = site_fixture()
      seed_band(site, gaps: [61], scheduled: 60)

      deployments!(site, [
        %{
          status: "deferred",
          inserted_at: ~U[2026-08-07 05:00:00Z],
          deferral_actual_gap_s: 9_000
        }
      ])

      text = DeferralPacing.report(from: @from, to: @to, site_id: site.id) |> Enum.join("\n")

      assert text =~ "deferrals     2 (1 measured, 1 unmeasured)"
      assert text =~ "p50 actual    61.0s"
    end

    # THE WINDOW IS A FENCE, not decoration: a gap outside it must not reach the
    # figure, or "over a pinned window" is a caption rather than a scope.
    test "the pinned window EXCLUDES rows outside it" do
      site = site_fixture()
      seed_band(site, gaps: [61], scheduled: 60)

      deployments!(site, [
        %{
          status: "deferred",
          inserted_at: ~U[2026-07-01 00:00:00Z],
          deferral_scheduled_s: 60,
          deferral_actual_gap_s: 9_000
        }
      ])

      text = DeferralPacing.report(from: @from, to: @to, site_id: site.id) |> Enum.join("\n")

      assert text =~ "deferrals     1 (1 measured, 0 unmeasured)"
      assert text =~ "p50 actual    61.0s"
    end
  end

  describe "the corpus figures" do
    # THE ONE COMMAND, PROVED. The task quotes 61.6 s p50 / 2,262 deferrals /
    # 1,441 inside the 55-75 s band / 4 below it — figures that existed only as
    # a paragraph and a SQL statement. This seeds a corpus of the SAME shape and
    # reads all four back off the RECORDED COLUMNS through the reader, which is
    # what "re-derivable, no hand SQL" has to mean.
    test "the band figures come back out of the recorded fields, not out of SQL" do
      site = site_fixture()

      # 2,262 gaps: 1,441 inside [55, 75], 4 below 55, the rest above — and a
      # p50 that lands in the band, as the live corpus's did.
      gaps =
        List.duplicate(50, 4) ++
          List.duplicate(61, 1_441) ++
          List.duplicate(120, 2_262 - 4 - 1_441)

      seed_band(site, gaps: gaps, scheduled: 60)

      summary = DeferralPacing.summarize(from: @from, to: @to, site_id: site.id)

      assert summary.deferrals == 2_262
      assert summary.measured == 2_262
      assert summary.in_band == 1_441
      assert summary.below_band == 4
      assert summary.p50_actual_gap_s == 61
      assert DeferralPacing.band() == {55, 75}

      # And the SAME four numbers are in the bytes a human reads.
      text = DeferralPacing.report(summary) |> Enum.join("\n")
      assert text =~ "deferrals     2262 (2262 measured, 0 unmeasured)"
      assert text =~ "p50 actual    61.0s"
      assert text =~ "band 55-75s  1441 inside, 4 below"
    end
  end

  defp seed_band(site, opts) do
    gaps = Keyword.fetch!(opts, :gaps)
    scheduled = Keyword.fetch!(opts, :scheduled)
    base = ~U[2026-08-07 00:00:00Z]

    rows =
      gaps
      |> Enum.with_index()
      |> Enum.map(fn {gap, i} ->
        %{
          status: "deferred",
          inserted_at: DateTime.add(base, i, :second),
          deferral_scheduled_s: scheduled,
          deferral_actual_gap_s: gap
        }
      end)

    deployments!(site, rows)
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

  # Struct inserts, not changesets: the instant and the status have to be pinned
  # exactly, and `Deployment.changeset/2` refuses to cast `status`.
  defp deployments!(site, rows) do
    entries =
      Enum.map(rows, fn r ->
        at = usec(Map.fetch!(r, :inserted_at))

        %{
          id: Ecto.UUID.generate(),
          site_id: site.id,
          status: Map.fetch!(r, :status),
          environment: "production",
          deferral_scheduled_s: Map.get(r, :deferral_scheduled_s),
          deferral_actual_gap_s: Map.get(r, :deferral_actual_gap_s),
          inserted_at: at,
          updated_at: at
        }
      end)

    entries
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Repo.insert_all(Deployment, &1))
  end

  defp usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}
end
