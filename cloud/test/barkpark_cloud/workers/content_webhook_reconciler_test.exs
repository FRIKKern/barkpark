defmodule BarkparkCloud.Workers.ContentWebhookReconcilerTest do
  @moduledoc """
  dr-w11-bl-eight-sites-never-autodeploy.

  THE FAULT UNDER TEST. Content-publish webhook registration ran on site create
  and on an explicit human backfill only, so a site whose create-time
  registration failed never got one and no surface said so. Guerrilla held five
  `site-autodeploy` rows for thirteen sites.

  Two halves, tested here as one story because either alone leaves the fault
  half-open: the hourly sweep REPAIRS the sites it can reach, and
  `Registry.publish_trigger/1` REPORTS the ones it structurally cannot.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Workers.ContentWebhookReconciler

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_bp do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "https://acme.barkpark.cloud",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp bound_site(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{
          name: "Blog #{n}",
          slug: "blog-#{n}",
          kind: "static",
          framework: "astro",
          doc_type: "paper",
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production",
          read_token: "bpt_read_#{n}"
        })
      )

    site
  end

  # The box answers the LIST for `production` with exactly `names` and nothing
  # else. An absent name is the "this site was never registered" state.
  defp box_listing(names) do
    %{
      "/v1/webhooks/production" =>
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "webhooks" =>
                 Enum.map(names, &%{"id" => Ecto.UUID.generate(), "name" => &1})
             })
         }}
    }
  end

  defp writes(method) do
    StudioLinkFakeHttpClient.requests()
    |> Enum.filter(fn r ->
      r.method == method and String.contains?(r.url, "/v1/webhooks/production")
    end)
  end

  describe "the sweep repairs a site that never got its webhook" do
    test "one pass REGISTERS the missing row, and the site reports `present` afterwards" do
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      site = bound_site(bp)

      # The box has no row for this site — exactly `auto-proof`'s state on
      # guerrilla, eight weeks after a create-time 422.
      StudioLinkFakeHttpClient.program(box_listing([]))

      assert {:ok, tally} = perform_job(ContentWebhookReconciler, %{})
      assert tally == %{swept: 1, registered: 1, present: 0, skipped: 0, errored: 0}

      post = Enum.find(writes(:post), &String.contains?(&1.url, "/v1/webhooks/production"))
      assert post, "the sweep must POST the missing registration"
      body = Jason.decode!(post.body)
      assert body["name"] == "site-autodeploy-#{site.id}"
      assert body["url"] =~ "/v1/sites/webhooks/content-publish/#{site.id}"
      assert body["active"] == true

      # And the surface a site owner reads says the trigger is there.
      assert Registry.publish_trigger(Repo.reload!(site)) == :present
    end

    test "a row that ALREADY exists is left exactly as the operator left it — no PUT" do
      # The negative direction. The explicit backfill re-asserts `active: true`
      # over a human who disabled the hook by hand, justified by "a repair run is
      # the operator's intent". A SCHEDULE cannot claim that intent, so the
      # reconcile mode must be strictly narrower than the verb it reuses.
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      site = bound_site(bp)

      StudioLinkFakeHttpClient.program(box_listing(["site-autodeploy-#{site.id}"]))

      assert {:ok, tally} = perform_job(ContentWebhookReconciler, %{})
      assert tally == %{swept: 1, registered: 0, present: 1, skipped: 0, errored: 0}
      assert writes(:put) == [], "the hourly sweep must never re-enable a hook a person turned off"
      assert writes(:post) == [], "and it must never duplicate a row that already exists"
    end
  end

  describe "the sweep's population" do
    test "a CONTAINER site is not touched, and reports `not_applicable` rather than a fault" do
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])

      n = System.unique_integer([:positive])

      {:ok, container} =
        Registry.create_site(bp, %{
          name: "App #{n}",
          slug: "app-#{n}",
          kind: "container",
          framework: "nextjs"
        })

      StudioLinkFakeHttpClient.program(box_listing([]))

      assert {:ok, tally} = perform_job(ContentWebhookReconciler, %{})
      assert tally == %{swept: 0, registered: 0, present: 0, skipped: 0, errored: 0}
      assert writes(:post) == []
      assert writes(:put) == []

      # NOT a fault: a container binds no content dataset, so no trigger is owed.
      # Reporting it as `absent` would train owners to ignore the row on the
      # sites where it means something.
      assert Registry.publish_trigger(Repo.reload!(container)) == :not_applicable
    end

    test "a content-bound site with NO secret is outside the sweep's reach and reports `absent`" do
      # THE SIX. `ensure_content_webhook/2` REVEALS a secret and never MINTS one,
      # so six of guerrilla's eight uncovered sites can never be repaired by any
      # sweep built on it. That is precisely why the visibility half exists.
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      site = bound_site(bp)

      site =
        site |> Ecto.Changeset.change(content_webhook_secret_encrypted: nil) |> Repo.update!()

      StudioLinkFakeHttpClient.program(box_listing([]))

      assert Registry.list_content_webhook_sites() == []
      assert {:ok, tally} = perform_job(ContentWebhookReconciler, %{})
      assert tally == %{swept: 0, registered: 0, present: 0, skipped: 0, errored: 0}

      assert Registry.publish_trigger(site) == :absent
    end
  end

  describe "one bad box does not stop the sweep" do
    test "a site whose box cannot be read is counted `errored` and the NEXT site is still repaired" do
      # An unreadable list is `:unknown`, never `:absent` — "I could not look"
      # must not authorize a possibly-duplicating POST. The point of this test is
      # the CONTINUATION: a raise or an early return here would leave every later
      # site unreconciled while the job row still read green.
      bad_bp = live_bp()
      good_bp = live_bp()

      StudioLinkFakeHttpClient.program([])
      _blind = bound_site(bad_bp, %{bootstrap_dataset: "unreadable"})
      good = bound_site(good_bp)

      # `production` lists cleanly and is missing the good site's row;
      # `unreadable` is left unprogrammed, so the path default (`{}` — no
      # `webhooks` key) is exactly an unreadable list.
      StudioLinkFakeHttpClient.program(box_listing([]))

      assert {:ok, tally} = perform_job(ContentWebhookReconciler, %{})
      assert tally == %{swept: 2, registered: 1, present: 0, skipped: 0, errored: 1}

      posts = writes(:post)
      assert length(posts) == 1

      assert Jason.decode!(hd(posts).body)["name"] == "site-autodeploy-#{good.id}",
             "the reachable site must still be repaired after the unreachable one failed"
    end

    test "a site whose barkpark row is gone is `skipped`, not a crash" do
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      site = bound_site(bp)

      site |> Ecto.Changeset.change(barkpark_id: Ecto.UUID.generate()) |> Repo.update!()
      StudioLinkFakeHttpClient.program(box_listing([]))

      assert {:ok, tally} = perform_job(ContentWebhookReconciler, %{})
      assert tally == %{swept: 1, registered: 0, present: 0, skipped: 1, errored: 0}
    end
  end

  describe "the sweep is bounded" do
    test "`limit` caps the box calls one tick makes" do
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      for _ <- 1..3, do: bound_site(bp)

      StudioLinkFakeHttpClient.program(box_listing([]))

      assert %{swept: 2, registered: 2} = Registry.reconcile_content_webhooks(2)
      assert length(writes(:post)) == 2
    end
  end

  describe "wiring" do
    test "a crontab row schedules this worker hourly on the maintenance queue" do
      # Read off the CONFIGURED Oban plugins, never off config.exs as text: the
      # whole fault this closes is a repair path that existed and was never
      # driven. A worker nothing schedules is that fault again.
      crontab =
        Application.fetch_env!(:barkpark_cloud, Oban)[:plugins]
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> opts[:crontab]
          _ -> nil
        end)

      assert {"53 * * * *", ContentWebhookReconciler} in crontab

      assert Ecto.Changeset.get_field(ContentWebhookReconciler.new(%{}), :queue) == "maintenance"
    end
  end
end
