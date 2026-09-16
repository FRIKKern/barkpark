defmodule BarkparkCloud.Notifications.DeploymentFailedLatchTest do
  @moduledoc """
  task-2db350610ca0a168 — `deployment_failed` is ONE notice per site per dark
  episode, not one per attempt.

  THE FAULT THIS MEASURES. `dr-w11-bl-deployment-failed-alarm-fatigue` narrowed
  the alert to failures that destroyed content, and that narrowing is sound, but
  its predicate reads `not content_on_web?(site)` — a fact about the SITE. While
  a site has nothing on the web it says the same thing to every attempt, so the
  135th failure of one dark site passed the same gate the 1st did. The flood was
  moved off serving sites and left whole on never-launched ones.

  THE SHAPE OF EVERY TEST HERE, and it is the point of the file: each row is
  asserted `"failed"` FIRST and the site asserted DARK, so a silent mailbox is
  proven to be a LATCH and not a fixture that never failed or a narrowing that
  swallowed it. Every suppression is paired with a send — the first failure of
  the episode, or a second site's own first — because a latch that silenced
  everything would pass half this file and fail the other half.

  THE VOLUME SHAPE IS MEASURED ON REAL ROWS AND COUNTED IN OBAN JOBS. The
  reaper test sweeps TWO dark sites that differ in exactly one respect — one has
  already had its episode notice, the other has not — and asserts the sweep
  enqueues ONE job, for the second site. An implementation that dropped the
  batch reads 0, the pre-latch implementation reads 2, and only the ruling reads
  1 with that site's id on it. That is the volume claim stated as a number a
  test can fail on, which is what this row asked for.

  WHY THE REAPER TEST IS NOT "N ROWS OF ONE SITE". It cannot be:
  `deployments_active_site_env_index` permits ONE active row per site and
  environment, so a site cannot hold five queued attempts for one sweep to
  terminate. Measured, not assumed — the first draft of this test tried it and
  the constraint refused the second insert. The repeat-attempt flood is
  therefore SEQUENTIAL, which is what the fenced-writer test above drives, and
  the reaper's own exposure is a reaped row on a site that already has a failed
  one. Both are covered, by the test that can actually produce each shape.

  `async: false`: these assert on the shared `Swoosh.Adapters.Test` mailbox.
  """
  use BarkparkCloud.DataCase, async: false
  use Oban.Testing, repo: BarkparkCloud.Repo
  import Swoosh.TestAssertions

  alias BarkparkCloud.{Accounts, DeployLedger, Registry}
  alias BarkparkCloud.Notifications.DeploymentFailedPolicy
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Workers.{DeploymentAlertWorker, StaleDeploymentReaper}

  @subject "Deployment failed"

  ## Fixtures — the narrowing test's, because the two files must drive the same
  ## producers through the same doors or they are measuring different systems.

  defp team_with_owner do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "owner-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _} = Accounts.add_member(team, user, "owner")
    {team, user}
  end

  defp setup_site(site_attrs \\ %{}) do
    {team, owner} = team_with_owner()
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    {:ok, site} =
      Registry.create_site(bp, Map.merge(%{name: "Shop #{n}", slug: "shop-#{n}"}, site_attrs))

    {site, owner}
  end

  defp flush_emails(n \\ 0) do
    receive do
      {:email, _} -> flush_emails(n + 1)
    after
      50 -> n
    end
  end

  # One queued row, claimed, failed through the fenced writer. Returns the id.
  defp fail_through_fenced_writer(site) do
    worker = "builder-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, claimed} = Registry.claim_next_deployment(worker)

    {:ok, _} =
      Registry.transition_deployment_fenced(claimed.id, worker, claimed.claim_epoch, %{
        status: "failed",
        failure_reason: "unauthorized: invalid token"
      })

    claimed.id
  end

  ## 1. THE FENCED WRITER — the arm that proves a real loss STILL SENDS, and the
  ##    arm that proves the repeat does not. Same site, same fixture, same
  ##    failure: the ONLY difference is that one is the episode's notice.

  test "the FIRST failure on a dark site mails, and the second through fifth do not" do
    {site, owner} = setup_site()
    refute DeployLedger.content_on_web?(site.id)

    first = fail_through_fenced_writer(site)

    # The real-loss arm: this site has nothing on the web and the team hears so.
    assert Repo.get(Deployment, first).status == "failed"

    assert_email_sent(fn email ->
      assert email.subject == @subject
      assert {_, to} = hd(email.to)
      assert to == owner.email
    end)

    assert flush_emails() == 0

    # Four more REAL failures, through the same writer, on the same dark site.
    repeats = for _ <- 1..4, do: fail_through_fenced_writer(site)

    # FIRST: every one of them really failed — the silence below is not a
    # fixture that quietly stopped producing failed rows.
    for id <- repeats, do: assert(Repo.get(Deployment, id).status == "failed")
    # ...and the site really is still dark, so the NARROWING did not do this.
    refute DeployLedger.content_on_web?(site.id)
    assert DeployLedger.first_production_failure_id(site.id) == first

    # THEN: four failures, zero interruptions.
    assert_no_email_sent()
  end

  test "CONTROL — a SECOND dark site gets its own first notice, so the latch is per SITE" do
    {quiet_site, _} = setup_site()
    first = fail_through_fenced_writer(quiet_site)
    assert Repo.get(Deployment, first).status == "failed"
    assert flush_emails() == 1

    # The repeat on site one is latched...
    repeat = fail_through_fenced_writer(quiet_site)
    assert Repo.get(Deployment, repeat).status == "failed"
    assert_no_email_sent()

    # ...while a different dark site is a different episode and still mails.
    {other, other_owner} = setup_site()
    refute DeployLedger.content_on_web?(other.id)
    other_id = fail_through_fenced_writer(other)
    assert Repo.get(Deployment, other_id).status == "failed"

    assert_email_sent(fn email ->
      assert email.subject == @subject
      assert {_, to} = hd(email.to)
      assert to == other_owner.email
    end)
  end

  ## 2. THE BORN-FAILED SEAM — a second producer. A latch wired at only one of
  ##    the three producers keeps the flood at the other two.

  test "a born-failed push is latched by an EARLIER failure on the same dark site" do
    {site, owner} = setup_site(%{github_repo: "octo/shop"})
    refute DeployLedger.content_on_web?(site.id)

    # The episode's notice, filed by the OTHER producer.
    first = fail_through_fenced_writer(site)
    assert Repo.get(Deployment, first).status == "failed"

    assert_email_sent(fn email ->
      assert {_, to} = hd(email.to)
      assert to == owner.email
    end)

    assert flush_emails() == 0

    assert {:ok, born} =
             Registry.create_failed_deployment(
               site,
               %{git_ref: "main", delivery_id: "delivery-#{System.unique_integer([:positive])}"},
               "github push builds are not available yet"
             )

    assert Repo.get(Deployment, born.id).status == "failed"
    refute DeployLedger.content_on_web?(site.id)
    assert_no_email_sent()
  end

  ## 3. THE REAPER — THE VOLUME SHAPE, COUNTED IN OBAN JOBS. Two dark sites,
  ##    one sweep, differing only in whether their episode already has a notice.

  test "one sweep reaps two dark sites and enqueues an alert only for the un-noticed one" do
    # LATCHED: this site's episode notice was already sent, by another producer.
    {noticed, _} = setup_site()
    first = fail_through_fenced_writer(noticed)
    assert Repo.get(Deployment, first).status == "failed"
    assert flush_emails() == 1
    {:ok, reaped_late} = Registry.create_deployment(noticed, %{git_ref: "main"})

    # LOUD: this site has no failed row at all, so the reaped one IS its notice.
    {fresh, _} = setup_site()
    {:ok, reaped_first} = Registry.create_deployment(fresh, %{git_ref: "main"})

    # Both rows are no-build-source rows, so ONE sweep terminates both.
    assert {:ok, %{no_source_failed: 2}} = perform_job(StaleDeploymentReaper, %{})

    # FIRST: the fixture really produced the defect on BOTH sites.
    assert Repo.get(Deployment, reaped_late.id).status == "failed"
    assert Repo.get(Deployment, reaped_first.id).status == "failed"
    # ...and both sites are still dark, so the NARROWING suppressed neither.
    refute DeployLedger.content_on_web?(noticed.id)
    refute DeployLedger.content_on_web?(fresh.id)

    # THEN: one job for the two failures — and it is the fresh site's.
    jobs = all_enqueued(worker: DeploymentAlertWorker)
    assert length(jobs) == 1
    assert [%{args: %{"site_id" => alerted_site, "payload" => payload}}] = jobs
    assert alerted_site == fresh.id
    refute alerted_site == noticed.id

    # ...carrying the row the ledger names as that episode's notice.
    assert payload["deployment_id"] == reaped_first.id
    assert DeployLedger.first_production_failure_id(fresh.id) == reaped_first.id
    # ...while the latched site's notice is still the EARLIER row, not the reap.
    assert DeployLedger.first_production_failure_id(noticed.id) == first
  end

  ## 4. UNKEYABLE IS NOT QUIET — the direction the doubt falls (charter D3). A
  ##    suppression must be earned by a reading, never granted by a missing
  ##    field, and this latch has two fields it can be missing.

  test "an attempt the latch cannot key stays LOUD" do
    assert DeploymentFailedPolicy.first_notice_of_episode?(%{site_id: nil, id: nil})
    assert DeploymentFailedPolicy.first_notice_of_episode?(%{id: "some-id"})
    assert DeploymentFailedPolicy.first_notice_of_episode?(%{site_id: Ecto.UUID.generate()})
    assert DeploymentFailedPolicy.first_notice_of_episode?(:not_a_map)
    assert DeployLedger.first_production_failure_id("not-a-uuid") == nil

    # A site with no failed row at all cannot have sent an earlier notice.
    {site, _} = setup_site()
    assert DeployLedger.first_production_failure_id(site.id) == nil

    assert DeploymentFailedPolicy.first_notice_of_episode?(%{
             site_id: site.id,
             id: Ecto.UUID.generate()
           })
  end
end
