defmodule BarkparkCloud.Workers.DeployRateAlertWorkerTest do
  @moduledoc """
  dr-bl-rate-notice — THE RATE, AND THE EDGE GUARD THAT KEEPS IT ONE EMAIL.

  Every reading here is REAL: real `deployments` rows for a real team's site,
  read by the real `DeployLedger.census/3` through the real
  `DigestEmail.deploy_health/1`, graded by the real verdict, sent by the real
  `Mailer`. No fixture map is handed to a renderer, so a number asserted below
  is a number the platform computed.

  ## The four things this file pins

    1. **THREE consecutive red readings send exactly ONE notice.** The rate is
       taken over a ROLLING 24h door, so a fleet that is red at 12:00 is red at
       13:00 and at 14:00 over largely the same rows. An alert keyed on a single
       tick would mail hourly for as long as the incident's rows stay inside the
       door — a per-deployment producer with a percentage on it, which charter
       D14 forbids.
    2. **THE LATCH HOLDS.** A fourth, fifth and sixth red reading send nothing.
       This is the mutation target: delete the `alerted_at` arm in
       `Notifications.deliver_deploy_rate_notices/1` and this test reds.
    3. **THE LATCH IS NOT A MUTE.** A reading that leaves red clears it, so the
       NEXT episode is alerted. A guard that could only fire once in the life of
       a team would be worse than no guard.
    4. **IT REFUSES BELOW n = `DeployLedger.min_sample/0`.** A 60%-failing team
       with 150 settled rows is never alerted, however many ticks run. The
       refusal is inherited from the census's own rate node, not re-implemented
       — the reading is recorded `unmeasured`, never `clear`.
  """
  use BarkparkCloud.DataCase, async: true

  import Swoosh.TestAssertions

  alias BarkparkCloud.{Accounts, Notifications, Registry, Repo}
  alias BarkparkCloud.Notifications.{DeployRateAlert, DeployRateAlertState, Delivery}
  alias BarkparkCloud.Registry.Deployment

  # Well clear of the deferred-status vocabulary boundary (2026-08-05T21:13:50Z),
  # so no reading here is refused for straddling it — that refusal is real and is
  # a different test's subject.
  @now ~U[2026-09-06 12:00:00Z]

  # A RED fleet: 80 failed + 220 live = 300 settled, above `min_sample` 200, and
  # 26.67% on the settled basis — above `DeployRateAlert.alert_pct/0` (25.0).
  #
  # The LIVE count alone (220) is deliberately above `min_sample` too: the
  # re-arm test deletes the failures, and a recovered fleet whose remaining
  # sample fell below the floor would read `unmeasured` rather than `clear` —
  # which would prove nothing about the latch, only about the floor.
  @red_failed 80
  @red_live 220

  describe "the edge guard" do
    test "THREE consecutive red readings send exactly ONE notice" do
      {user, team} = team_with_red_fleet()

      tick(@now)
      tick(hours(1))
      tick(hours(2))

      assert [receipt] = notices()
      assert receipt.team_id == team.id
      assert receipt.recipient == user.email
      assert receipt.status == "sent"
      assert receipt.event == "deploy_failure_rate"
      assert receipt.kind == "alert"

      # And it took all three: nothing was sent on the first two readings.
      state = Repo.get_by!(DeployRateAlertState, team_id: team.id)
      assert state.consecutive_red == 3
      assert state.verdict == "red"
      refute is_nil(state.alerted_at)
    end

    test "the first two readings send NOTHING — the notice needs a run, not a tick" do
      {_user, team} = team_with_red_fleet()

      tick(@now)
      assert notices() == []
      assert Repo.get_by!(DeployRateAlertState, team_id: team.id).consecutive_red == 1

      tick(hours(1))
      assert notices() == []
      assert Repo.get_by!(DeployRateAlertState, team_id: team.id).consecutive_red == 2
    end

    test "MUTATION TARGET — a fourth, fifth and sixth red reading send nothing (the latch)" do
      {_user, _team} = team_with_red_fleet()

      for h <- 0..5, do: tick(hours(h))

      assert length(notices()) == 1,
             "six consecutive red readings must produce ONE notice, not one per reading"
    end

    test "the latch is not a mute: a clear reading re-arms the next episode" do
      {_user, team} = team_with_red_fleet()

      for h <- 0..2, do: tick(hours(h))
      assert length(notices()) == 1

      # The fleet recovers: drop the failures, keep the live rows.
      {@red_failed, _} = Repo.delete_all(from(d in Deployment, where: d.status == "failed"))
      tick(hours(3))

      state = Repo.get_by!(DeployRateAlertState, team_id: team.id)
      assert state.verdict == "clear"
      assert state.consecutive_red == 0
      assert is_nil(state.alerted_at), "a non-red reading must clear the latch"

      # And it fails again.
      site = one_site(team)
      at = DateTime.add(hours(3), -12 * 3600, :second)

      Repo.insert_all(
        Deployment,
        bulk(site, "failed", @red_failed, at, "instance is unreachable")
      )

      for h <- 4..6, do: tick(hours(h))

      assert length(notices()) == 2
    end
  end

  describe "the refusal floor" do
    test "a 60%-failing team below min_sample is NEVER alerted, and reads unmeasured" do
      {_user, team} = team_with_fleet(90, 60)

      for h <- 0..9, do: tick(hours(h))

      assert notices() == []

      state = Repo.get_by!(DeployRateAlertState, team_id: team.id)

      assert state.verdict == "unmeasured",
             "a sample below min_sample is UNMEASURED and must never read as clear"

      assert state.consecutive_red == 0
    end

    test "the floor is the census's own, not a constant in the alert" do
      {_user, team} = team_with_fleet(90, 60)

      health =
        BarkparkCloud.Notifications.DigestEmail.deploy_health(
          now: @now,
          site_ids: team |> Registry.list_sites_for_team() |> Enum.map(& &1.id)
        )

      node = DeployRateAlert.rate_node(health)

      assert node.refused
      assert node.pct == nil
      assert node.sample == 150
      assert node.min_sample == BarkparkCloud.DeployLedger.min_sample()
      assert DeployRateAlert.verdict(health) == :unmeasured
    end
  end

  describe "what the notice says" do
    test "the rate never travels without its volume, on BOTH bases" do
      {_user, _team} = team_with_red_fleet()

      for h <- 0..2, do: tick(hours(h))

      assert_email_sent(fn email ->
        # THE SUBJECT carries the percentage AND the denominator, because a
        # subject line is the part most likely to be read alone.
        assert email.subject =~ "26.67% of settled deploys (80 of 300)"
        assert email.subject =~ "last 24h"

        # BOTH BASES, both denominators (D525). The attempted door here carries
        # no deferrals, so the two percentages coincide — what is asserted is
        # that neither is printed without its own count.
        assert email.text_body =~ "Settled basis: 26.67% failed (80 of 300 settled)."
        assert email.text_body =~ "Attempted basis: 26.67% failed (80 of 300 attempted)."

        # The window it was taken over, pinned.
        assert email.text_body =~ "2026-09-05 14:00 UTC to 2026-09-06 14:00 UTC"

        # And what it is NOT.
        assert email.text_body =~ "THIS IS NOT ONE EMAIL PER FAILED DEPLOYMENT"
        assert email.text_body =~ "3 consecutive hourly readings"
      end)
    end

    test "MUTATION: with the failed rows gone, the same rail sends nothing at all" do
      {_user, _team} = team_with_red_fleet()

      {@red_failed, _} = Repo.delete_all(from(d in Deployment, where: d.status == "failed"))

      for h <- 0..5, do: tick(hours(h))

      assert notices() == [],
             "the verdict must be derived from the rows, not from the fixture's shape"
    end
  end

  describe "the mute path" do
    test "a team that turned deployment_failed off is not sent a summary of it" do
      {_user, team} = team_with_red_fleet()

      {:ok, _} = Notifications.update_settings(team.id, %{"deployment_failed" => false})

      for h <- 0..5, do: tick(hours(h))

      assert notices() == []
    end
  end

  ## ── Helpers ──────────────────────────────────────────────────────────────

  defp tick(now), do: Notifications.deliver_deploy_rate_notices(now: now)

  defp hours(n), do: DateTime.add(@now, n * 3600, :second)

  defp notices do
    Delivery
    |> Repo.all()
    |> Enum.filter(&(&1.event == "deploy_failure_rate"))
  end

  defp team_with_red_fleet, do: team_with_fleet(@red_failed, @red_live)

  defp team_with_fleet(failed, live) do
    {user, team} = user_team()
    {:ok, bp} = Registry.register_barkpark(team, %{name: "Fleet", slug: uniq("prod")})
    {:ok, site} = Registry.create_site(bp, %{name: "S", slug: uniq("s")})

    # Rows land twelve hours inside the 24h door that closes at `@now`, so every
    # tick in these tests (up to +6h) still sees the whole population: the door
    # is rolling and a row placed at its edge would fall out mid-test and turn a
    # guard assertion into a window artefact.
    at = DateTime.add(@now, -12 * 3600, :second)

    Repo.insert_all(
      Deployment,
      bulk(site, "failed", failed, at, "instance guerrilla is unreachable") ++
        bulk(site, "live", live, at)
    )

    {user, team}
  end

  defp one_site(team), do: team |> Registry.list_sites_for_team() |> hd()

  defp bulk(site, status, count, at, reason \\ nil)
  defp bulk(_site, _status, 0, _at, _reason), do: []

  defp bulk(site, status, count, at, reason) do
    # `insert_all` dumps straight to `:utc_datetime_usec`, which REFUSES a
    # second-precision struct — carry the precision, do not truncate to it.
    at = %{at | microsecond: {elem(at.microsecond, 0), 6}}

    for _ <- 1..count do
      %{
        id: Ecto.UUID.generate(),
        site_id: site.id,
        status: status,
        environment: "production",
        trigger: "content-auto",
        source: "box-build",
        stage: nil,
        failure_reason: reason,
        inserted_at: at,
        updated_at: at
      }
    end
  end

  defp user_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "rate-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, team} = Accounts.create_team(%{name: "Rate #{n}", slug: "rate-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
