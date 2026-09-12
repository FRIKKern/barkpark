defmodule BarkparkCloud.Notifications.DeploymentFailedNarrowingTest do
  @moduledoc """
  dr-w11-bl-deployment-failed-alarm-fatigue — the `deployment_failed` alert says
  only the failures that DESTROYED CONTENT.

  RULED by team-lead 2026-09-02 on the row: 2,291 emails SENT on a rising curve
  (340 → 446 → 625 → 870 a day) about attempts the same ledger says stranded
  NOTHING. The alert was never wrong about any one row; it was pointed at the
  wrong quantity. `Notifications.DeploymentFailedPolicy` is the narrowing, and
  every test here drives a REAL write to `failed` through one of the THREE
  producers — the fenced writer, the born-failed webhook insert, and the
  reaper's bulk `update_all` passes — because a producer the narrowing missed
  keeps sending, and a test that hand-calls the predicate could not see that.

  THE SHAPE OF EVERY TEST: the row is asserted `"failed"` FIRST, so a silent
  mailbox is proven to be a SUPPRESSION and not a fixture that never failed.
  Each suppression is paired with the same fixture MINUS the live deployment,
  which must still mail — a narrowing that silenced everything would pass half
  of this file and fail the other half.

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

  ## Fixtures

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

  # Swoosh's test adapter delivers into THIS process's mailbox, so a fixture that
  # drives a real `live` transition leaves a `deployment_succeeded` email behind.
  # Every `assert_no_email_sent` below would then be measuring the FIXTURE's
  # mail, not the alert's absence — so the mailbox is emptied between arranging
  # and acting, and the count it drained is returned so a test can say so.
  defp flush_emails(n \\ 0) do
    receive do
      {:email, _} -> flush_emails(n + 1)
    after
      50 -> n
    end
  end

  # Put content ON THE WEB the honest way: a real queued row, claimed, walked
  # queued → building → pushing → live through the fenced writer. `became_live_at`
  # is passed unless `mark: false` — a `live` row with a NULL mark is real (55 on
  # jarl-website alone) and `content_on_web?/1` must count it.
  defp serve_content!(site, opts \\ []) do
    worker = "builder-live-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.create_deployment(site, %{git_ref: "live-ref"})
    {:ok, claimed} = Registry.claim_next_deployment(worker)

    for status <- ~w(building pushing) do
      {:ok, _} = transition(claimed, worker, %{status: status})
    end

    live_attrs =
      if Keyword.get(opts, :mark, true) do
        %{status: "live", became_live_at: DateTime.utc_now() |> DateTime.truncate(:second)}
      else
        %{status: "live"}
      end

    {:ok, live} = transition(claimed, worker, live_attrs)
    assert live.status == "live"
    flush_emails()
    live
  end

  defp transition(claimed, worker, attrs) do
    Registry.transition_deployment_fenced(claimed.id, worker, claimed.claim_epoch, attrs)
  end

  # One queued row, claimed, failed through the fenced writer. Returns the id.
  defp fail_through_fenced_writer(site) do
    worker = "builder-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, claimed} = Registry.claim_next_deployment(worker)

    {:ok, _} =
      transition(claimed, worker, %{
        status: "failed",
        failure_reason: "unauthorized: invalid token"
      })

    claimed.id
  end

  ## 1. THE FENCED WRITER — the builder route, the agent route and
  ##    `Sites.Deploy.fail/2` all funnel through it.

  test "a failure on a site that is SERVING content mails nobody" do
    {site, _owner} = setup_site()
    serve_content!(site)

    id = fail_through_fenced_writer(site)

    # FIRST: the fixture really produced the defect — this IS a failed deploy.
    assert Repo.get(Deployment, id).status == "failed"
    # ...and the site really is up, so the reader lost nothing.
    assert DeployLedger.content_on_web?(site.id)
    # THEN: nobody is interrupted about it.
    assert_no_email_sent()
  end

  test "CONTROL — the SAME failure on a site with nothing on the web still mails" do
    {site, owner} = setup_site()
    refute DeployLedger.content_on_web?(site.id)

    id = fail_through_fenced_writer(site)

    assert Repo.get(Deployment, id).status == "failed"

    assert_email_sent(fn email ->
      assert email.subject == @subject
      assert {_, to} = hd(email.to)
      assert to == owner.email
    end)
  end

  ## 2. THE BORN-FAILED SEAM — a GitHub push with no way to build. A second
  ##    producer, narrowed by the same predicate at the same funnel.

  test "a born-failed push on a serving site mails nobody, and on a dark site mails" do
    {serving, _} = setup_site(%{github_repo: "octo/shop"})
    serve_content!(serving)

    assert {:ok, quiet} =
             Registry.create_failed_deployment(
               serving,
               %{git_ref: "main", delivery_id: "delivery-#{System.unique_integer([:positive])}"},
               "github push builds are not available yet"
             )

    assert Repo.get(Deployment, quiet.id).status == "failed"
    assert_no_email_sent()

    {dark, dark_owner} = setup_site(%{github_repo: "octo/shop"})

    assert {:ok, loud} =
             Registry.create_failed_deployment(
               dark,
               %{git_ref: "main", delivery_id: "delivery-#{System.unique_integer([:positive])}"},
               "github push builds are not available yet"
             )

    assert Repo.get(Deployment, loud.id).status == "failed"

    assert_email_sent(fn email ->
      assert email.subject == @subject
      assert {_, to} = hd(email.to)
      assert to == dark_owner.email
    end)
  end

  ## 3. THE REAPER — four bare `Repo.update_all` passes that never reach
  ##    `dispatch_deployment_failed/1`. Both sites are reaped in ONE sweep, so
  ##    this measures a PER-SITE narrowing and not an all-or-nothing switch: an
  ##    implementation that dropped the whole batch, or kept it, fails here.

  test "one sweep reaps two sites and enqueues an alert only for the dark one" do
    {serving, _serving_owner} = setup_site()
    serve_content!(serving)
    {:ok, quiet} = Registry.create_deployment(serving, %{git_ref: "main"})

    {dark, dark_owner} = setup_site()
    {:ok, loud} = Registry.create_deployment(dark, %{git_ref: "main"})

    # Both rows are no-build-source rows, so ONE sweep terminates both.
    assert {:ok, %{no_source_failed: 2}} = perform_job(StaleDeploymentReaper, %{})

    # FIRST: both rows really are terminal — the console lost nothing, and the
    # serving site's suppression is a suppression, not a row that never failed.
    assert Repo.get(Deployment, quiet.id).status == "failed"
    assert Repo.get(Deployment, loud.id).status == "failed"

    # The narrowing is on the ENQUEUE: a suppressed alert costs no Oban row.
    jobs = all_enqueued(worker: DeploymentAlertWorker)
    assert length(jobs) == 1
    assert [job] = jobs
    assert job.args["site_id"] == dark.id
    assert job.args["payload"]["deployment_id"] == loud.id

    assert %{success: 1} = Oban.drain_queue(queue: :default, with_safety: false)

    assert_email_sent(fn email ->
      assert email.subject == @subject
      assert {_, to} = hd(email.to)
      assert to == dark_owner.email
    end)

    # ...and that was the ONLY email the sweep produced.
    assert_no_email_sent()
  end

  ## 4. PREVIEW — a branch preview answers on its own host and NEVER touches
  ##    `sites.current_deployment_id` / `sites.port`, so it cannot destroy
  ##    production content EVEN ON A SITE THAT HAS NONE. This is the one
  ##    suppression that does not depend on the site being up, which is why it is
  ##    driven on a DARK site: on a serving site the test could not tell the
  ##    preview clause from the site clause.

  test "a preview failure on a DARK site mails nobody" do
    {site, _owner} = setup_site(%{github_repo: "octo/shop"})
    refute DeployLedger.content_on_web?(site.id)

    {:ok, _preview} = Registry.create_preview_deployment(site, "feature-x", "deadbeef")
    worker = "builder-preview-#{System.unique_integer([:positive])}"
    {:ok, claimed} = Registry.claim_next_deployment(worker)
    assert claimed.environment == "preview"

    {:ok, failed} = transition(claimed, worker, %{status: "failed", failure_reason: "boom"})

    assert Repo.get(Deployment, failed.id).status == "failed"
    assert_no_email_sent()
  end

  ## 5. THE PREDICATE ITSELF — the two directions the doubt falls, and they are
  ##    NOT the same direction (charter D3: a thing nobody could measure must not
  ##    resolve to good news).

  test "an attempt the policy cannot KEY is an alarm, not a suppression" do
    assert DeploymentFailedPolicy.destroyed_content?(%{})
    assert DeploymentFailedPolicy.destroyed_content?(%{site_id: nil})
    assert DeploymentFailedPolicy.destroyed_content?(%{site_id: nil, environment: "production"})
    assert DeploymentFailedPolicy.destroyed_content?(:not_an_attempt)

    # ...but a PREVIEW is suppressed even unkeyed: it cannot touch production.
    refute DeploymentFailedPolicy.destroyed_content?(%{site_id: nil, environment: "preview"})
  end

  ## 6. `DeployLedger.content_on_web?/1` — the predicate the policy reads, and
  ##    the three ways it must not answer.

  test "a live production row with a NULL became_live_at still counts as up" do
    {site, _owner} = setup_site()
    live = serve_content!(site, mark: false)

    # The row really is unmetered — this is the shape the assertion is about.
    assert is_nil(Repo.get(Deployment, live.id).became_live_at)
    assert DeployLedger.content_on_web?(site.id)
    refute DeploymentFailedPolicy.destroyed_content?(%{site_id: site.id})
  end

  test "a live PREVIEW row is not production content on the web" do
    {site, _owner} = setup_site(%{github_repo: "octo/shop"})
    {:ok, _preview} = Registry.create_preview_deployment(site, "feature-y", "cafebabe")
    worker = "builder-preview-#{System.unique_integer([:positive])}"
    {:ok, claimed} = Registry.claim_next_deployment(worker)
    assert claimed.environment == "preview"

    for status <- ~w(building pushing live) do
      {:ok, _} = transition(claimed, worker, %{status: status})
    end

    assert Repo.get(Deployment, claimed.id).status == "live"
    refute DeployLedger.content_on_web?(site.id)
    assert DeploymentFailedPolicy.destroyed_content?(%{site_id: site.id})
  end

  test "a non-castable site id reads false rather than raising" do
    # The reaper's alert pass runs AFTER its four bulk passes have committed; a
    # raise there fails the job and Oban re-drives a sweep that can no longer
    # find those rows. `false` is also the safe verdict — it means "nothing is
    # up", so the policy ALARMS.
    refute DeployLedger.content_on_web?("not-a-uuid")
    refute DeployLedger.content_on_web?(nil)
    assert DeploymentFailedPolicy.destroyed_content?(%{site_id: "not-a-uuid"})
  end
end
