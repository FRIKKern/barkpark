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
  alias BarkparkCloud.Workers.StaleDeploymentReaper

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

  ## 5b. THE CAP — a person-facing SUPPRESSION, so it is measured, not asserted.
  ##     `@reap_alert_cap` decides that the 26th owner of a cluster-wide incident
  ##     hears nothing by email. A suppression branch no fixture drives is green
  ##     by construction; this drives it.

  # Swoosh's test adapter delivers `{:email, %Swoosh.Email{}}` to the test
  # process, so the mailbox itself is the counter. `assert_email_sent` consumes
  # one message and cannot answer "how many".
  defp drain_emails(acc \\ 0) do
    receive do
      {:email, _email} -> drain_emails(acc + 1)
    after
      100 -> acc
    end
  end

  test "a mass reap alerts at most the cap, and RECORDS the ones it suppressed" do
    # One container site with neither an artifact nor a repo: pass (0a) fails
    # every queued row it owns in a single sweep.
    {site, owner} = setup_site()
    over = 2
    n = Registry.reap_alert_cap() + over

    # One queued row per SITE: deploy-truth W1 re-keyed the active index onto
    # (site_id, environment), so a mass reap is many SITES on the box, not many
    # concurrent builds of one site (which the DB now refuses outright).
    bp = Registry.get_barkpark(site.barkpark_id)

    # A SECOND member, so the withheld-row grain is measured as a product and not
    # as a coincidence: a withheld alert is withheld from every person who would
    # have received it, each under their own address.
    team = Accounts.get_team(site.team_id)
    m = System.unique_integer([:positive])

    {:ok, second} =
      Accounts.register_user(%{email: "second-#{m}@example.com", password: "correct-horse-battery"})

    {:ok, _} = Accounts.add_member(team, second, "member")
    members = [owner.email, second.email]

    ids =
      for i <- 1..n do
        site_i =
          if i == 1 do
            site
          else
            {:ok, s} =
              Registry.create_site(bp, %{name: "Shop #{i}-#{n}", slug: "shop-#{i}-#{n}"})

            s
          end

        {:ok, d} = Registry.create_deployment(site_i, %{git_ref: "ref-#{i}"})
        d.id
      end

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{no_source_failed: ^n}} = perform_job(StaleDeploymentReaper, %{})
    end)

    # FIRST: every row really is terminal — the console, which is the surface of
    # record, lost nothing. The cap suppresses the EMAIL, never the truth.
    for id <- ids, do: assert(Repo.get(Deployment, id).status == "failed")

    # Both members are alerted for each of the first `cap` deployments.
    assert drain_emails() == Registry.reap_alert_cap() * length(members)

    # THE REWRITE (wave 32 S2). This test used to end on two `log =~` substrings —
    # it PINNED the falsehood that a server-side Logger line is how the owner
    # learns their alert was thrown away. It is not: the owner reads the console,
    # not our logs, and the whole value of an alert is that nobody is looking.
    # The cap stays (charter D349(g), resolved in favour of TRACING); the trace is
    # now a row the owner can read, on the surface that answers "was I notified?".
    suppressed = Notifications.list_deliveries(team, status: "suppressed", limit: 500)

    assert length(suppressed) == over * length(members),
           "the #{over} withheld alerts left no trace on the delivery log for " <>
             "#{length(members)} members — got #{length(suppressed)} suppressed rows"

    for row <- suppressed do
      assert row.recipient in members,
             "a suppressed row must name the PERSON it was withheld from, not a marker"

      assert row.event == "deployment_failed"
      assert row.last_error =~ "too many deployment alerts in one sweep"
    end

    # ...and EVERY member, not just the first: the row a person cannot find is
    # the same silence this slice exists to end.
    assert suppressed |> Enum.map(& &1.recipient) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(members)

    # The sent alerts are still on the same log, and the two outcomes are
    # distinguishable — a filter that cannot separate them is not a filter.
    assert length(Notifications.list_deliveries(team, status: "sent", limit: 500)) ==
             Registry.reap_alert_cap() * length(members)
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
end
