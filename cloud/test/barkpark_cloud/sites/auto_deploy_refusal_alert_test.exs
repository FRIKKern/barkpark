defmodule BarkparkCloud.Sites.AutoDeployRefusalAlertTest do
  @moduledoc """
  cch-w29-bl + cch-w31-bl — THE AUTO-DEPLOY REFUSAL REACHES A PERSON WHO WAS NOT
  LOOKING AT THE CONSOLE.

  ## The two halves, and why they are one file

  `Sites.AutoDeployWorker.refuse/1` has exactly two outcomes, and before this
  change both of them ended inside the control plane:

    * the row was minted — a `cancelled` deployment carrying the remedy, which is
      a CONSOLE trace and reaches nobody who published and walked away
      (`cch-w29-bl`);
    * the row FAILED to insert — the transaction rolled back and the branch ended
      at a `Logger.warning`, so the person's content did not deploy and there was
      no trace anywhere a person can read (`cch-w31-bl`).

  They are the two arms of one `case`, so they are proved together: a test that
  only drove the happy arm would leave the other one green by never running it.

  ## PRODUCER-LEVEL, and the DELIVERY is the assertion

  Every test here drives the real `perform/1` against a real prebuilt-current
  site and asserts the OUTCOME FIRST (the cancel tuple, and the presence or
  absence of the row) — so the fixture is proven able to produce the case — and
  only then asserts what reached the person. `router_notifications_test.exs`'s
  shape (hand-build a payload into `EventEmail.build/4`) is green on a tree with
  no dispatch site at all and proves nothing about reachability.

  ## The copy is PINNED, never re-typed

  The remedy has one owner: `AutoDeployWorker.refusal_detail/0`, the same string
  the worker writes into the deployment row. The email assertion reads that
  function — it does not carry a copy of the sentence — so a change to the remedy
  that forgot the inbox reds here instead of shipping two different instructions
  to the same person. A NON-VACUITY assertion guards the pin itself: a
  `refusal_detail/0` that degraded to `""` would make `=~` trivially true, so the
  sentence is first asserted to still name the command.

  `async: false`: these assert on the shared `Swoosh.Adapters.Test` mailbox.
  """
  use BarkparkCloud.DataCase, async: false
  use Oban.Testing, repo: BarkparkCloud.Repo
  import Swoosh.TestAssertions

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Notifications.{Delivery, Withhold}
  alias BarkparkCloud.Registry.{Deployment, Vault}
  alias BarkparkCloud.Sites.{AutoDeployWorker, Deploy}

  @instance_url "https://acme.barkpark.cloud"

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
        read_token: "bpt_read_#{n}"
      })

    site
  end

  # {bp, site, owner} — a site whose CURRENT release was UPLOADED, i.e. bytes
  # this fleet cannot reproduce, which is what `refuse/1` protects.
  defp prebuilt_site do
    {team, owner} = team_with_owner()
    bp = live_barkpark(team)
    site = static_site(bp)

    {:ok, marker} = Deploy.enqueue(site, bp, false, "manual", nil, "prebuilt")
    assert marker.source == "prebuilt"

    site =
      site
      |> Ecto.Changeset.change(current_deployment_id: went_live(marker).id)
      |> Repo.update!()

    {bp, site, owner}
  end

  # A site's CURRENT release is a build that FINISHED — and the active-deployment
  # index would otherwise (correctly) block the very refusal these tests drive.
  defp went_live(deployment) do
    Enum.reduce(~w(building pushing live), deployment, fn status, d ->
      {:ok, next} = Registry.transition_deployment(d, %{status: status})
      next
    end)
  end

  defp content_autos(site) do
    Repo.all(from(d in Deployment, where: d.site_id == ^site.id and d.trigger == "content-auto"))
  end

  defp deliveries(event) do
    Repo.all(from(d in Delivery, where: d.event == ^event))
  end

  ## ── cch-w29-bl — the refusal EMITS AN EVENT and it is DELIVERED ───────────

  describe "a refused auto-deploy reaches an inbox (cch-w29-bl)" do
    test "the delivery FIRES, and its body carries refusal_detail/0 rather than a re-typed twin" do
      {_bp, site, owner} = prebuilt_site()

      # NON-VACUITY, first: an empty or remedy-less `refusal_detail/0` would make
      # the `=~` below trivially true no matter what the email said.
      remedy = AutoDeployWorker.refusal_detail()
      assert String.length(remedy) > 80
      assert remedy =~ "bp cloud site deploy"
      assert remedy =~ "--prebuilt"

      # THE OUTCOME FIRST: the fixture really produced a refusal.
      assert {:cancel, :prebuilt_release_protected} =
               perform_job(AutoDeployWorker, %{"site_id" => site.id})

      assert [row] = content_autos(site)
      assert row.status == "cancelled"
      assert row.detail == remedy

      # THEN: the person who never opened the console hears about it. This is the
      # assertion the row exists for — the DELIVERY, not the toggle.
      assert_email_sent(fn email ->
        assert email.subject == "Deployment refused"
        assert {_, to} = hd(email.to)
        assert to == owner.email

        # THE PIN. The delivered text contains the module attribute's own value,
        # read back through its accessor — no copy of the sentence lives here.
        assert email.text_body =~ remedy

        # …and it names WHICH deployment, so a reader with three of these can act.
        assert email.text_body =~ row.id
      end)

      # The delivery is LOGGED, so the notifications page can answer "was I told?"
      assert [%Delivery{} = d] = deliveries("deployment_refused")
      assert d.status == "sent"
      assert d.recipient == owner.email
      assert d.kind == "alert"
    end

    test "the event is in the vocabulary the settings row and the dispatcher share" do
      # The toggle did not land ahead of its dispatcher: the atom is a real
      # column, and its default is ON because a refused publish is a FAILURE.
      assert :deployment_refused in BarkparkCloud.Notifications.EmailSettings.events()

      assert %BarkparkCloud.Notifications.EmailSettings{deployment_refused: true} =
               %BarkparkCloud.Notifications.EmailSettings{}
    end
  end

  ## ── cch-w31-bl — the row that could NOT be written still leaves a trace ───

  # THE FIXTURE FOR THE FAILURE ARM IS THE REAL FAILURE, not a stubbed Repo: an
  # in-flight production build holds `deployments_active_site_env_index`, so the
  # `queued` row `refuse/1` mints FIRST loses that insert, `Repo.rollback/1`
  # takes the whole transaction with it, and the worker lands in the arm that
  # used to end at a Logger line.
  defp block_the_refusal_row(site) do
    {:ok, in_flight} = Registry.create_deployment(site, %{git_ref: "main"})
    assert in_flight.status == "queued"
    in_flight
  end

  describe "the refusal row itself fails to insert (cch-w31-bl)" do
    test "a suppressed Delivery row per member names the decision the reader can act on" do
      {_bp, site, owner} = prebuilt_site()
      in_flight = block_the_refusal_row(site)

      # THE OUTCOME FIRST: still refused BY VALUE, and NO refusal row exists.
      assert {:cancel, :prebuilt_release_protected} =
               perform_job(AutoDeployWorker, %{"site_id" => site.id})

      assert content_autos(site) == [],
             "the fixture did not reproduce the case — a refusal row was written after all"

      assert Repo.get(Deployment, in_flight.id).status == "queued"

      # No alert was sent: there is no row for it to name.
      assert_no_email_sent()

      # THE TRACE. One `suppressed` row per member, with that member's own
      # address, carrying the CLOSED-VOCABULARY sentence.
      assert [%Delivery{} = row] = deliveries("deployment_refused")
      assert row.status == Withhold.status()
      assert row.recipient == owner.email
      assert row.attempts == 0
      assert row.last_error == Withhold.label(:deployment_refusal_unrecorded)
    end

    test "the trace names a decision and a remedy, and carries NO raw capture" do
      sentence = Withhold.label(:deployment_refusal_unrecorded)

      # The DECISION, in words a reader can act on.
      assert sentence =~ "REFUSED"
      assert sentence =~ "did not go live"
      assert sentence =~ "prebuilt site deploy"

      # CLOSED VOCABULARY: the changeset that failed the insert never reaches it.
      refute sentence =~ "Ecto"
      refute sentence =~ "changeset"
      refute sentence =~ "Postgrex"
      # No id, no address, no capture: a constant has no shape to interpolate.
      refute sentence =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}/

      # And it is publishable — `Delivery.changeset/2` clamps `last_error` to the
      # published vocabulary, so a sentence outside it would write ZERO rows.
      assert sentence in Withhold.labels()
      assert :deployment_refusal_unrecorded in Withhold.reasons()
    end
  end
end
