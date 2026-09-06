defmodule BarkparkCloud.ContentSecretMintTest do
  @moduledoc """
  task-bf9a5199484a5a6b — the WRITE half of the auto-deploy repair.

  THE FAULT UNDER TEST. `ensure_content_webhook/2` REVEALS a site's
  content-publish secret and never MINTS one, so the hourly
  `ContentWebhookReconciler` built on it can only repair a site that already has
  one. A content-bound site whose secret was never minted therefore reports
  `publish_trigger: absent` on every surface FOREVER and no sweep can fix it —
  six of guerrilla's thirteen sites were in exactly that state. This file pins
  the missing write and the three ways it must refuse to fire.

  THE RULING IT ENCODES: the mint is an OPERATOR VERB
  (`POST /v1/operator/sites/content-secrets/mint`), not a tick of the hourly
  schedule. A schedule that mints credentials silently turns every content-bound
  site into a live publish target on its next tick — including sites a human
  deliberately left un-wired — and leaves nobody's name on the write. The verb
  keeps it an intentional act with an audit row, and registers the webhook INLINE
  so the repair does not wait an hour to become true.

  Fixture style is inherited from `content_webhook_reconciler_test.exs`, whose
  population claims this file is the complement of.

  `async: false` — the operator allowlist is process-global Application config
  (`:platform_admin_emails`), the same reason `RouterOperatorTest` is serial.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Site
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  setup do
    prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prior) end)
    :ok
  end

  ## Fixtures

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp live_bp(team \\ nil) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team || team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "https://bp-#{n}.barkpark.cloud",
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

  # A content-bound site in THE STATE THIS ROW EXISTS FOR: a dataset, and no
  # content-publish secret ever minted. `create_site/2` always mints one, so the
  # state has to be reached by nulling the column — which is exactly how the six
  # guerrilla rows read (their create predates the mint, or its write was lost).
  defp secretless_site(bp, attrs \\ %{}) do
    site = bound_site(bp, attrs)
    site |> Ecto.Changeset.change(content_webhook_secret_encrypted: nil) |> Repo.update!()
  end

  defp container_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "App #{n}",
        slug: "app-#{n}",
        kind: "container",
        framework: "nextjs"
      })

    site
  end

  defp box_listing(names) do
    %{
      "/v1/webhooks/production" =>
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "webhooks" => Enum.map(names, &%{"id" => Ecto.UUID.generate(), "name" => &1})
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

  defp operator_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "op-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "OpTeam #{n}", slug: "opteam-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
    user
  end

  defp plain_user_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "plain-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "PlainTeam #{n}", slug: "plainteam-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    user
  end

  defp mint_via_route(user) do
    conn = conn(:post, "/v1/operator/sites/content-secrets/mint")

    conn =
      case user do
        nil ->
          conn

        user ->
          {:ok, token} = Accounts.create_user_session_token(user)
          put_req_header(conn, "authorization", "Bearer #{token}")
      end

    Router.call(conn, @opts)
  end

  defp audit_rows(action) do
    BarkparkCloud.Accounts.AuditEvent
    |> Ecto.Query.where([e], e.action == ^action)
    |> Repo.all()
  end

  ## 1. The repair itself — the criterion this row was filed for

  describe "the operator verb repairs a site no sweep could reach" do
    test "a secretless content-bound site ends with a secret, a registered webhook and `present`" do
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      site = secretless_site(bp)

      # The precondition is the whole point: before the verb, this site is
      # OUTSIDE the hourly sweep's population and reports the absence.
      assert Registry.publish_trigger(site) == :absent
      assert Registry.list_content_webhook_sites() == []
      assert [site.id] == Enum.map(Registry.list_sites_missing_content_secret(), & &1.id)

      operator = operator_fixture()
      StudioLinkFakeHttpClient.program(box_listing([]))

      conn = mint_via_route(operator)
      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "swept" => 1,
               "minted" => 1,
               "registered" => 1,
               "skipped" => 0,
               "errored" => 0
             }

      reloaded = Repo.reload!(site)

      # (a) THE SECRET EXISTS, and it is the real thing — Vault-decryptable, not
      # a placeholder the receiver would reject.
      refute is_nil(reloaded.content_webhook_secret_encrypted)
      assert {:ok, secret} = Registry.reveal_site_content_secret(reloaded)
      assert is_binary(secret) and byte_size(secret) > 20

      # (b) THE WEBHOOK IS REGISTERED, under the name the receiver resolves by,
      # carrying the secret that was just minted.
      post = Enum.find(writes(:post), &String.contains?(&1.url, "/v1/webhooks/production"))
      assert post, "the mint must register the missing row inline, not an hour later"
      body = Jason.decode!(post.body)
      assert body["name"] == "site-autodeploy-#{site.id}"
      assert body["url"] =~ "/v1/sites/webhooks/content-publish/#{site.id}"
      assert body["secret"] == secret
      assert body["active"] == true

      # (c) AND THE SURFACE SAYS SO.
      assert Registry.publish_trigger(reloaded) == :present

      # (d) The act is on the record, with the operator's name on it.
      assert [event] = audit_rows("site.content_secret_minted")
      assert event.actor_user_id == operator.id
      assert event.target_type == "site"
      assert event.target_id == site.id
      assert event.team_id == site.team_id
      assert event.metadata["slug"] == site.slug
      assert event.metadata["dataset"] == "production"
    end

    test "running it twice mints nothing the second time" do
      # IDEMPOTENT BY POPULATION, not by a flag: the second call's query no
      # longer returns the site it just repaired. A mint that fired again would
      # rotate a live credential out from under the box row registered with the
      # first one — the site would go DEAD in a way the tally still called a
      # success.
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      site = secretless_site(bp)
      operator = operator_fixture()

      StudioLinkFakeHttpClient.program(box_listing([]))
      assert mint_via_route(operator).status == 200
      first = Repo.reload!(site).content_webhook_secret_encrypted
      assert length(writes(:post)) == 1

      StudioLinkFakeHttpClient.program(box_listing(["site-autodeploy-#{site.id}"]))
      conn = mint_via_route(operator)

      assert Jason.decode!(conn.resp_body) == %{
               "swept" => 0,
               "minted" => 0,
               "registered" => 0,
               "skipped" => 0,
               "errored" => 0
             }

      assert Repo.reload!(site).content_webhook_secret_encrypted == first,
             "a second run must never overwrite the secret the first one minted"

      assert writes(:post) == []
      assert writes(:put) == []
      assert length(audit_rows("site.content_secret_minted")) == 1
    end
  end

  ## 2. What it must NOT touch

  describe "the population the verb refuses" do
    test "a CONTAINER site is untouched — no secret, no write, still `not_applicable`" do
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      container = container_site(bp)
      operator = operator_fixture()

      StudioLinkFakeHttpClient.program(box_listing([]))
      conn = mint_via_route(operator)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["swept"] == 0

      reloaded = Repo.reload!(container)
      assert is_nil(reloaded.content_webhook_secret_encrypted)
      assert writes(:post) == []
      assert writes(:put) == []

      # NOT a fault and not repaired into one: a container binds no content
      # dataset, so no trigger is owed and minting it a credential would create a
      # live publish target for content that does not exist.
      assert Registry.publish_trigger(reloaded) == :not_applicable
      assert audit_rows("site.content_secret_minted") == []
      assert Registry.mint_content_publish_secret(reloaded) == :noop
    end

    test "a site that ALREADY has a secret keeps it byte for byte" do
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      site = bound_site(bp)
      before = site.content_webhook_secret_encrypted
      refute is_nil(before)

      StudioLinkFakeHttpClient.program(box_listing([]))
      assert Registry.mint_content_publish_secret(site) == :noop
      assert Repo.reload!(site).content_webhook_secret_encrypted == before
      assert writes(:post) == []
      assert audit_rows("site.content_secret_minted") == []
    end

    test "the two populations partition: no site is in both lists" do
      # `list_sites_missing_content_secret/1` claims to be the exact complement of
      # `list_content_webhook_sites/1` inside the content-bound population. A
      # site in both would be minted AND swept, and the sweep would race the mint
      # with the OLD secret.
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      _container = container_site(bp)
      have = bound_site(bp)
      missing = secretless_site(bp)

      swept = MapSet.new(Registry.list_content_webhook_sites(), & &1.id)
      minted = MapSet.new(Registry.list_sites_missing_content_secret(), & &1.id)

      assert MapSet.disjoint?(swept, minted)
      assert have.id in swept
      assert missing.id in minted
    end
  end

  ## 3. The tally is honest about a box it could not reach

  test "a site whose box is not live is `minted` but NOT `registered`" do
    # `registered` is a SUB-COUNT of `minted`, not a partition bucket, and this is
    # the case that makes the distinction load-bearing: the secret is written (so
    # the hourly reconciler can finally reach the site) while the box row does not
    # exist yet. Folding this into `registered` would report a working trigger for
    # a site nothing was ever registered on — the same false green the whole
    # repair exists to delete.
    bp = live_bp()
    StudioLinkFakeHttpClient.program([])
    site = secretless_site(bp)
    operator = operator_fixture()

    bp |> Ecto.Changeset.change(url: nil) |> Repo.update!()
    StudioLinkFakeHttpClient.program(box_listing([]))

    conn = mint_via_route(operator)
    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "swept" => 1,
             "minted" => 1,
             "registered" => 0,
             "skipped" => 0,
             "errored" => 0
           }

    assert writes(:post) == []
    reloaded = Repo.reload!(site)
    refute is_nil(reloaded.content_webhook_secret_encrypted)
    assert Registry.publish_trigger(reloaded) == :present

    # And the site is now INSIDE the hourly sweep's reach, which it was not before.
    assert reloaded.id in Enum.map(Registry.list_content_webhook_sites(), & &1.id)
  end

  ## 4. The door is the operator's, and it fails closed

  describe "the route is platform-operator gated" do
    test "no token → 401, and nothing is minted" do
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      site = secretless_site(bp)
      StudioLinkFakeHttpClient.program(box_listing([]))

      conn = mint_via_route(nil)
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "unauthorized"
      assert is_nil(Repo.reload!(site).content_webhook_secret_encrypted)
      assert writes(:post) == []
    end

    test "a plain (non-operator) session → 403, and nothing is minted" do
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      site = secretless_site(bp)
      user = plain_user_fixture()
      StudioLinkFakeHttpClient.program(box_listing([]))

      conn = mint_via_route(user)
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "forbidden"
      assert is_nil(Repo.reload!(site).content_webhook_secret_encrypted)
      assert writes(:post) == []
    end

    test "an operator on ANOTHER team still repairs the site — the verb is fleet-wide" do
      # Deliberate: the platform operator is cross-team by construction (the same
      # principal the fleet snapshot and the disarmed-box census answer to). A
      # team-scoped mint could not repair a fleet, which is the only job this
      # verb has.
      bp = live_bp()
      StudioLinkFakeHttpClient.program([])
      site = secretless_site(bp)
      operator = operator_fixture()
      refute operator.id == nil

      StudioLinkFakeHttpClient.program(box_listing([]))
      conn = mint_via_route(operator)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["minted"] == 1
      refute is_nil(Repo.reload!(site).content_webhook_secret_encrypted)

      # The audit row lands on the SITE's team, never the operator's — the
      # register is the site owner's history, not the operator's scratchpad.
      assert [event] = audit_rows("site.content_secret_minted")
      assert event.team_id == site.team_id
      assert event.actor_user_id == operator.id
    end
  end

  ## 5. The verb the schedule is NOT

  test "the hourly reconciler still never mints" do
    # The other half of the ruling, asserted rather than trusted: adding the mint
    # must not have widened the schedule. `reconcile_content_webhooks/1` sees the
    # secretless site as outside its population, exactly as before.
    bp = live_bp()
    StudioLinkFakeHttpClient.program([])
    site = secretless_site(bp)
    StudioLinkFakeHttpClient.program(box_listing([]))

    assert Registry.reconcile_content_webhooks() ==
             %{swept: 0, registered: 0, present: 0, skipped: 0, errored: 0}

    assert is_nil(Repo.reload!(site).content_webhook_secret_encrypted)
    assert writes(:post) == []
    assert Registry.publish_trigger(Repo.reload!(site)) == :absent
  end

  test "the mint and the create door use the SAME secret shape" do
    # The row's INVARIANT: "the path that mints the secret is the same one
    # create-time uses, so the webhook it registers is the one the receiver
    # expects". Both doors go through `new_content_secret/0`; this compares what
    # each produced, since a shape divergence would only show as a 401 on the
    # receiving route months later.
    bp = live_bp()
    StudioLinkFakeHttpClient.program([])
    created = bound_site(bp)
    repaired = secretless_site(bp)

    StudioLinkFakeHttpClient.program(box_listing([]))
    assert {:ok, %Site{} = repaired, _} = Registry.mint_content_publish_secret(repaired)

    assert {:ok, a} = Registry.reveal_site_content_secret(created)
    assert {:ok, b} = Registry.reveal_site_content_secret(repaired)

    assert byte_size(a) == byte_size(b)
    assert a =~ ~r/\A[A-Za-z0-9_-]+\z/
    assert b =~ ~r/\A[A-Za-z0-9_-]+\z/
    refute a == b
  end
end
