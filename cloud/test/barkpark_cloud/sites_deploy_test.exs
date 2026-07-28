defmodule BarkparkCloud.SitesDeployTest do
  @moduledoc """
  site-spawner D22/D30 — the STATIC deploy driver: mint a build, drive the box
  through PLAN → BUILD → STAGE → HEALTH → SWITCH → RETIRE, narrate every stage
  onto the row, and settle it live (or fail it honestly).

  The box is `Sites.FakeBoxRelay` — an in-memory instance. Nothing here touches a
  network, a shell, or npm, and yet every claim the product makes is exercised
  against real Postgres rows:

    * the six stages are CASed onto `stage` / `console` / `detail` as they happen,
      and the deployment ends `live` with the site's live pointer flipped;
    * a build that fails HEALTH NEVER switches — the site's live pointer does not
      move, so visitors keep the previous build (the whole point of a health gate);
    * the box is driven with the SCRUBBED env and the site's OWN read token;
    * a rollback blocks on the real flip and repoints the site, while a box that
      cannot roll back is reported as a failure, never as a success.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.{Deployment, Site, Vault}
  alias BarkparkCloud.Sites.Deploy
  alias BarkparkCloud.Sites.FakeBoxRelay
  alias BarkparkCloud.StudioLinkFakeHttpClient

  @instance_url "https://acme.barkpark.cloud"
  @read_token "bpt_public_read_xyz"

  ## Fixtures

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # A LIVE instance: url + encrypted admin token (what the provision-succeed path
  # writes). Without both, the control plane cannot drive anything on it.
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

  defp static_site(bp, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{
          name: "Blog #{n}",
          slug: "blog-#{n}",
          kind: "static",
          framework: "astro",
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production",
          read_token: @read_token
        })
      )

    site
  end

  defp setup_site do
    bp = team_fixture() |> live_barkpark()
    {bp, static_site(bp)}
  end

  defp all_stages, do: Deploy.stages()

  ## ---------------------------------------------------------------------------

  describe "enqueue/2" do
    test "mints a build_id + content_rev, and a repeat build of the same code+content+config is a no-op" do
      {bp, site} = setup_site()

      assert {:ok, %Deployment{} = d} = Deploy.enqueue(site, bp)
      assert d.status == "queued"
      assert is_binary(d.build_id) and byte_size(d.build_id) == 16
      assert is_binary(d.content_rev)

      # The SAME code + content + config hashes to the same build_id, which the
      # (site_id, build_id) unique index turns into a no-op — the DB backstop
      # behind the script's PLAN "already live, nothing to do" exit.
      assert {:duplicate, existing} = Deploy.enqueue(site, bp)
      assert existing.id == d.id
      assert length(Registry.list_deployments(site, 10)) == 1
    end

    test "a different dataset binding is a different build" do
      {bp, site} = setup_site()
      {:ok, d1} = Deploy.enqueue(site, bp)

      other = static_site(bp, %{bootstrap_dataset: "staging"})
      {:ok, d2} = Deploy.enqueue(other, bp)

      refute d1.build_id == d2.build_id
    end

    # charter D36 — the force nonce. Without it a re-deploy of UNCHANGED content
    # returns the cached duplicate (the no-op above) and can never re-run: a
    # genuinely-new build is impossible. `force: true` folds a nonce into the
    # build_id so a brand-new releases/<build_id>/ is minted, WITHOUT changing the
    # default (no-op) path — the two live side by side.
    test "force: true mints a NEW build on unchanged content, while the default path stays a no-op" do
      {bp, site} = setup_site()

      assert {:ok, d1} = Deploy.enqueue(site, bp)
      # The tripwire: same code+content+config is STILL a no-op by default.
      assert {:duplicate, ^d1} = Deploy.enqueue(site, bp)

      # …but a forced deploy of that same content is a real, distinct build.
      assert {:ok, forced} = Deploy.enqueue(site, bp, true)
      refute forced.id == d1.id
      refute forced.build_id == d1.build_id
      assert byte_size(forced.build_id) == 16
      assert length(Registry.list_deployments(site, 10)) == 2

      # Two forced deploys are each distinct too (a fresh nonce every time) — so a
      # rollback proof can stand up two live builds to flip between.
      assert {:ok, forced2} = Deploy.enqueue(site, bp, true)
      refute forced2.build_id == forced.build_id
    end
  end

  # ssw8 — WHAT the content revision is derived from, and what it says when it
  # could not be read.
  #
  # The revision used to be sha256 of the WHOLE analytics body, whose
  # `recent_activity` is the last 50 mutation events for the entire dataset —
  # every type, drafts included. A site bound to one doc_type therefore got a
  # fresh rev, a fresh build_id and a full rebuild of byte-identical output every
  # time an unrelated type churned or anyone saved a draft. And when the read
  # FAILED it minted a random `"u" <> hex` marker that was shipped to the box,
  # baked into `<meta name="bp-content-rev">` and then asserted EQUAL by HEALTH —
  # a green certified by comparing an invented value to itself.
  describe "content_rev — published + type-scoped, honest when unreadable" do
    @analytics_path "/w/acme/p/blog/v1/data/analytics/production"

    defp analytics(fields) do
      body =
        %{
          "dataset" => "production",
          "total_documents" => 3,
          "types" => [%{"type" => "post", "total" => 3, "published" => 2, "drafts" => 1}],
          "recent_activity" => []
        }
        |> Map.merge(Map.new(fields, fn {k, v} -> {to_string(k), v} end))

      {:ok, %{status: 200, body: Jason.encode!(body)}}
    end

    defp event(id, type, doc_id, mutation, ts) do
      %{"id" => id, "type" => type, "doc_id" => doc_id, "mutation" => mutation, "timestamp" => ts}
    end

    defp program_analytics(response),
      do: StudioLinkFakeHttpClient.program(%{@analytics_path => response})

    test "draft churn and other types do NOT move the revision — the no-op survives a live dataset" do
      {bp, site} = setup_site()

      program_analytics(
        analytics(
          recent_activity: [
            event("e1", "post", "hello", "createOrReplace", "2026-07-28T10:00:00Z")
          ]
        )
      )

      assert {:ok, d1} = Deploy.enqueue(site, bp)

      # The SAME published content, on a dataset that has since churned: a draft
      # of the bound type was saved, an unrelated `task` was closed, the totals
      # and the draft counts moved with them. Nothing the site PUBLISHES changed.
      program_analytics(
        analytics(
          total_documents: 5,
          types: [
            %{"type" => "post", "total" => 4, "published" => 2, "drafts" => 2},
            %{"type" => "task", "total" => 1, "published" => 1, "drafts" => 0}
          ],
          recent_activity: [
            event("e3", "task", "t-1", "patch", "2026-07-28T10:02:00Z"),
            event("e2", "post", "drafts.hello", "createOrReplace", "2026-07-28T10:01:00Z"),
            event("e1", "post", "hello", "createOrReplace", "2026-07-28T10:00:00Z")
          ]
        )
      )

      assert {:duplicate, ^d1} = Deploy.enqueue(site, bp),
             "a draft-only / other-type mutation must not mint a new build of byte-identical output"

      assert length(Registry.list_deployments(site, 10)) == 1
    end

    test "a real PUBLISHED change to the bound type DOES move the revision — the fix is not a constant" do
      {bp, site} = setup_site()

      program_analytics(
        analytics(
          recent_activity: [
            event("e1", "post", "hello", "createOrReplace", "2026-07-28T10:00:00Z")
          ]
        )
      )

      assert {:ok, d1} = Deploy.enqueue(site, bp)

      # A published post is edited: same count, a new published event of the bound
      # type. The site's output really does change, so the build must.
      program_analytics(
        analytics(
          recent_activity: [
            event("e2", "post", "hello", "createOrReplace", "2026-07-28T10:05:00Z"),
            event("e1", "post", "hello", "createOrReplace", "2026-07-28T10:00:00Z")
          ]
        )
      )

      assert {:ok, d2} = Deploy.enqueue(site, bp)
      refute d2.content_rev == d1.content_rev
      refute d2.build_id == d1.build_id

      # …and so does a brand-new published document of the bound type, even if the
      # activity window has rolled past every event.
      program_analytics(
        analytics(
          types: [%{"type" => "post", "total" => 4, "published" => 3, "drafts" => 1}],
          recent_activity: []
        )
      )

      assert {:ok, d3} = Deploy.enqueue(site, bp)
      refute d3.content_rev in [d1.content_rev, d2.content_rev]
    end

    test "an UNREADABLE box ships an EMPTY content_rev — never a fabricated one — and still rebuilds" do
      {bp, site} = setup_site()

      program_analytics({:ok, %{status: 502, body: "upstream down"}})

      assert {:ok, d1} = Deploy.enqueue(site, bp)

      # The honesty claim: nothing invented. An empty CONTENT_REV is what routes
      # deploy/site-deploy.sh into its "no CONTENT_REV supplied — asserting
      # bp-content-rev is non-empty only" branch, instead of cross-checking a
      # random value against itself. (Ecto's cast stores the empty string as NULL,
      # and the box's DeployRequest maps `nil` and `""` to the same "not supplied"
      # — so both spellings of empty are the honest branch, and neither is a value.)
      assert d1.content_rev in [nil, ""]

      refute String.starts_with?(d1.content_rev || "", "u"),
             "the fail-open must not mint a 'u'+hex marker that nothing in the repo can detect"

      # …and that emptiness is what the BOX is handed — the post-condition read,
      # not an assumption about the row.
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(all_stages())])
      assert {:ok, :live} = Deploy.run(d1.id)
      assert [{:start_deploy, payload} | _] = FakeBoxRelay.calls()
      assert payload.content_rev in [nil, ""]

      # …and the unknown revision must NOT dedupe: a constant rev would collapse
      # every re-deploy of a sick box into the (site_id, build_id) no-op and serve
      # stale content forever.
      assert {:ok, d2} = Deploy.enqueue(site, bp)
      refute d2.build_id == d1.build_id
      assert d2.content_rev in [nil, ""]
    end

    test "the probe reports :error (not a value) when the box cannot be read" do
      {bp, site} = setup_site()

      program_analytics({:ok, %{status: 502, body: "upstream down"}})
      assert Deploy.content_rev_probe(site, bp) == :error

      program_analytics(analytics([]))
      assert {:ok, rev} = Deploy.content_rev_probe(site, bp)
      assert byte_size(rev) == 12
    end
  end

  describe "run/1 — the six-stage walk" do
    test "walks PLAN..RETIRE, persists each stage, and settles live with the site pointer flipped" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      # The box reports the stages as it finishes them — three polls, the way a
      # real build lands: plan+build, then stage+health, then the switch.
      FakeBoxRelay.program(
        polls: [
          FakeBoxRelay.walk(~w(PLAN BUILD)),
          FakeBoxRelay.walk(~w(PLAN BUILD STAGE HEALTH)),
          FakeBoxRelay.walk(all_stages(), url: "#{@instance_url}/sites/#{site.slug}/")
        ]
      )

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "live"
      assert final.stage == "RETIRE"
      assert final.became_live_at
      assert final.detail =~ "live at"

      # Every one of the six stages was CASed onto the row as it happened — the
      # console is the narration, and `stages/1` folds it back into the bar.
      stages = Deploy.stages(final)
      assert Enum.map(stages, & &1.name) == all_stages()

      assert Enum.all?(stages, &(&1.status == "done")),
             "expected every stage done, got #{inspect(Enum.map(stages, &{&1.name, &1.status}))}"

      # The site now serves this build.
      assert Repo.get(Site, site.id).current_deployment_id == d.id
    end

    # site-spawner W4 (charter D15-D17): every stage transition PUSHES a
    # `site.deploy.stage` SSE event the moment it is CAS'd — the console's live
    # rail advances without polling. Coarse-by-design: the payload names WHICH
    # deployment reached WHICH stage; the dashboard folds the whole set, so a
    # missed/duplicated event is harmless. The terminal `deployments` tick still
    # fires at settle (asserted by its presence in the mailbox alongside).
    test "broadcasts a site.deploy.stage event per stage, then the terminal deployments tick" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      # Subscribe THIS process to the site's team group BEFORE the driver runs —
      # Deploy.run/1 is synchronous here (NoopStarter), so every broadcast lands
      # in this mailbox.
      :ok = BarkparkCloud.Events.subscribe(site.team_id)

      FakeBoxRelay.program(
        polls: [FakeBoxRelay.walk(all_stages(), url: "#{@instance_url}/sites/#{site.slug}/")]
      )

      assert {:ok, :live} = Deploy.run(d.id)

      # Each of the six stages pushed one event, carrying this deployment's id and
      # the stage's name — the exact payload the console rail folds.
      for stage <- all_stages() do
        assert_receive {:bpcloud_event,
                        %{
                          type: "site.deploy.stage",
                          payload:
                            %{deployment_id: dep_id, stage: ^stage, status: "done"} = payload
                        }}

        assert dep_id == d.id
        assert payload.site_id == site.id
        assert payload.slug == site.slug
      end

      # …and the coarse terminal tick still fires so a tab with no rail open (a
      # sites LIST) still invalidates.
      assert_receive {:bpcloud_event, %{type: "deployments"}}
    end

    test "the box is driven with the site's OWN read token over the SCOPED route, and the build env is exactly the allow-list" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(all_stages())])

      assert {:ok, :live} = Deploy.run(d.id)

      assert [{:start_deploy, payload} | _] = FakeBoxRelay.calls()
      assert payload.slug == site.slug
      assert payload.build_id == d.build_id
      assert payload.mode == "deploy"

      env = payload.env
      # The token is the SITE's public-read token — not the instance admin token,
      # and not an ambient BARKPARK_TOKEN (charter D6/D7).
      assert env[:BARKPARK_TOKEN] == @read_token
      # Scoped route: tenant-membership isolation (the flat route would let the
      # token's default workspace decide which content it sees).
      assert env[:BARKPARK_API_URL] == "#{@instance_url}/w/acme/p/blog"
      assert env[:BARKPARK_DATASET] == "production"
      assert env[:BARKPARK_SITE_BASE] == "/sites/#{site.slug}/"
      # charter D35: the content type the build's flagship fetch reads — the
      # canonical default "post" when the site was created without --doc-type.
      assert env[:BARKPARK_DOC_TYPE] == "post"
      # search-template D7: the template-slug axis rides the payload, derived
      # from framework (this site is astro → astro-starter).
      assert payload.template == "astro-starter"
    end

    # charter D35 — DOC_TYPE end-to-end. A site created with `doc_type: "paper"`
    # drives the box with BARKPARK_DOC_TYPE=paper, so a real Astro build reads
    # papers (100 docs on guerrilla) instead of the default "post" (0 docs there,
    # which hard-fails the build). Proves the per-site type reaches argv.
    test "a site bound to doc_type=paper drives the box with BARKPARK_DOC_TYPE=paper" do
      bp = team_fixture() |> live_barkpark()
      site = static_site(bp, %{doc_type: "paper"})
      assert site.doc_type == "paper"

      {:ok, d} = Deploy.enqueue(site, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(all_stages())])

      assert {:ok, :live} = Deploy.run(d.id)

      assert [{:start_deploy, payload} | _] = FakeBoxRelay.calls()
      assert payload.env[:BARKPARK_DOC_TYPE] == "paper"
    end

    # search-template W2 (charter D8) — an EXPLICIT Site.template wins over the
    # framework-derived default: a nextjs site created with template
    # "search-starter" drives the box's Provisioner with the flagship tree, not
    # next-starter. A nil template stays framework-derived (asserted above).
    test "a site with an explicit template drives the box with THAT starter" do
      bp = team_fixture() |> live_barkpark()
      site = static_site(bp, %{template: "search-starter"})
      assert site.template == "search-starter"

      {:ok, d} = Deploy.enqueue(site, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(all_stages())])

      assert {:ok, :live} = Deploy.run(d.id)

      assert [{:start_deploy, payload} | _] = FakeBoxRelay.calls()
      assert payload.template == "search-starter"
    end

    # search-template W6 — the deploy-pinned palette rides the env only when the
    # row pins one; nil deploys byte-identical (no BARKPARK_THEME key at all).
    test "a site with a pinned theme drives the box with BARKPARK_THEME" do
      bp = team_fixture() |> live_barkpark()
      site = static_site(bp, %{theme: "ember"})
      assert site.theme == "ember"

      {:ok, d} = Deploy.enqueue(site, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(all_stages())])
      assert {:ok, :live} = Deploy.run(d.id)

      assert [{:start_deploy, payload} | _] = FakeBoxRelay.calls()
      assert payload.env[:BARKPARK_THEME] == "ember"
    end

    test "a themeless site carries NO BARKPARK_THEME key (byte-identical env)" do
      {bp, site} = setup_site()
      assert site.theme == nil

      {:ok, d} = Deploy.enqueue(site, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(all_stages())])
      assert {:ok, :live} = Deploy.run(d.id)

      assert [{:start_deploy, payload} | _] = FakeBoxRelay.calls()
      refute Map.has_key?(payload.env, :BARKPARK_THEME)
    end

    test "an unknown theme is rejected at create" do
      bp = team_fixture() |> live_barkpark()

      assert {:error, cs} =
               Registry.create_site(bp, %{
                 name: "vaporwave",
                 slug: "vaporwave",
                 kind: "static",
                 framework: "astro",
                 theme: "vaporwave"
               })

      assert {"must be one of: charple, ember, evergreen, fjord", _} = cs.errors[:theme]
    end

    test "an unknown template is rejected at create — never discovered on the box" do
      bp = team_fixture() |> live_barkpark()

      assert {:error, cs} =
               Registry.create_site(bp, %{
                 name: "evil",
                 slug: "evil",
                 kind: "static",
                 framework: "astro",
                 template: "../../etc"
               })

      assert {"must be one of: astro-search-starter, astro-starter, next-starter, search-starter",
              _} =
               cs.errors[:template]
    end

    # charter D37 — a nil/undecryptable read token FAILS CLOSED. The build fetches
    # over the scoped route with this token; a nil one would build UNAUTHENTICATED
    # (empty content, an empty bp-doc-id marker, a false-green live page). So the
    # driver refuses BEFORE touching the box: the deployment settles failed with an
    # honest reason and start_deploy is never called.
    test "a site whose read token is missing settles failed and never touches the box" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      # Simulate a row whose token was never stored / cannot be revealed.
      site
      |> Ecto.Changeset.change(read_token_encrypted: nil)
      |> Repo.update!()

      assert {:ok, :failed} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "failed"
      assert final.failure_reason =~ "read token"

      # The box was NEVER driven — no build ran unauthenticated.
      assert FakeBoxRelay.calls() == []
      # …and the site's live pointer never moved.
      assert is_nil(Repo.get(Site, site.id).current_deployment_id)
    end

    test "a build that fails HEALTH never switches — the live pointer does not move" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        polls: [
          FakeBoxRelay.failed_at(
            "HEALTH",
            "health probe returned 500 — bp-build-id marker missing"
          )
        ]
      )

      assert {:ok, :failed} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "failed"
      assert final.failure_reason =~ "health probe returned 500"
      assert final.stage == "HEALTH"

      # THE promise of a health gate: SWITCH never ran, so visitors never saw this
      # build. The site's live pointer is untouched.
      stages = Deploy.stages(final)
      by_name = Map.new(stages, &{&1.name, &1.status})
      assert by_name["BUILD"] == "done"
      assert by_name["HEALTH"] == "failed"
      assert by_name["SWITCH"] == "skipped"
      assert by_name["RETIRE"] == "skipped"

      assert is_nil(Repo.get(Site, site.id).current_deployment_id)
    end

    test "an unreachable box fails the row with an honest reason, never a silent hang" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(start: {:error, :instance_error})

      assert {:ok, :failed} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "failed"
      assert final.failure_reason =~ "unreachable"
      assert final.failure_reason =~ bp.slug
    end

    test "the box's own refusal travels intact (never a generic 'deploy failed')" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(start: {:ok, 409, %{"error" => "a deploy is already running"}})

      assert {:ok, :failed} = Deploy.run(d.id)
      assert Repo.get(Deployment, d.id).failure_reason =~ "a deploy is already running"
    end

    test "the driver CLAIMS the row and heartbeats it, so the stale reaper can still recover an orphan" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)
      assert d.claim_epoch == 0

      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(all_stages())])
      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      # The row carries a claim + a bumped epoch + a fresh lease — the same shape
      # the off-box builder leaves behind, which is exactly what makes an orphaned
      # in-flight row visible (and sweepable) to the StaleDeploymentReaper rather
      # than a lost in-BEAM Task.
      assert final.claim_epoch == 1
      assert is_binary(final.claim_worker)
      assert final.claimed_at
    end

    test "a poll stream that never finishes fails the row rather than spinning forever" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      # The box keeps saying "running" — test config caps the driver at 10 polls.
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(~w(PLAN BUILD))])

      assert {:ok, :failed} = Deploy.run(d.id)
      assert Repo.get(Deployment, d.id).failure_reason =~ "did not finish in time"
    end

    # stw6 (charter D-restart-grace) — THE grenade this slice defuses. On busy
    # days an api/** merge auto-deploys the box and the post-merge restart bounces
    # `barkpark.service` mid-build, so a poll or two comes back {:error, _} (the box
    # is briefly unreachable) BEFORE the surviving on-box build finishes. The loop
    # used to fail the row on the FIRST such blip — and a failed row is
    # unresurrectable, so the build could never settle live. With the restart-grace,
    # a bounded run of unreachable polls is tolerated: the box comes back, the walk
    # completes, and the row settles LIVE.
    test "a restart-shaped error gap followed by a real success settles the row live" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      # Test grace budget is 3; two unreachable polls (< grace) then the box is
      # back and walks all the way to succeeded.
      FakeBoxRelay.program(
        polls: [
          {:error, :instance_error},
          {:error, :instance_error},
          FakeBoxRelay.walk(all_stages(), url: "#{@instance_url}/sites/#{site.slug}/")
        ]
      )

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "live"
      assert final.stage == "RETIRE"
      assert Repo.get(Site, site.id).current_deployment_id == d.id
    end

    # The other side of the same coin: a GENUINELY dead box (never reachable again)
    # must still fail honestly — the grace is bounded, not infinite. grace+1
    # consecutive unreachable polls exhaust the budget and the row fails with the
    # box's own unreachable reason, exactly as it did before the grace existed.
    test "a box that stays unreachable past the grace budget still fails honestly" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      # Every poll is unreachable and the last reply repeats, so the loop only ever
      # sees {:error, _} — grace (3) is spent, the 4th error fails the row.
      FakeBoxRelay.program(polls: [{:error, :instance_error}])

      assert {:ok, :failed} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "failed"
      # The honest unreachable reason — NOT a "did not finish in time" build-budget
      # timeout: the build budget (`left`) was never spent on the blips.
      assert final.failure_reason =~ "unreachable"
      assert final.failure_reason =~ bp.slug
      # The live pointer never moved — a dead box ships nothing.
      assert is_nil(Repo.get(Site, site.id).current_deployment_id)
    end

    # The grace budget is SEPARATE from the build budget AND resets on every poll
    # that reaches the box. Two bursts of 2 errors (4 total > grace 3) would exhaust
    # a shared/non-resetting budget — but a single good poll BETWEEN them refreshes
    # the grace, so the deploy survives both restarts and settles live.
    test "a reachable poll between two error bursts refreshes the grace budget" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        polls: [
          {:error, :instance_error},
          {:error, :instance_error},
          # A reachable, still-running poll — this is what resets grace to full.
          FakeBoxRelay.walk(~w(PLAN BUILD)),
          {:error, :instance_error},
          {:error, :instance_error},
          FakeBoxRelay.walk(all_stages(), url: "#{@instance_url}/sites/#{site.slug}/")
        ]
      )

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "live"
      assert Repo.get(Site, site.id).current_deployment_id == d.id
    end
  end

  describe "rollback/2 — the sub-second symlink flip (charter D5)" do
    test "blocks on the real flip, then repoints the site at the build that is now live" do
      {bp, site} = setup_site()

      # Two builds: the previous good one, and the one currently live.
      {:ok, prev} = Registry.create_deployment(site, %{build_id: "prevbuild0000001"})
      {:ok, live} = Registry.create_deployment(site, %{build_id: "livebuild0000001"})
      {:ok, site} = Registry.set_site_current_deployment(site, live.id)

      # The box confirms it repointed `current` at the previous release.
      FakeBoxRelay.program(
        rollback: {:ok, 200, %{"status" => "rolled_back", "build_id" => "prevbuild0000001"}}
      )

      assert {:ok, result} = Deploy.rollback(site, bp)
      assert result.deployment_id == prev.id
      assert result.previous_deployment_id == live.id
      assert result.url == "#{@instance_url}/sites/#{site.slug}/"

      # The control plane's view agrees with the box IMMEDIATELY — no window where
      # `bp cloud site status` names the build it just rolled away from.
      assert Repo.get(Site, site.id).current_deployment_id == prev.id

      # It invoked --rollback, NOT a promote (a new build).
      assert [{:rollback, payload}] = FakeBoxRelay.calls()
      assert payload.mode == "rollback"
      assert payload.slug == site.slug
    end

    test "a box with no previous release is a FAILURE, not a cheerful no-op" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(rollback: {:ok, 422, %{"error" => "no_previous"}})

      assert {:error, status, detail} = Deploy.rollback(site, bp)
      # Non-2xx is load-bearing: the CLI gates success on the HTTP status ALONE.
      refute status in 200..299
      assert detail =~ "no previous build"
    end

    test "a deploy holding the box's lock answers 409, in plain words" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(rollback: {:ok, 409, %{"error" => "lock_held"}})

      assert {:error, 409, detail} = Deploy.rollback(site, bp)
      assert detail =~ "deploy is running"
    end

    test "an unreachable box is a 502, never a 200" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(rollback: {:error, :instance_error})

      assert {:error, 502, detail} = Deploy.rollback(site, bp)
      assert detail =~ "unreachable"
    end
  end

  describe "normalize_report/1 — tolerating whatever the box says" do
    test "parses site-deploy.sh's own log lines when no structured stages are reported" do
      report =
        Deploy.normalize_report(%{
          "console" => [
            "[site-deploy 09:12:01] PLAN: deploy 'blog' build abc (live now: none)",
            "[site-deploy 09:12:40] BUILD: npm ci && npm run build in /opt/.../src",
            "[site-deploy 09:12:59] HEALTH failed for 'blog' — marker missing"
          ]
        })

      assert report.state == :failed
      by_name = Map.new(report.stages, &{&1.name, &1.status})
      assert by_name["PLAN"] == "done"
      assert by_name["HEALTH"] == "failed"
    end

    test "maps ok/passed/complete onto the ONLY three words the CLI renders" do
      report =
        Deploy.normalize_report(%{
          "state" => "running",
          "stages" => [
            %{"name" => "PLAN", "status" => "ok"},
            %{"name" => "BUILD", "status" => "passed"},
            %{"name" => "STAGE", "status" => "complete"}
          ]
        })

      # `ok` / `passed` / `complete` all print NOTHING in the CLI's stream — a
      # blank six-stage bar with no error anywhere. They are mapped, not trusted.
      assert Enum.map(report.stages, & &1.status) == ["done", "done", "done"]
    end

    # THE FALSE GREEN. The instance's `state` is a RUN LIFECYCLE (idle|running|
    # done) mirroring SelfUpdateController — `done` means "the process exited",
    # not "the deploy worked". The verdict is exit_code / failure_reason. Reading
    # `done` as success settled a build that died at HEALTH as LIVE: the box
    # refused to switch (so visitors were safe), but the control plane flipped
    # current_deployment_id and `bp cloud site` printed a success line and a URL
    # for a build that never shipped. Failure signals must beat the lifecycle word.
    test "state:done with a non-zero exit_code is FAILED, never succeeded" do
      report =
        Deploy.normalize_report(%{
          "state" => "done",
          "exit_code" => 14,
          "failure_reason" => "HEALTH gate failed (exit 14): bp-content-rev marker is empty",
          "stages" => [
            %{"name" => "PLAN", "status" => "ok"},
            %{"name" => "BUILD", "status" => "ok"},
            %{"name" => "STAGE", "status" => "ok"},
            %{"name" => "HEALTH", "status" => "failed", "detail" => "bp-content-rev is empty"}
          ]
        })

      assert report.state == :failed
      assert report.failure_reason =~ "bp-content-rev marker is empty"
      # …and no SWITCH ever happened, so nothing a visitor sees moved.
      refute Enum.any?(report.stages, &(&1.name == "SWITCH"))
    end

    test "state:done with a failed stage is FAILED even with no exit_code" do
      report =
        Deploy.normalize_report(%{
          "state" => "done",
          "stages" => [
            %{"name" => "BUILD", "status" => "failed", "detail" => "401 Unauthorized"}
          ]
        })

      assert report.state == :failed
    end

    test "state:done with exit_code 0 and no failure is still SUCCEEDED" do
      report =
        Deploy.normalize_report(%{
          "state" => "done",
          "exit_code" => 0,
          "stages" => Enum.map(Deploy.stages(), &%{"name" => &1, "status" => "ok"})
        })

      assert report.state == :succeeded
    end

    # The engine's real marker is key=value. The prose fallback below it could
    # never have matched it, so the documented "tolerates the BPSTAGE marker"
    # was untrue — and a mis-parsed status is a blank stage bar.
    test "parses the engine's REAL key=value BPSTAGE marker, detail and all" do
      report =
        Deploy.normalize_report(%{
          "console" => [
            ~s(BPSTAGE name=PLAN status=noop build_id=b1 detail="nothing to do"),
            ~s(BPSTAGE name=BUILD status=failed build_id=b1 detail="FATAL: 401 Unauthorized")
          ]
        })

      assert report.state == :failed
      by_name = Map.new(report.stages, &{&1.name, {&1.status, &1.detail}})
      # `noop` is a skip, not a failure — inferring from prose would have read
      # "nothing to do" and guessed.
      assert by_name["PLAN"] == {"skipped", "nothing to do"}
      assert by_name["BUILD"] == {"failed", "FATAL: 401 Unauthorized"}
    end
  end

  # ---------------------------------------------------------------------------
  # BoxRelay.HTTP — the REAL wire, not the in-memory fake.
  #
  # Every other rollback test here drives FakeBoxRelay, whose default reply is a
  # SYNCHRONOUS {:ok, 200, %{"status" => "rolled_back"}} — a shape the real box
  # never sends. The real /v1/admin/site-deploy is ASYNCHRONOUS: it answers 202
  # `started` and runs the engine behind a Port. A relay that returned on the 202
  # would report a successful rollback for a symlink that had not moved, and the
  # "sub-second rollback" the product promises would be timing the ACCEPT, not the
  # FLIP. These tests drive the actual HTTP impl over the fake transport.
  #
  # They call `BoxRelay.HTTP.rollback/2` DIRECTLY — never `BoxRelay.rollback/2`
  # after swapping `:site_box_relay`. Application env is one GLOBAL shared by the
  # whole node, so in an `async: true` module that swap points EVERY concurrently
  # running test at the real HTTP relay for as long as this describe runs: a
  # `Sites.Deploy.run/1` over in `router_sites_test.exs` then talks to a fake
  # transport nobody programmed for it and settles `{:ok, :failed}`. That was the
  # order-dependent red on the required Cloud gate (GR47). The dispatcher is one
  # `impl().rollback(...)` hop with no logic of its own, so naming the impl
  # directly tests strictly MORE than the swap did, and isolates by construction.
  # ---------------------------------------------------------------------------
  describe "BoxRelay.HTTP.rollback/2 — answers only once the box has really flipped" do
    test "POLLS past the async 202 and reports the build that is NOW live" do
      bp = team_fixture() |> live_barkpark()

      StudioLinkFakeHttpClient.program([
        {:ok,
         %{status: 202, body: Jason.encode!(%{"ok" => true, "status" => %{"state" => "running"}})}},
        {:ok, %{status: 200, body: Jason.encode!(%{"state" => "running", "exit_code" => nil})}},
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "state" => "done",
               "exit_code" => 0,
               "log" => ["[site-deploy] rolling back", "TARGET_BUILD=b-prev"]
             })
         }}
      ])

      assert {:ok, 200, body} =
               BarkparkCloud.Sites.BoxRelay.HTTP.rollback(bp, %{mode: "rollback", slug: "blog"})

      assert body["status"] == "rolled_back"
      # THE point: the previous build's id, scraped from the box's own stream. A
      # 202 body carries no build_id at all, so a relay that answered on the accept
      # could only ever have reported nil here.
      assert body["build_id"] == "b-prev"
    end

    test "a box that CANNOT roll back is a refusal, never a success" do
      bp = team_fixture() |> live_barkpark()

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 202, body: Jason.encode!(%{"ok" => true})}},
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "state" => "done",
               "exit_code" => 21,
               "failure_reason" => "rollback: no previous release (exit 21)"
             })
         }}
      ])

      assert {:ok, 422, body} =
               BarkparkCloud.Sites.BoxRelay.HTTP.rollback(bp, %{mode: "rollback", slug: "blog"})

      assert body["error"] =~ "no previous release"
    end

    test "a 409 from the box (a deploy is in flight) is relayed verbatim, never polled" do
      bp = team_fixture() |> live_barkpark()

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 409, body: Jason.encode!(%{"error" => %{"code" => "already_running"}})}}
      ])

      assert {:ok, 409, _body} =
               BarkparkCloud.Sites.BoxRelay.HTTP.rollback(bp, %{mode: "rollback", slug: "blog"})
    end
  end

  describe "teardown/2 — the inverse of a spawn (site delete, box half)" do
    test "returns :ok and sends mode=teardown + the site slug when the box confirms" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      assert :ok = Deploy.teardown(site, bp)

      assert [{:teardown, payload}] = FakeBoxRelay.calls()
      assert payload.mode == "teardown"
      assert payload.slug == site.slug
      # A static site tears down with the symlink engine.
      assert payload.runtime_target == "static"
    end

    test "a node site tears down with runtime_target=node (the slot-stopping engine)" do
      bp = team_fixture() |> live_barkpark()
      site = static_site(bp, %{kind: "node", framework: "nextjs"})
      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      assert :ok = Deploy.teardown(site, bp)
      assert [{:teardown, payload}] = FakeBoxRelay.calls()
      assert payload.runtime_target == "node"
    end

    test "a box that could not tear the site down is a FAILURE (non-2xx), never a false :ok" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        teardown: {:ok, 422, %{"error" => "caddy validate rejected the disarm"}}
      )

      assert {:error, status, detail} = Deploy.teardown(site, bp)
      refute status in 200..299
      assert is_binary(detail)
    end
  end
end
