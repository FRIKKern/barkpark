defmodule BarkparkCloud.Notifications.DeploymentSucceededDispatchTest do
  @moduledoc """
  cch-w30-bl — the `deployment_succeeded` alert actually leaves the building, from
  BOTH writers that can land the `live` terminal, and exactly ONCE per deployment.

  ## What wave 30 measured, and what this file has to answer

  Wave 30 S1 DELETED the `deployment_succeeded` toggle because nothing in
  `cloud/lib` dispatched it. The filed follow-up (`cch-w30-bl-…`) named three
  facts a producer had to survive, and every one of them is a test below:

    * THE SUCCESS TERMINAL IS `"live"`, not `"succeeded"`. `Deployment`'s status
      vocabulary is `queued building pushing live failed cancelled`.

    * THERE ARE TWO LIVE WRITERS. `Sites.Deploy.settle_live/2` →
      `Registry.transition_deployment_with_site_update/5` is how every STATIC
      SITE BUILD reaches live — the dominant path, and the one that had no
      post-transaction dispatch at all. `Registry.transition_deployment_fenced/4`
      is the other, chosen by the agent route when `make_current` is false. A
      producer on the fenced writer alone would miss every static build, so §1
      drives a REAL build end to end through `FakeBoxRelay` rather than calling
      the writer by hand.

    * THE EDGE GUARD IS NOT FREE. `Deployment.legal_transition?/2` is
      `to == from or to in @transitions[from]`, so a live → live rewrite is
      ACCEPTED. §3 writes live twice and demands exactly one Delivery row.

  ## DELIVERY ROWS, not just the mailbox

  `assert_email_sent` consumes one message and cannot answer "how many". Every
  count here is `Notifications.list_deliveries/2` filtered to this event — the
  durable row the console's delivery log renders — so "exactly one" is a
  measured product, not the absence of a second assertion.

  `async: false`: these assert on the shared `Swoosh.Adapters.Test` mailbox.
  """
  use BarkparkCloud.DataCase, async: false
  import Swoosh.TestAssertions

  alias BarkparkCloud.{Accounts, Notifications, Registry}
  alias BarkparkCloud.Registry.{Deployment, Site, Vault}
  alias BarkparkCloud.Sites.Deploy
  alias BarkparkCloud.Sites.FakeBoxRelay

  @subject "Deployment live"
  @event "deployment_succeeded"
  @instance_url "https://acme.barkpark.cloud"

  ## Fixtures ------------------------------------------------------------------

  # A team whose OWNER is a member, so an alert has exactly one recipient — which
  # is what makes "exactly one Delivery row" a statement about the PRODUCER
  # rather than about the size of the roster.
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

  # A LIVE instance: url + encrypted admin token — what the provision-succeed path
  # writes, and the minimum the control plane needs to drive a build on a box.
  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp static_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_public_read_xyz"
      })

    site
  end

  # THE TOGGLE IS OFF BY DEFAULT AND THAT IS CORRECT (failures on, successes off
  # — `EmailSettings`'s own alert-hygiene rule). Every test that expects a
  # delivery therefore OPTS IN first, exactly as a team would; §5 is the control
  # that proves the default really is off, so this helper is not hiding a
  # producer that fires regardless.
  defp opt_in(team) do
    {:ok, _settings} = Notifications.update_settings(team, %{"deployment_succeeded" => true})
    :ok
  end

  # A CONTAINER site — the shape `Registry.claim_next_deployment/1` (the builder
  # queue) will hand out. A `kind: "static"` row is NOT in that queue: static
  # builds are driven by `Sites.Deploy` against the box, which is exactly why §1
  # uses `Deploy.run/1` and §2 uses a different site. Using one fixture for both
  # would have made §2 test nothing (`{:error, :no_queued}`, measured).
  defp container_site(bp) do
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(bp, %{name: "Shop #{n}", slug: "shop-#{n}"})
    site
  end

  defp setup_live_site do
    {team, owner} = team_with_owner()
    bp = live_barkpark(team)
    {team, owner, bp, static_site(bp)}
  end

  # The fenced writer's fixture: same team + owner, a container site the builder
  # queue really serves.
  defp setup_builder_site do
    {team, owner} = team_with_owner()
    bp = live_barkpark(team)
    {team, owner, bp, container_site(bp)}
  end

  defp deliveries(team),
    do: Notifications.list_deliveries(team, event: @event, limit: 100)

  # `pushing` is the ONLY legal predecessor of `live`
  # (`Deployment.@transitions`), so a fenced test that wants the success edge has
  # to walk there first — `building -> live` is refused outright as
  # `:illegal_transition`. This step is itself non-terminal and must send
  # nothing; §4 asserts that separately.
  defp push(claimed) do
    {:ok, pushed} =
      Registry.transition_deployment_fenced(
        claimed.id,
        "builder-1",
        claimed.claim_epoch,
        %{status: "pushing"}
      )

    pushed
  end

  # The three-poll walk a real static build lands as: plan+build, stage+health,
  # then the switch that makes the run succeeded.
  defp program_successful_build(site) do
    FakeBoxRelay.program(
      polls: [
        FakeBoxRelay.walk(~w(PLAN BUILD)),
        FakeBoxRelay.walk(~w(PLAN BUILD STAGE HEALTH)),
        FakeBoxRelay.walk(Deploy.stages(), url: "#{@instance_url}/sites/#{site.slug}/")
      ]
    )
  end

  ## 1. THE DOMINANT PATH — a static site build, driven end to end -------------

  describe "the with_site_update writer (Sites.Deploy.settle_live/2)" do
    test "a static site build driven end to end produces exactly ONE Delivery row" do
      {team, owner, bp, site} = setup_live_site()
      :ok = opt_in(team)
      {:ok, d} = Deploy.enqueue(site, bp)
      program_successful_build(site)

      assert {:ok, :live} = Deploy.run(d.id)

      # FIRST: the fixture really reached the success terminal, through the
      # writer this row exists for — the row is live AND the site's live pointer
      # moved, which only `transition_deployment_with_site_update/5` does.
      final = Repo.get(Deployment, d.id)
      assert final.status == "live"
      assert Repo.get(Site, site.id).current_deployment_id == d.id

      # THEN: the person hears about it, once.
      assert [delivery] = deliveries(team)
      assert delivery.event == @event
      assert delivery.recipient == owner.email

      assert_email_sent(fn email ->
        assert email.subject == @subject
        assert {_, to} = hd(email.to)
        assert to == owner.email
      end)
    end

    test "the alert names WHICH deployment went live, and invents no cause" do
      {team, _owner, bp, site} = setup_live_site()
      :ok = opt_in(team)
      {:ok, d} = Deploy.enqueue(site, bp)
      program_successful_build(site)

      assert {:ok, :live} = Deploy.run(d.id)
      assert Repo.get(Deployment, d.id).status == "live"

      assert_email_sent(fn email ->
        # The site is named, not `EventEmail`'s "Your Barkpark" fallback…
        assert email.text_body =~ site.name
        # …and the identity line is the shared `Render.deployment_identity/1`
        # formatter, so the inbox and chat name the same deployment the same way.
        assert email.text_body =~ "Deployment #{d.id}"
        assert email.text_body =~ "A deployment for #{site.name} is live."

        # NOTHING FABRICATED. `deployments` has no started_at/finished_at to
        # subtract, and the producer sends no `:detail` — the row's own
        # "live at <url>" sentence is written by `settle_live/2` only, so it is
        # not a fact the agent route would have.
        for word <- ~w(duration took elapsed lasted commit) do
          refute email.text_body =~ word
        end
      end)
    end
  end

  ## 2. THE OTHER WRITER — the agent route with make_current false -------------

  describe "the fenced writer (transition_deployment_fenced/4)" do
    test "a deployment driven live through the fenced writer alerts the team once" do
      {team, owner, _bp, site} = setup_builder_site()
      :ok = opt_in(team)
      {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
      {:ok, claimed} = Registry.claim_next_deployment("builder-1")
      _ = push(claimed)

      assert {:ok, _} =
               Registry.transition_deployment_fenced(
                 claimed.id,
                 "builder-1",
                 claimed.claim_epoch,
                 %{status: "live"}
               )

      assert Repo.get(Deployment, claimed.id).status == "live"
      assert [delivery] = deliveries(team)
      assert delivery.recipient == owner.email

      assert_email_sent(fn email -> assert email.subject == @subject end)
    end

    test "a fenced transition that ROLLS BACK sends nothing" do
      {team, _owner, _bp, site} = setup_builder_site()
      :ok = opt_in(team)
      {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
      {:ok, claimed} = Registry.claim_next_deployment("builder-1")

      # A stale epoch rolls the whole transaction back before any write lands.
      # The dispatch is POST-commit, so nothing may escape.
      assert {:error, :stale_epoch} =
               Registry.transition_deployment_fenced(
                 claimed.id,
                 "builder-1",
                 claimed.claim_epoch + 7,
                 %{status: "live"}
               )

      refute Repo.get(Deployment, claimed.id).status == "live"
      assert deliveries(team) == []
      assert_no_email_sent()
    end
  end

  ## 3. THE EDGE GUARD — live -> live is a LEGAL rewrite -----------------------

  describe "edge-triggered on the PRIOR status" do
    test "TWO live writes through the with_site_update writer produce exactly ONE Delivery row" do
      {team, _owner, bp, site} = setup_live_site()
      :ok = opt_in(team)
      {:ok, d} = Deploy.enqueue(site, bp)
      program_successful_build(site)

      assert {:ok, :live} = Deploy.run(d.id)
      assert [_one] = deliveries(team)

      # THE SECOND LIVE WRITE. `legal_transition?/2` is `to == from or …`, so
      # this is ACCEPTED — the writer returns {:ok, _}, the row stays live, and
      # the ONLY thing standing between a person and a duplicate alert is the
      # edge guard on the prior status.
      live_row = Repo.get(Deployment, d.id)

      assert {:ok, _} =
               Registry.transition_deployment_with_site_update(
                 live_row.id,
                 live_row.claim_worker,
                 live_row.claim_epoch,
                 %{status: "live"},
                 %{current_deployment_id: live_row.id}
               )

      assert Repo.get(Deployment, d.id).status == "live"
      assert length(deliveries(team)) == 1
    end

    test "TWO live writes through the FENCED writer produce exactly ONE Delivery row" do
      {team, _owner, _bp, site} = setup_builder_site()
      :ok = opt_in(team)
      {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
      {:ok, claimed} = Registry.claim_next_deployment("builder-1")
      _ = push(claimed)

      # The FIRST write is the edge pushing -> live; the SECOND is live -> live,
      # which `legal_transition?/2` ACCEPTS (`to == from`). Only the edge guard
      # keeps the second one silent.
      for _ <- 1..2 do
        assert {:ok, _} =
                 Registry.transition_deployment_fenced(
                   claimed.id,
                   "builder-1",
                   claimed.claim_epoch,
                   %{status: "live"}
                 )
      end

      assert Repo.get(Deployment, claimed.id).status == "live"
      assert length(deliveries(team)) == 1
    end
  end

  ## 4. NOT EVERY TRANSITION IS A SUCCESS --------------------------------------

  test "a non-terminal transition (building -> pushing) sends nothing" do
    {team, _owner, _bp, site} = setup_builder_site()
    :ok = opt_in(team)
    {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main"})
    {:ok, claimed} = Registry.claim_next_deployment("builder-1")

    assert {:ok, _} =
             Registry.transition_deployment_fenced(
               claimed.id,
               "builder-1",
               claimed.claim_epoch,
               %{status: "pushing"}
             )

    assert deliveries(team) == []
    assert_no_email_sent()
  end

  ## 5. THE DEFAULT IS OFF — the control that keeps §1-§3 honest ---------------

  test "with the toggle at its DEFAULT, a live build delivers nothing" do
    # Successes default OFF (EmailSettings' alert-hygiene rule). This is the
    # control: without it, a producer that ignored the toggle entirely would pass
    # every test above, because every one of them opts in first.
    {team, _owner, bp, site} = setup_live_site()
    {:ok, d} = Deploy.enqueue(site, bp)
    program_successful_build(site)

    assert {:ok, :live} = Deploy.run(d.id)
    assert Repo.get(Deployment, d.id).status == "live"

    assert deliveries(team) == []
    assert_no_email_sent()
  end

  ## 6. THE TOGGLE IS REACHABLE ------------------------------------------------

  test "the event is in EmailSettings' vocabulary, so the console can offer it" do
    # The pairing the console census guards from the other side: a producer with
    # no column is an alert nobody can switch on.
    assert :deployment_succeeded in BarkparkCloud.Notifications.EmailSettings.events()
    assert @event in Notifications.chat_events()
  end
end
