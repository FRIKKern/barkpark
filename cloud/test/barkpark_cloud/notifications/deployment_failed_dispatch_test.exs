defmodule BarkparkCloud.Notifications.DeploymentFailedDispatchTest do
  @moduledoc """
  wave 28 S6 — the `deployment_failed` alert actually leaves the building.

  The console renders a live per-channel matrix row for "Deployment failed" and
  the EMAIL column is default-true in a migration-backed column, but on main
  `:deployment_failed` had ZERO dispatch sites: the person is promised an alert
  nothing could ever send.

  PRODUCER-LEVEL BY CONSTRUCTION. `router_notifications_test.exs` hand-builds a
  payload into `EventEmail.build/4` and is green on a tree with no dispatchers at
  all — a test in that shape proves nothing about whether an alert is reachable.
  Every test here drives a REAL write to `failed` (the fenced writer, the
  reaper's bulk `update_all` passes, the born-failed webhook insert), asserts the
  ROW is `"failed"` FIRST — so the fixture is proven able to produce the defect —
  and only then asserts the delivery.

  `async: false`: these assert on the shared `Swoosh.Adapters.Test` mailbox.
  """
  use BarkparkCloud.DataCase, async: false
  use Oban.Testing, repo: BarkparkCloud.Repo
  import Swoosh.TestAssertions

  alias BarkparkCloud.{Accounts, Notifications, Registry}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Workers.{DeploymentAlertWorker, StaleDeploymentReaper}

  @subject "Deployment failed"

  ## Fixtures — a team whose OWNER is a member, so an alert has a recipient.

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

  # {site, owner} — the minimum tree a Deployment hangs off, plus a recipient.
  defp setup_site(site_attrs \\ %{}) do
    {team, owner} = team_with_owner()
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    {:ok, site} =
      Registry.create_site(bp, Map.merge(%{name: "Shop #{n}", slug: "shop-#{n}"}, site_attrs))

    {site, owner}
  end

  # THE REAPER'S ALERTS ARE OFF THE TICK (cch-w28-s6-followup). The sweep used to
  # call `Mailer.deliver` inline; it now enqueues one `DeploymentAlertWorker` job
  # per reaped deployment. So every reaper test below drains the queue between
  # the sweep and its email assertion, and the drain is not a formality: it is
  # the assertion. Every one of these tests is RED if the enqueue is replaced by
  # a synchronous send, because §2b asserts the mailbox is EMPTY before it.
  defp drain_alerts do
    Oban.drain_queue(queue: :default, with_safety: false)
  end

  defp backdate(deployment_id) do
    stale_at =
      DateTime.add(DateTime.utc_now(), -(Registry.deployment_stale_after_seconds() + 60), :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(from(d in Deployment, where: d.id == ^deployment_id),
      set: [claimed_at: stale_at]
    )
  end

  ## 1. The FENCED writer — the builder route, the agent route and
  ##    `Sites.Deploy.fail/2` all funnel through it.

  test "a deployment failed through the fenced writer alerts the site's team" do
    {site, owner} = setup_site()
    {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, claimed} = Registry.claim_next_deployment("builder-1")

    assert {:ok, _} =
             Registry.transition_deployment_fenced(
               claimed.id,
               "builder-1",
               claimed.claim_epoch,
               %{status: "failed", failure_reason: "unauthorized: invalid token"}
             )

    # FIRST: the fixture really produced the defect.
    assert Repo.get(Deployment, claimed.id).status == "failed"
    # THEN: the person hears about it.
    assert_email_sent(fn email ->
      assert email.subject == @subject
      assert {_, to} = hd(email.to)
      assert to == owner.email
    end)
  end

  ## 2. The REAPER — four bare `Repo.update_all` passes that never touch the
  ##    fenced writer. A route-side-only fix misses every one of them.

  test "a deployment failed by the reaper's JOINED bulk pass alerts the team" do
    # A container site with no artifact and no connected repo: pass (0a).
    {site, owner} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})

    assert {:ok, %{no_source_failed: 1}} = perform_job(StaleDeploymentReaper, %{})

    assert Repo.get(Deployment, d.id).status == "failed"

    assert %{success: 1} = drain_alerts()

    assert_email_sent(fn email ->
      assert email.subject == @subject
      assert {_, to} = hd(email.to)
      assert to == owner.email
    end)
  end

  ## 2b. ENQUEUED, NOT DELIVERED INLINE — the property the cap's deletion rests
  ##     on. If the alert were still synchronous the sweep would hold the tick
  ##     for the whole fan-out, which is the entire reason a cap existed.

  test "the reaper's alert is an Oban job, and NOTHING is mailed until it runs" do
    {site, owner} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})

    assert {:ok, %{no_source_failed: 1}} = perform_job(StaleDeploymentReaper, %{})
    assert Repo.get(Deployment, d.id).status == "failed"

    # The sweep sent NOTHING itself...
    assert_no_email_sent()

    # ...it left a job naming the site, carrying the payload the synchronous
    # producers build by hand.
    assert_enqueued(worker: DeploymentAlertWorker, args: %{site_id: site.id})

    [job] = all_enqueued(worker: DeploymentAlertWorker)
    assert job.args["payload"]["deployment_id"] == d.id
    assert job.args["payload"]["detail"] =~ "no build source"

    # ...and running it is what mails the owner.
    assert %{success: 1} = drain_alerts()

    assert_email_sent(fn email ->
      assert email.subject == @subject
      assert {_, to} = hd(email.to)
      assert to == owner.email
    end)
  end

  test "a deployment failed by the reaper's PLAIN bulk pass alerts the team" do
    # Pass (i): a stale `building` row at the claim budget. Not joined — proves
    # the row-naming works for both query shapes the sweep uses.
    {site, owner} = setup_site(%{github_repo: "octo/shop"})
    {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, claimed} = Registry.claim_next_deployment("builder-1")

    Repo.update_all(from(d in Deployment, where: d.id == ^claimed.id),
      set: [claim_epoch: Registry.max_deploy_claims()]
    )

    backdate(claimed.id)

    assert {:ok, %{failed: 1}} = perform_job(StaleDeploymentReaper, %{})
    assert Repo.get(Deployment, claimed.id).status == "failed"
    assert %{success: 1} = drain_alerts()

    assert_email_sent(fn email ->
      assert email.subject == @subject
      assert {_, to} = hd(email.to)
      assert to == owner.email
    end)
  end

  ## 3. The BORN-FAILED seam — a GitHub push with no way to build.

  test "a born-failed deployment from the push webhook alerts the team" do
    {site, owner} = setup_site(%{github_repo: "octo/shop"})

    assert {:ok, d} =
             Registry.create_failed_deployment(
               site,
               %{git_ref: "main", delivery_id: "delivery-#{System.unique_integer([:positive])}"},
               "github push builds are not available yet"
             )

    assert Repo.get(Deployment, d.id).status == "failed"

    assert_email_sent(fn email ->
      assert email.subject == @subject
      assert {_, to} = hd(email.to)
      assert to == owner.email
    end)
  end

  ## 4. POST-TRANSACTION — a rolled-back transition emails nobody.

  test "a fenced transition that rolls back sends nothing" do
    {site, _owner} = setup_site(%{github_repo: "octo/shop"})
    {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, claimed} = Registry.claim_next_deployment("builder-1")

    # A stale epoch rolls the whole transaction back before any write lands.
    assert {:error, :stale_epoch} =
             Registry.transition_deployment_fenced(
               claimed.id,
               "builder-1",
               claimed.claim_epoch + 7,
               %{status: "failed", failure_reason: "boom"}
             )

    refute Repo.get(Deployment, claimed.id).status == "failed"
    assert_no_email_sent()
  end

  ## 5. EDGE-TRIGGERED — `record_stage/2` re-drives the writer on every stage
  ##    report and `status_for_stage/2` carries "failed" forward, so a
  ##    failed → failed rewrite must not re-alert.

  test "a failed -> failed re-drive does not send a second alert" do
    {site, _owner} = setup_site(%{github_repo: "octo/shop"})
    {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, claimed} = Registry.claim_next_deployment("builder-1")

    {:ok, _} =
      Registry.transition_deployment_fenced(claimed.id, "builder-1", claimed.claim_epoch, %{
        status: "failed",
        failure_reason: "unauthorized: invalid token"
      })

    assert_email_sent(fn email -> assert email.subject == @subject end)

    # The same writer, re-driven with the status it already carries.
    {:ok, _} =
      Registry.transition_deployment_fenced(claimed.id, "builder-1", claimed.claim_epoch, %{
        status: "failed",
        failure_reason: "unauthorized: invalid token"
      })

    assert Repo.get(Deployment, claimed.id).status == "failed"
    assert_no_email_sent()
  end

  ## 5b. THE MASS REAP — 27 deployments across TWO teams in ONE sweep, and
  ##     EVERY owning team is alerted.
  ##
  ##     This replaces the cap test (wave 28 S6, rewritten wave 32 S2). The old
  ##     one drove `Registry.reap_alert_cap()` + 2 rows and asserted that the
  ##     tail was SUPPRESSED — `length(suppressed) == over * length(members)`.
  ##     That assertion is gone, and gone on purpose: it pinned the policy this
  ##     slice deletes. It cannot be kept byte-identical AND green, because with
  ##     the cap deleted the sweep withholds nothing, so `over * length(members)`
  ##     is now a demand for rows whose existence would be the bug. What it was
  ##     protecting — the GRAIN of a withheld row, one per member with that
  ##     member's own address — is not deleted with it: it moves to
  ##     `withhold_batch_test.exs`, at the grain of `Withhold.record/4` itself,
  ##     where it survives the cap's removal. The inverse of the old assertion is
  ##     asserted below: ZERO suppressed rows, because nobody was skipped.
  ##
  ##     The old literal 25 stays in the fixture as a HARD-CODED number
  ##     (`@over_the_old_cap`), not a call to a policy reader: the number the
  ##     fixture must exceed is a historical fact about a deleted cap, and reading
  ##     it from the code under test is how a driven test goes vacuous when that
  ##     code changes.

  # The cap that used to stand. A fixture must fail MORE than this in one sweep
  # or it cannot tell an uncapped fan-out from the capped one it replaced.
  @old_reap_alert_cap 25
  @over_the_old_cap 2

  # Swoosh's test adapter delivers `{:email, %Swoosh.Email{}}` to the test
  # process, so the mailbox itself is the record. `assert_email_sent` consumes
  # one message and cannot answer "how many, and to whom".
  defp collect_emails(acc \\ []) do
    receive do
      {:email, email} ->
        collect_emails(Enum.map(email.to, fn {_name, address} -> address end) ++ acc)
    after
      100 -> acc
    end
  end

  # A second team, so "every OWNING TEAM" is a measured product and not a
  # coincidence of there being only one. Returns {barkpark, [member emails]}.
  defp second_team_with_two_members do
    {team, owner} = team_with_owner()
    n = System.unique_integer([:positive])

    {:ok, extra} =
      Accounts.register_user(%{
        email: "extra-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _} = Accounts.add_member(team, extra, "member")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {team, bp, Enum.sort([owner.email, extra.email])}
  end

  test "a mass reap over the old cap alerts EVERY owning team, none suppressed" do
    # Team A: the site fixture's own team, plus a second member so the per-team
    # fan-out is a product.
    {site_a, owner_a} = setup_site()
    team_a = Accounts.get_team(site_a.team_id)
    m = System.unique_integer([:positive])

    {:ok, second} =
      Accounts.register_user(%{
        email: "second-#{m}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _} = Accounts.add_member(team_a, second, "member")
    members_a = Enum.sort([owner_a.email, second.email])

    # Team B: a DIFFERENT team, two members of its own.
    {team_b, bp_b, members_b} = second_team_with_two_members()

    # One queued row per SITE: deploy-truth W1 re-keyed the active index onto
    # (site_id, environment), so a mass reap is many SITES on the box, not many
    # concurrent builds of one site (which the DB now refuses outright).
    bp_a = Registry.get_barkpark(site_a.barkpark_id)

    n = @old_reap_alert_cap + @over_the_old_cap
    assert n > @old_reap_alert_cap

    # Split across the two teams so the tail — the rows the cap used to throw
    # away — belongs to a team that has NO row inside the old first 25.
    a_count = @old_reap_alert_cap
    b_count = @over_the_old_cap

    ids =
      for i <- 1..n do
        {bp, owner_site} = if i <= a_count, do: {bp_a, i == 1}, else: {bp_b, false}

        site_i =
          if owner_site do
            site_a
          else
            {:ok, s} = Registry.create_site(bp, %{name: "Shop #{i}-#{n}", slug: "shop-#{i}-#{n}"})
            s
          end

        {:ok, d} = Registry.create_deployment(site_i, %{git_ref: "ref-#{i}"})
        d.id
      end

    assert {:ok, %{no_source_failed: ^n}} = perform_job(StaleDeploymentReaper, %{})

    # FIRST: every row really is terminal — the fixture is proven able to produce
    # the defect, and the console lost nothing.
    for id <- ids, do: assert(Repo.get(Deployment, id).status == "failed")

    # THE UNCAPPED FAN-OUT: one job per reaped deployment, all n of them, and
    # the 26th and 27th are there — under the cap they were dropped.
    jobs = all_enqueued(worker: DeploymentAlertWorker)
    assert length(jobs) == n
    assert_no_email_sent()

    assert %{success: ^n} = drain_alerts()

    # EVERY owning team's every member is mailed, once per failed deployment
    # their team owns.
    sent_to = collect_emails()
    assert length(sent_to) == a_count * length(members_a) + b_count * length(members_b)

    assert sent_to |> Enum.uniq() |> Enum.sort() == Enum.sort(members_a ++ members_b)

    # Team B is the whole point: its rows are the tail the cap suppressed, and
    # both of its members hear about both of them.
    for address <- members_b do
      assert Enum.count(sent_to, &(&1 == address)) == b_count
    end

    # NOTHING was withheld — the inverse of the assertion the cap test made.
    for team <- [team_a, team_b] do
      assert Notifications.list_deliveries(team, status: "suppressed", limit: 500) == []
    end

    # ...and the sends are on the delivery log at the same grain as the mail.
    assert length(Notifications.list_deliveries(team_a, status: "sent", limit: 500)) ==
             a_count * length(members_a)

    assert length(Notifications.list_deliveries(team_b, status: "sent", limit: 500)) ==
             b_count * length(members_b)
  end

  ## 6. THE EMAIL — a classified cause, not raw reaper jargon, and the site named.

  test "the alert names the SITE and leads with a classified cause, capture below" do
    {site, _owner} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})

    assert {:ok, %{no_source_failed: 1}} = perform_job(StaleDeploymentReaper, %{})
    reaped = Repo.get(Deployment, d.id)
    assert reaped.status == "failed"
    # The raw reason the dashboard classifies — the jargon that used to ship.
    assert reaped.failure_reason =~ "no build source (upload an artifact"
    assert %{success: 1} = drain_alerts()

    assert_email_sent(fn email ->
      # The SITE is named, not EventEmail's "Your Barkpark" fallback.
      assert email.text_body =~ site.name
      refute email.text_body =~ "Your Barkpark"
      # The human class leads.
      assert email.text_body =~ "This site has no build source yet."
      # The honest capture is kept, below its heading (D310's ruling).
      assert email.text_body =~ "What the provider reported:"
      assert email.text_body =~ "no build source (upload an artifact"
    end)
  end

  ## 7. WHICH DEPLOYMENT (wave 15 S4, charter D248) — the alert used to be a
  ##    site name plus a cause, so three alerts in an hour were indistinguishable
  ##    from three attempts at one push. All THREE producer paths now name the
  ##    deployment, and each is driven here through a real write to `failed`.

  test "the FENCED writer's alert names the deployment id, stage and git_ref" do
    {site, _owner} = setup_site(%{github_repo: "octo/shop"})
    {:ok, _d} = Registry.create_deployment(site, %{git_ref: "refs/heads/main"})
    {:ok, claimed} = Registry.claim_next_deployment("builder-1")

    assert {:ok, failed} =
             Registry.transition_deployment_fenced(
               claimed.id,
               "builder-1",
               claimed.claim_epoch,
               %{status: "failed", failure_reason: "unauthorized: invalid token", stage: "BUILD"}
             )

    assert Repo.get(Deployment, claimed.id).status == "failed"

    assert_email_sent(fn email ->
      assert email.text_body =~
               "Deployment #{failed.id} · stage BUILD · git_ref refs/heads/main"

      # The identity leads, the cause follows it.
      assert email.text_body =~ "A deployment for #{site.name} failed.\n\nDeployment #{failed.id}"
    end)
  end

  test "the BORN-FAILED webhook alert names the deployment it just minted" do
    {site, _owner} = setup_site(%{github_repo: "octo/shop"})

    assert {:ok, d} =
             Registry.create_failed_deployment(
               site,
               %{git_ref: "main", delivery_id: "delivery-#{System.unique_integer([:positive])}"},
               "github push builds are not available yet"
             )

    assert Repo.get(Deployment, d.id).status == "failed"

    assert_email_sent(fn email ->
      assert email.text_body =~ "Deployment #{d.id} · git_ref main"
    end)
  end

  test "the REAPER's fan-out names the deployment its select already held" do
    # The id was SELECTED at the sweep and thrown away as `_id`; it now rides the
    # payload. The reaper holds no struct, so stage/code identity are absent
    # rather than filled in — the alert claims only what the producer had.
    {site, _owner} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})

    assert {:ok, %{no_source_failed: 1}} = perform_job(StaleDeploymentReaper, %{})
    assert Repo.get(Deployment, d.id).status == "failed"
    assert %{success: 1} = drain_alerts()

    assert_email_sent(fn email ->
      refute email.text_body =~ "stage "
      refute email.text_body =~ "git_ref"
      assert email.text_body =~ "Deployment #{d.id}"
    end)
  end

  test "the alert invents no link and no build duration" do
    {site, _owner} = setup_site()
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main"})

    assert {:ok, %{no_source_failed: 1}} = perform_job(StaleDeploymentReaper, %{})
    assert Repo.get(Deployment, d.id).status == "failed"
    assert %{success: 1} = drain_alerts()

    assert_email_sent(fn email ->
      # `deployments` carries no started_at/finished_at, and `became_live_at` is
      # NULL on every failed row — any duration here would be fabricated.
      for word <- ~w(duration took elapsed lasted commit) do
        refute email.text_body =~ word
      end

      refute email.text_body =~ "http"
      assert email.text_body =~ "Deployment #{d.id}"
    end)
  end
end
