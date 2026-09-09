defmodule BarkparkCloud.Notifications.SitePublishWaitingAlertTest do
  @moduledoc """
  dr-w11-s5-waiting-alert — THE ALERT POINTS AT THE WAIT.

  Every reading here is REAL: real `deployments` rows for a real team's site,
  read by the real `DeployLedger.delivery/3` through the real
  `SitePublishWaitingAlert.read/2`, graded by the real verdict, sent by the real
  `Mailer`, and recorded as real `Delivery` rows. No fixture map is handed to a
  renderer, so a duration asserted below is a duration the ledger computed off
  the rows.

  ## What this file pins

    1. **THREE consecutive sweeps over one still-waiting site send exactly ONE
       email.** This is the mutation target: delete the `waiting_alerted_at`
       arm in `Notifications.deliver_site_publish_waiting_notices/1` and this
       test reds with three notices where one was asserted.
    2. **RECOVERY IS SENT, AND IT NAMES THE DURATION.** When the wait clears, a
       second message goes out carrying the longest wait the ledger measured
       during the episode. An instrument that can only accuse is an alarm.
    3. **THE LATCH IS NOT A MUTE.** A wait that clears and returns is alerted
       again. A guard that could fire once in the life of a team is worse than
       no guard.
    4. **THE THRESHOLD IS REAL, NOT THE FIXTURE'S SHAPE.** A site waiting 30
       minutes — under the one-hour threshold — is never alerted, however many
       sweeps run. This is the control: without it every assertion above would
       pass on a rail that fires on ANY wait.
    5. **THE COPY NAMES ITS CLOCK.** The control-plane pickup, not the human's
       publish, pinned as a literal string.
    6. **`:unmeasured` IS NOT `:clear`.** A truncated or unreadable cohort is
       refused, never reported as a clean bill — a reading nobody could take is
       not good news, and collapsing it into `clear` would send a RECOVERY
       message for a wait that may still be standing.
  """
  use BarkparkCloud.DataCase, async: true

  import Swoosh.TestAssertions

  alias BarkparkCloud.{Accounts, Notifications, Registry, Repo}
  alias BarkparkCloud.Notifications.{DeployRateAlertState, Delivery, SitePublishWaitingAlert}
  alias BarkparkCloud.Registry.Deployment

  # Well clear of the deferred-status vocabulary boundary, for the reason the
  # rate alert's suite records: a reading that straddles it is refused, and that
  # refusal is a different test's subject.
  @now ~U[2026-09-06 12:00:00Z]

  # TWO HOURS — comfortably over the one-hour threshold and comfortably inside
  # the 24h door, so no sweep in this file (up to +6h) can turn a guard
  # assertion into a window artefact.
  @waited_seconds 7200

  describe "the edge guard" do
    test "THREE consecutive sweeps over one still-waiting site send exactly ONE notice" do
      {user, team} = team_with_waiting_site(@waited_seconds)

      # The precondition, asserted rather than assumed: the ledger really does
      # report this site as still waiting past the threshold. Without this the
      # three assertions below would also pass on a fleet that is simply silent.
      envelope = SitePublishWaitingAlert.read(@now, site_ids(team))
      assert SitePublishWaitingAlert.verdict(envelope) == :waiting
      assert SitePublishWaitingAlert.longest_wait_seconds(envelope) >= 3600

      sweep(@now)
      sweep(hours(1))
      sweep(hours(2))

      assert [receipt] = notices()
      assert receipt.team_id == team.id
      assert receipt.recipient == user.email
      assert receipt.status == "sent"
      assert receipt.event == "site_publish_waiting"
      assert receipt.kind == "alert"

      # THE LATCH IS WHAT DID IT, and it is still standing.
      state = Repo.get_by!(DeployRateAlertState, team_id: team.id)
      assert state.waiting_verdict == "waiting"
      refute is_nil(state.waiting_alerted_at)
    end

    test "the sweep's own accounting says LATCHED on the second and third pass" do
      {_user, _team} = team_with_waiting_site(@waited_seconds)

      assert %{waiting: 1, sent: 1, latched: 0} = sweep(@now)
      assert %{waiting: 1, sent: 0, latched: 1} = sweep(hours(1))
      assert %{waiting: 1, sent: 0, latched: 1} = sweep(hours(2))
    end
  end

  describe "the threshold" do
    test "CONTROL: a site waiting UNDER the threshold is never alerted" do
      {_user, team} = team_with_waiting_site(1800)

      envelope = SitePublishWaitingAlert.read(@now, site_ids(team))

      # The site IS waiting — the ledger says so — it is simply not waiting
      # long enough. That distinction is the whole content of the threshold, and
      # without this control the suite could not tell a working threshold from
      # a rail that fires on any censored row at all.
      assert [node] = envelope.sites
      assert node.still_waiting
      assert node.oldest_waiting_seconds < SitePublishWaitingAlert.threshold_seconds()
      assert SitePublishWaitingAlert.verdict(envelope) == :clear

      for h <- 0..3, do: sweep(hours(h))

      assert notices() == []
    end

    test "the threshold is 3600s and it is quoted against the measured p95" do
      assert SitePublishWaitingAlert.threshold_seconds() == 3600
      assert SitePublishWaitingAlert.window_seconds() == 86_400

      {_user, _team} = team_with_waiting_site(@waited_seconds)
      sweep(@now)

      assert_email_sent(fn email ->
        # The number NEVER travels without the measurement it was derived from.
        assert email.text_body =~ "948.782s (cloud-db-1, 2026-08-09, this clock)"
        assert email.text_body =~ "3.79x above it"
      end)
    end
  end

  describe "recovery" do
    test "when the wait clears a message goes out NAMING how long it lasted" do
      {_user, team} = team_with_waiting_site(@waited_seconds)

      sweep(@now)
      assert [_alert] = notices()

      # THE WAIT CLEARS — a live row whose bytes answered on the web, which is
      # the only thing that resolves a censored observation.
      settle(team, hours(1))

      envelope = SitePublishWaitingAlert.read(hours(1), site_ids(team))
      assert SitePublishWaitingAlert.verdict(envelope) == :clear

      assert %{recovered: 1} = sweep(hours(1))

      assert [recovery] = recoveries()
      assert recovery.status == "sent"
      assert recovery.event == "site_publish_waiting_recovered"

      assert_email_sent(fn email ->
        # THE DURATION, and it is the one the ledger measured — 7200s of wait,
        # rendered as hours and minutes.
        assert email.text_body =~ "Longest wait measured during the episode: 2h 0m."
        # AND the episode's own wall time, which is a different number: one hour
        # from the notice going out to the sweep that saw it clear.
        assert email.text_body =~ "The alert stood for: 1h 0m."
        assert email.subject =~ "has CLEARED"
      end)

      # THE LATCH IS RE-ARMED.
      state = Repo.get_by!(DeployRateAlertState, team_id: team.id)
      assert state.waiting_verdict == "clear"
      assert is_nil(state.waiting_alerted_at)
    end

    test "the latch is not a mute: a wait that returns is alerted again" do
      {_user, team} = team_with_waiting_site(@waited_seconds)

      sweep(@now)
      settle(team, hours(1))
      sweep(hours(1))

      # A SECOND episode: a new attempt, two hours old at the +4h sweep, with
      # nothing live after it.
      stall(team, DateTime.add(hours(4), -@waited_seconds, :second))

      assert %{sent: 1} = sweep(hours(4))
      assert length(notices()) == 2
    end

    test "an UNMEASURED reading is not CLEAR — a truncated cohort is refused" do
      {_user, team} = team_with_waiting_site(@waited_seconds)

      sweep(@now)
      before = Repo.get_by!(DeployRateAlertState, team_id: team.id)
      refute is_nil(before.waiting_alerted_at)

      # A truncated envelope is the shape `delivery/3` returns when its site cap
      # cut the list — the waiting site could be the one that was cut, so the
      # reading is REFUSED rather than reported as a clean bill. If this
      # collapsed into `:clear` the sweep would send a recovery message for a
      # wait that is very possibly still standing.
      assert SitePublishWaitingAlert.verdict(%{sites: [], truncated: true}) == :unmeasured
      assert SitePublishWaitingAlert.waiting_sites(%{sites: [], truncated: true}) == []

      # An envelope with no `sites` node at all — the shape the sweep substitutes
      # when a team's site list could not be read — is the same refusal.
      assert SitePublishWaitingAlert.verdict(%{}) == :unmeasured

      assert recoveries() == []
    end
  end

  describe "the copy" do
    test "it names the CONTROL-PLANE PICKUP as its clock, not the human's publish" do
      {_user, _team} = team_with_waiting_site(@waited_seconds)
      sweep(@now)

      assert_email_sent(fn email ->
        # THE PINNED STRING (criterion 6). It says which instant the duration is
        # measured from, and it says what it is NOT measured from, because the
        # publish-keyed clock is dr-w11-s1's and is not live yet.
        assert email.text_body =~
                 "Measured from when the control plane PICKED THE PUBLISH UP — " <>
                   "the deployment row's own inserted_at — not from when you pressed publish."

        assert email.text_body =~ SitePublishWaitingAlert.clock_sentence()

        # And the ledger's OWN name for its clock rides underneath, so the copy
        # cannot drift from the estimator it quotes.
        assert email.text_body =~ "Clock: deployment row: inserted_at → became_live_at"

        assert email.subject =~ "content still WAITING to reach the web — 2h 0m (1 site)"
      end)
    end
  end

  describe "the mute path" do
    test "a team that turned deployment_failed off is not told about its waits" do
      {_user, team} = team_with_waiting_site(@waited_seconds)

      {:ok, _} = Notifications.update_settings(team.id, %{"deployment_failed" => false})

      for h <- 0..3, do: sweep(hours(h))

      assert notices() == []
    end
  end

  ## ── Helpers ──────────────────────────────────────────────────────────────

  defp sweep(now), do: Notifications.deliver_site_publish_waiting_notices(now: now)

  defp hours(n), do: DateTime.add(@now, n * 3600, :second)

  defp notices, do: deliveries("site_publish_waiting")
  defp recoveries, do: deliveries("site_publish_waiting_recovered")

  defp deliveries(event) do
    Delivery |> Repo.all() |> Enum.filter(&(&1.event == event))
  end

  defp site_ids(team), do: team |> Registry.list_sites_for_team() |> Enum.map(& &1.id)

  # A team with one site whose newest attempt has been waiting `seconds` and has
  # NO live mark at or after it — the censored cohort `delivery/3` publishes.
  defp team_with_waiting_site(seconds) do
    {user, team} = user_team()
    {:ok, bp} = Registry.register_barkpark(team, %{name: "Fleet", slug: uniq("prod")})
    {:ok, _site} = Registry.create_site(bp, %{name: "S", slug: uniq("s")})

    stall(team, DateTime.add(@now, -seconds, :second))

    {user, team}
  end

  # ONE ATTEMPT that did not reach the web. `failed` and not `cancelled`:
  # `delivery/3` splits cancelled rows into their own bucket and never counts
  # them as waits (`dr-w11-bl-cancelled-rows-count-as-waiting`), so a fixture
  # built on `cancelled` would assert nothing.
  defp stall(team, at) do
    site = team |> Registry.list_sites_for_team() |> hd()

    Repo.insert_all(Deployment, [
      row(site, "failed", at, failure_reason: "instance guerrilla is unreachable")
    ])
  end

  # THE ONLY THING THAT RESOLVES A CENSORED ROW: a live row whose bytes answered
  # on the web at a nameable instant.
  defp settle(team, at) do
    site = team |> Registry.list_sites_for_team() |> hd()

    Repo.insert_all(Deployment, [row(site, "live", at, became_live_at: at)])
  end

  defp row(site, status, at, extra) do
    # `insert_all` dumps straight to `:utc_datetime_usec`, which REFUSES a
    # second-precision struct — carry the precision, do not truncate to it.
    at = %{at | microsecond: {elem(at.microsecond, 0), 6}}

    live =
      case Keyword.get(extra, :became_live_at) do
        %DateTime{} = dt -> %{dt | microsecond: {elem(dt.microsecond, 0), 6}}
        nil -> nil
      end

    %{
      id: Ecto.UUID.generate(),
      site_id: site.id,
      status: status,
      environment: "production",
      trigger: "content-auto",
      source: "box-build",
      stage: nil,
      failure_reason: Keyword.get(extra, :failure_reason),
      became_live_at: live,
      inserted_at: at,
      updated_at: at
    }
  end

  defp user_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "waiting-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, team} = Accounts.create_team(%{name: "Wait #{n}", slug: "wait-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
