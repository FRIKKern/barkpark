defmodule BarkparkCloud.DeployLedgerPartitionTest do
  @moduledoc """
  THE CENSUS COHORTS PARTITION `volume` — deploy-reliability W17 S4.

  `DeployLedger.census/3` computes the residue BY SUBTRACTION:

      residual = volume - (failed + total(deferred) + live + in_flight + cancelled)

  and `deployments.status` is a CHECK-less varchar (`SELECT conname FROM
  pg_constraint WHERE conrelid = 'deployments'::regclass AND contype = 'c'`
  returns ZERO rows on cloud-db-1). So nothing in the database stops an unnamed
  status entering the census, and until this file nothing in the tree asserted
  that the six terms of that subtraction are DISJOINT. A cohort counted twice
  does not red — it drives `residual` NEGATIVE and the census prints it as a
  number, which is exactly the shape of report this epic exists to refuse.

  ## The escape this file closes, and the one it does NOT

  THE FILED PREMISE WAS WRONG, AND IS CORRECTED HERE. The backlog row
  `dr-w16-bl-residual-cannot-go-negative` states that adding `live` to
  `@in_flight_statuses` makes `residual` go negative "while every test stays
  green". Run this wave, that mutation REDS THREE TESTS in
  `deploy_ledger_test.exs` (`in_flight` 100 != 0, `residual` -6 != 0,
  `residual` -3 != 3) — two hand-built fixtures happen to pin `in_flight` and
  `cancelled` by exact equality. Adding `cancelled` there reds one. Those
  escapes were already closed, by accident.

  THE REAL ESCAPE IS THE DEFERRED COHORT, because it is the one cohort split out
  by CLASS (`Enum.split_with(attempted, &deferred?(&1.class))`) while
  live / in_flight / cancelled are filtered by STATUS. A term keyed on
  `status == "deferred"` over `attempted` therefore overlaps the deferred cohort
  INVISIBLY. Measured: adding exactly that term to the subtraction left the
  ENTIRE cloud suite — 3,131 tests — green, while driving `residual` to -3 on a
  probe fixture (-2,124 on the prod corpus). Cause: only four residual
  assertions existed, and NOT ONE of their fixtures contained a deferred row. A
  guard whose fixture cannot produce the defect is green by construction.

  Hence the two rules this file is built on:

    1. THE FIXTURE CARRIES ONE ROW OF EVERY STATUS THE CENSUS NAMES, INCLUDING
       DEFERRED ONES (one per deferred class) and one status the census has
       never been taught, so every term of the identity is non-zero and an
       overlap has nowhere to hide.

    2. BOTH HALVES OF THE GUARD ARE ASSERTED. `residual >= 0` ALONE IS
       INSUFFICIENT: an overlap SMALLER than the true residue leaves the residue
       positive and the guard sleeps through it. The partition identity
       `failed + sum(deferred) + live + in_flight + cancelled + residual ==
       volume` is the load-bearing half. And note that computing `residual`
       POSITIVELY instead would make negativity impossible by construction while
       being unable to detect the double count AT ALL — so the identity is
       required either way, which is why this guard is written against the
       observable census map and not against the arithmetic that produced it.

  ## The sample-size trap

  This fixture is far below `min_sample/0` (200), so the census REFUSES its
  rates — `failure_rate.pct` and `live_rate.pct` are `nil` here BY DESIGN. This
  file therefore guards COUNTS and the IDENTITY, never the rate nodes. Do not
  fold these assertions into a rate-asserting fixture without re-deriving the
  sample size, or the rate assertions go vacuous by refusal.

  ## The zero-population caveat (recorded, not fixed)

  The prod corpus exercises only 4 of the 7 statuses this census names:
  `cancelled`, `queued` and `pushing` have never had a single row on cloud-db-1
  (0 of 31,137 all-time). Their arithmetic is certified ONLY by the synthetic
  fixture below. And `residual` has never once risen on prod — it measured 0 on
  each of the last 8 days and over the whole 31,130-row corpus — so its ability
  to RISE has never been exhibited outside a test. That is the honest shape of
  this defect: not a live bug, an unguarded invariant.

  Collateral fact, also measured on cloud-db-1 this wave: a live-and-failed
  double count is impossible FROM DATA (`classify/1` returns non-nil only for
  status `failed` and `deferred`, and no live row anywhere carries a
  `failure_reason`). The overlap hazard is purely a CODE hazard — which is
  precisely why it needs a code-shaped guard.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, DeployLedger, Registry, Repo}
  alias BarkparkCloud.Registry.Deployment

  @password "correct-horse-battery"

  # Verbatim corpus shapes (2026-08-05 re-derivation), same strings the ledger
  # test uses — a fixture built on invented text proves nothing about the
  # classifier that has to read the real column.
  @r409_bare "the instance refused the deploy (HTTP 409)"
  @requeued " — deferred: a rebuild carrying this content has been re-queued and will run once the in-flight deploy finishes"
  @d_busy_bare @r409_bare <> @requeued
  @d_capacity "the instance refused the deploy (HTTP 409): box_at_capacity — the box is at its build capacity (1 of 1 build slots in use) — site 'other-site' is building; retry when it finishes" <>
                @requeued
  # A deferral shape the ledger has never seen — lands in DEFERRED_UNCLASSIFIED.
  @d_novel "the boxcar shim deferred the handshake (code BLERG-7)" <> @requeued
  # Born-failed tombstone: NOT an attempt, so it must stay outside `volume`.
  @gh_push "github push builds require the GitHub App integration (not yet available) — deploy an artifact via bp deploy"

  @from ~U[2026-07-26 00:00:00Z]
  @to ~U[2026-07-27 00:00:00Z]

  setup do
    {_user, team} = user_team()
    %{team: team, site: site_fixture(team)}
  end

  describe "census/3 — the named cohorts PARTITION volume" do
    test "one row of EVERY named status: residual >= 0 AND the cohorts sum to volume", ctx do
      census = every_status_census(ctx)

      # ── HALF ONE: the residue is a COUNT, and a count is never negative. ──
      # This catches an overlap LARGER than the true residue.
      assert census.residual >= 0,
             "residual went NEGATIVE (#{census.residual}) — a cohort is double counting"

      # ── HALF TWO, the load-bearing one: the six named terms PARTITION the
      # population. `residual >= 0` alone sleeps through an overlap smaller than
      # the residue (here: any double count of 1 row leaves residual at 1 and
      # says nothing); the identity reds on an overlap of a SINGLE row. ──
      assert census.failed + deferred_total(census) + census.live + census.in_flight +
               census.cancelled + census.residual == census.volume,
             """
             the census cohorts do not partition volume:
               failed=#{census.failed} deferred=#{deferred_total(census)} live=#{census.live} \
             in_flight=#{census.in_flight} cancelled=#{census.cancelled} \
             residual=#{census.residual} volume=#{census.volume}
             """

      # ── …and the fixture itself, stated as counts, so a silent cohort MOVE
      # (which preserves the identity) is visible too. These come last on
      # purpose: the two halves above are the guard, and they must be the
      # assertions that speak when a cohort double counts. ──
      assert census.volume == 21
      assert census.failed == 5
      assert deferred_total(census) == 3
      assert census.live == 7
      assert census.in_flight == 3
      assert census.cancelled == 1
      assert census.residual == 2
    end

    test "the guard is NOT VACUOUS: every term of the identity is non-zero here", ctx do
      census = every_status_census(ctx)

      # A partition identity over a fixture with empty cohorts is an identity
      # over nothing — the exact failure mode of the four pre-existing residual
      # fixtures, none of which held a deferred row. Each term carries mass, so
      # each term is a place an overlap can be caught.
      for {name, n} <- [
            failed: census.failed,
            deferred: deferred_total(census),
            live: census.live,
            in_flight: census.in_flight,
            cancelled: census.cancelled,
            residual: census.residual
          ] do
        assert n > 0, "cohort #{name} is empty — the partition identity is vacuous against it"
      end

      # And the deferred cohort — the one split by CLASS while its neighbours
      # are filtered by STATUS, which is where the measured escape lives — holds
      # all three deferred classes, so an overlap cannot hide in an unpopulated
      # arm of the taxonomy.
      classes = census.deferred |> Enum.map(& &1.class) |> Enum.sort()
      assert classes == Enum.sort(DeployLedger.deferred_classes())
    end

    test "rows that were never attempted stay OUTSIDE the partition entirely", ctx do
      census = every_status_census(ctx)

      # The fixture holds one GITHUB_PUSH_UNBUILDABLE tombstone (D19). It is not
      # an attempt, so it is in neither `volume` nor any cohort — and the
      # identity above must hold WITHOUT it, not by absorbing it into residual.
      assert Enum.map(census.not_attempted, & &1.class) == ["GITHUB_PUSH_UNBUILDABLE"]
      assert Enum.map(census.not_attempted, & &1.count) == [1]
      refute Enum.any?(census.classes, &(&1.class == "GITHUB_PUSH_UNBUILDABLE"))
      assert census.volume == 21
    end

    test "the rates are REFUSED at this sample size — this file guards counts, not rates", ctx do
      census = every_status_census(ctx)

      # Recorded as behaviour so nobody folds a rate assertion into this fixture
      # and gets a vacuous green out of the refusal.
      assert census.volume < DeployLedger.min_sample()
      assert census.failure_rate.refused
      assert census.failure_rate.pct == nil
      assert census.live_rate.refused
      assert census.live_rate.pct == nil
    end
  end

  ## ── The fixture: ONE ROW OF EVERY STATUS THE CENSUS CAN NAME ──────────────

  # 5 failed · 3 deferred (one per deferred class) · 7 live · 3 in flight
  # (queued/building/pushing) · 1 cancelled · 2 in a status nobody taught the
  # census · 1 never-attempted tombstone outside volume.
  defp every_status_census(%{team: team, site: site}) do
    for i <- 1..5 do
      deployment!(site, %{
        status: "failed",
        stage: "PLAN",
        failure_reason: @r409_bare,
        inserted_at: at(i)
      })
    end

    for {reason, i} <- Enum.with_index([@d_busy_bare, @d_capacity, @d_novel]) do
      deployment!(site, %{
        status: "deferred",
        stage: "PLAN",
        failure_reason: reason,
        inserted_at: at(100 + i)
      })
    end

    for i <- 1..7 do
      deployment!(site, %{
        status: "live",
        stage: "SWITCH",
        failure_reason: nil,
        inserted_at: at(200 + i)
      })
    end

    # Each in-flight row gets its OWN site: the partial unique index
    # `deployments_active_site_env_index` permits exactly one active production
    # row per (site, environment), so stacking them would raise
    # Ecto.ConstraintError and this fixture would never build.
    for {status, i} <- Enum.with_index(~w(queued building pushing)) do
      deployment!(site_fixture(team), %{
        status: status,
        stage: "PLAN",
        failure_reason: nil,
        inserted_at: at(300 + i)
      })
    end

    deployment!(site, %{
      status: "cancelled",
      stage: "PLAN",
      failure_reason: nil,
      inserted_at: at(400)
    })

    # A status no arm of this census has ever been taught: the residue, which
    # must RISE rather than be absorbed by a neighbour.
    for i <- 1..2 do
      deployment!(site, %{
        status: "quarantined",
        stage: "SWITCH",
        failure_reason: nil,
        inserted_at: at(500 + i)
      })
    end

    deployment!(site, %{
      status: "failed",
      stage: nil,
      failure_reason: @gh_push,
      inserted_at: at(600)
    })

    DeployLedger.census(@from, @to)
  end

  defp deferred_total(census), do: census.deferred |> Enum.map(& &1.count) |> Enum.sum()

  defp at(seconds), do: DateTime.add(@from, seconds, :second)

  ## ── Fixtures ─────────────────────────────────────────────────────────────

  defp user_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp site_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Deployments are inserted as STRUCTS on purpose: `Deployment.changeset/2`
  # forbids casting `status` (transition_changeset is the sole status mutator)
  # and the census needs rows pinned to an exact `inserted_at`.
  defp deployment!(site, attrs) do
    now = attrs |> Map.get(:inserted_at, DateTime.utc_now()) |> usec()

    Repo.insert!(
      struct(
        %Deployment{
          site_id: site.id,
          status: "failed",
          environment: "production",
          inserted_at: now,
          updated_at: now
        },
        attrs
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      )
    )
  end

  defp usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}
end
