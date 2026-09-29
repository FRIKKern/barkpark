# dr-w32 S5. The abandonment backfill is a MIGRATION, and migrations live outside
# the compiled app's load path — so it is required HERE, before this file
# compiles, rather than in a setup block: the tests call its own statement
# builders, and a runtime-only load would leave those calls compiling against an
# unknown module.
unless Code.ensure_loaded?(BarkparkCloud.Repo.Migrations.BackfillAbandonmentDeferralStructure) do
  Code.require_file(
    Path.expand(
      "../../priv/repo/migrations/20260809180000_backfill_abandonment_deferral_structure.exs",
      __DIR__
    )
  )
end

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

  alias BarkparkCloud.{Accounts, DeployLedger, Registry}
  alias BarkparkCloud.BoxCapacityRefusalFixture
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

  # THE POOL BLIP, byte-for-byte. A `DBConnection.ConnectionError` on the deploy
  # door's auth plug never reaches `action_fallback` — Phoenix's RenderErrors
  # layer renders it through `BarkparkWeb.ErrorJSON`, which collapses ANY
  # unhandled fault to the UNTYPED `internal_error / "unknown error"` envelope
  # (`Barkpark.Content.Errors`), request_id stamped from Logger metadata. It is
  # the shape a transient answer has, and the only 5xx shape that earns grace.
  defp crash_500(request_id \\ "F9-pool-blip") do
    {:ok, 500,
     %{
       "error" => %{
         "code" => "internal_error",
         "message" => "unknown error",
         "request_id" => request_id
       }
     }}
  end

  # THE SECOND AUTHORLESS SHAPE (dr-w8-s2). The box's door emits this when its
  # DeployRunner did not answer the trigger inside the call budget — busy or
  # wedged, not a verdict about this build. It used to arrive wearing
  # `feature_not_configured`, a TYPED refusal, and was therefore terminal on the
  # first beat: 207 rows in 24h spent a whole build on a box that was merely slow
  # (and, worse, often on a build that was ALREADY RUNNING behind the answer).
  defp runner_unavailable_503(request_id \\ "F9-runner-wedged") do
    {:ok, 503,
     %{
       "error" => %{
         "code" => "deploy_runner_unavailable",
         "message" => "the deploy runner did not answer in time",
         "request_id" => request_id
       }
     }}
  end

  # Move a row out of the ACTIVE set. deploy-truth W1 re-keyed the active-
  # deployment index onto (site_id, environment), so at most ONE queued/building/
  # pushing production build per site can exist — a test that wants a second one
  # must settle the first, exactly as the fleet does.
  defp settle(%Deployment{} = d) do
    {:ok, settled} = Registry.transition_deployment(d, %{status: "failed"})
    settled
  end

  # The debounced rebuild a deferral promises — a REAL Oban row, not a log line.
  defp pending_auto_deploy_jobs(site_id) do
    Repo.all(
      from(j in Oban.Job,
        where:
          j.worker == "BarkparkCloud.Sites.AutoDeployWorker" and
            fragment("?->>'site_id' = ?", j.args, ^site_id) and
            j.state in ["available", "scheduled"]
      )
    )
  end

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

      # …but a forced deploy of that same content is a real, distinct build once
      # the previous one is no longer in flight. (deploy-truth W1: settling d1 is
      # required now that at most ONE active build per site can exist — see the
      # active-index describe below.)
      settle(d1)
      assert {:ok, forced} = Deploy.enqueue(site, bp, true)
      refute forced.id == d1.id
      refute forced.build_id == d1.build_id
      assert byte_size(forced.build_id) == 16
      assert length(Registry.list_deployments(site, 10)) == 2

      # Two forced deploys are each distinct too (a fresh nonce every time) — so a
      # rollback proof can stand up two live builds to flip between.
      settle(forced)
      assert {:ok, forced2} = Deploy.enqueue(site, bp, true)
      refute forced2.build_id == forced.build_id
    end
  end

  # deploy-truth W1 (charter D10) — THE DEDUP INDEX, WHICH HAD NEVER RUN.
  #
  # `deployments_active_site_ref_index` was UNIQUE (site_id, git_ref) over the
  # active statuses. On production `git_ref` is NULL on 26,395 of 26,423 rows
  # (and on 8,830 of 8,830 rows a busy box refused), and a btree unique treats
  # NULLs as DISTINCT — so it had never once refused a duplicate active deploy.
  # Two builds for the same site could always be in flight at once, and the box
  # answered the second one 409.
  describe "the ACTIVE-deployment index, re-keyed on (site_id, environment)" do
    test "two concurrent NULL-git_ref actives for one site are REFUSED (they both inserted before)" do
      {bp, site} = setup_site()

      assert {:ok, first} = Deploy.enqueue(site, bp)
      assert is_nil(first.git_ref)
      assert first.status == "queued"

      # The DB itself refuses — not an app-level check. A distinct build_id rules
      # the (site_id, build_id) index out, and git_ref is NULL on both rows, so
      # under the old key this INSERT succeeded and two builds raced.
      assert {:error, %Ecto.Changeset{} = cs} =
               Registry.create_deployment(site, %{
                 build_id: "deadbeefdeadbeef",
                 trigger: "content-auto"
               })

      assert {"is blocked — a build for this site is already in progress", _} =
               cs.errors[:git_ref]

      # And the enqueue path turns that refusal into a COALESCE, never a lost
      # publish: the caller is handed the row already in flight.
      assert {:duplicate, ^first} = Deploy.enqueue(site, bp, true, "content-auto")
      assert [_only_one] = Registry.list_deployments(site, 10)
    end

    test "the key is per SITE, not per commit — and a settled row frees the slot" do
      {bp, site} = setup_site()
      other = static_site(bp)

      assert {:ok, mine} = Deploy.enqueue(site, bp)
      # A different site is unaffected (the index is keyed on site_id).
      assert {:ok, _theirs} = Deploy.enqueue(other, bp)

      # `deferred` is deliberately NOT in the active literal: a deferral must not
      # block the rebuild it promises.
      {:ok, _} = Registry.transition_deployment(mine, %{status: "deferred"})
      assert {:ok, next} = Deploy.enqueue(site, bp, true, "content-auto")
      refute next.id == mine.id
    end
  end

  # ssw8 / charter D162 — WHAT the content revision is derived from, and what it
  # says when it could not be read.
  #
  # The revision used to be sha256 of the WHOLE analytics body, whose
  # `recent_activity` is the last 50 mutation events for the entire dataset —
  # every type, drafts included. A site bound to one doc_type therefore got a
  # fresh rev, a fresh build_id and a full rebuild of byte-identical output every
  # time an unrelated type churned or anyone saved a draft. And when the read
  # FAILED it minted a random `"u" <> hex` marker that was shipped to the box,
  # baked into `<meta name="bp-content-rev">` and then asserted EQUAL by HEALTH —
  # a green certified by comparing an invented value to itself.
  #
  # The FIRST fix filtered that window down to the bound type. It could not work,
  # and the docstring that said it did was false: the box truncates to 50 events
  # BEFORE the cloud filters, so another type's churn EVICTS the bound type out of
  # the window and moves the hash with zero publishes of that type (D162: ≈19
  # minutes of history on the live fleet, a real publish demonstrated evicted to
  # EMPTY inside 20 minutes, ≥24 % of a day's distinct revisions eviction
  # artefacts). The probe now asks the box a TYPE-SCOPED published question
  # instead of filtering a fleet-shared firehose, so there is no window to evict.
  describe "content_rev — published + type-scoped, honest when unreadable" do
    @query_path "/w/acme/p/blog/v1/data/query/production/post"
    @analytics_path "/w/acme/p/blog/v1/data/analytics/production"

    # The box's answer to the type-scoped published query: this type's published
    # `total` plus the newest published document of the type.
    defp query(opts) do
      docs =
        case Keyword.get(opts, :head, {"hello", "r1", "2026-07-28T10:00:00Z"}) do
          nil -> []
          {id, rev, updated} -> [%{"_id" => id, "_rev" => rev, "_updatedAt" => updated}]
        end

      body = %{
        "result" => %{
          "perspective" => "published",
          "documents" => docs,
          "count" => length(docs),
          "limit" => 1,
          "offset" => 0,
          "hasMore" => false,
          "total" => Keyword.get(opts, :total, 2)
        },
        "syncTags" => [],
        "ms" => 1,
        "etag" => "e",
        "schemaHash" => "s"
      }

      {:ok, %{status: 200, body: Jason.encode!(body)}}
    end

    defp event(id, type, doc_id, mutation, ts) do
      %{"id" => id, "type" => type, "doc_id" => doc_id, "mutation" => mutation, "timestamp" => ts}
    end

    # The DATASET-WIDE analytics body — the fleet-shared 50-event firehose the
    # projection used to hash. Programmed alongside the query path so a test can
    # churn it and prove the revision does NOT follow.
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

    defp program_box(query_response, analytics_response \\ analytics([])) do
      StudioLinkFakeHttpClient.program(%{
        @query_path => query_response,
        @analytics_path => analytics_response
      })
    end

    # THE EVICTION PIN (task dr-w11-bl-content-rev-projection-evicts, charter
    # D162). RED before the fix, and red for the exact reason the row names: the
    # bound type's published event starts inside the dataset-wide window, another
    # type's churn fills all 50 slots, and the old projection's post-hoc filter
    # returns [] where it returned [e1] — a moved revision, a fresh build_id and a
    # rebuild of byte-identical output, with ZERO publishes of the bound type in
    # between. The site's own published content — the count and the newest
    # published document — is held BYTE-IDENTICAL across the two reads, so the
    # only thing that changed is other types' churn.
    test "another type's churn EVICTING the bound type from the activity window does NOT move the revision" do
      {bp, site} = setup_site()

      program_box(
        query(total: 2, head: {"hello", "r1", "2026-07-28T10:00:00Z"}),
        analytics(
          recent_activity: [
            event("e1", "post", "hello", "createOrReplace", "2026-07-28T10:00:00Z")
          ]
        )
      )

      assert {:ok, d1} = Deploy.enqueue(site, bp)
      assert is_binary(d1.content_rev) and d1.content_rev != ""

      # SETTLE FIRST — otherwise this test has no subject. `recover_conflict/3`
      # answers `{:duplicate, active}` for the still-`queued` d1 whenever the
      # re-keyed `(site_id, environment)` index refuses the insert, and it does
      # that for a DIFFERENT build_id too. Left in flight, the assertion below
      # passes on the defective code for a reason that has nothing to do with the
      # revision: it measures the one-active-build guard, not the projection.
      # With d1 settled, only a repeat `build_id` can produce `:duplicate`.
      settle(d1)

      # 50 slots of `task` churn later, the bound type's only published event has
      # been truncated off the end of the window. Nothing this site publishes
      # changed: same published total, same newest published document.
      program_box(
        query(total: 2, head: {"hello", "r1", "2026-07-28T10:00:00Z"}),
        analytics(
          total_documents: 53,
          types: [
            %{"type" => "post", "total" => 3, "published" => 2, "drafts" => 1},
            %{"type" => "task", "total" => 50, "published" => 50, "drafts" => 0}
          ],
          recent_activity:
            for i <- 50..1//-1 do
              minute = String.pad_leading(Integer.to_string(i), 2, "0")
              event("t#{i}", "task", "t-#{i}", "patch", "2026-07-28T11:#{minute}:00Z")
            end
        )
      )

      assert {:duplicate, dup} = Deploy.enqueue(site, bp),
             "an evicted activity window must not mint a new build of byte-identical output"

      assert dup.id == d1.id and dup.build_id == d1.build_id
      assert dup.content_rev == d1.content_rev
      assert length(Registry.list_deployments(site, 10)) == 1
    end

    # The same eviction, one rung below `enqueue/5` — the revision itself, with no
    # deployment row and therefore no index in the way. This is the assertion the
    # row's invariant is literally about: the projection's answer must not move
    # when only ANOTHER TYPE churns.
    test "the revision itself is unmoved by another type's churn filling the activity window" do
      {bp, site} = setup_site()

      program_box(
        query(total: 2, head: {"hello", "r1", "2026-07-28T10:00:00Z"}),
        analytics(
          recent_activity: [
            event("e1", "post", "hello", "createOrReplace", "2026-07-28T10:00:00Z")
          ]
        )
      )

      assert {:ok, rev_before} = Deploy.content_rev_probe(site, bp)

      program_box(
        query(total: 2, head: {"hello", "r1", "2026-07-28T10:00:00Z"}),
        analytics(
          total_documents: 53,
          types: [
            %{"type" => "post", "total" => 3, "published" => 2, "drafts" => 1},
            %{"type" => "task", "total" => 50, "published" => 50, "drafts" => 0}
          ],
          recent_activity:
            for i <- 50..1//-1 do
              minute = String.pad_leading(Integer.to_string(i), 2, "0")
              event("t#{i}", "task", "t-#{i}", "patch", "2026-07-28T11:#{minute}:00Z")
            end
        )
      )

      assert {:ok, rev_after} = Deploy.content_rev_probe(site, bp)

      assert rev_after == rev_before,
             "the bound type published nothing between these two reads — only `task` churn " <>
               "evicted its event out of the dataset-wide window"
    end

    test "draft churn and other types do NOT move the revision — the no-op survives a live dataset" do
      {bp, site} = setup_site()

      program_box(query(total: 2, head: {"hello", "r1", "2026-07-28T10:00:00Z"}))

      assert {:ok, d1} = Deploy.enqueue(site, bp)
      # Settle it: an in-flight d1 makes `:duplicate` the answer to EVERY second
      # enqueue (see the eviction pin above), which would make this test green
      # over a projection that had moved.
      settle(d1)

      # The SAME published content, on a dataset that has since churned: a draft
      # of the bound type was saved, an unrelated `task` was closed, the totals
      # and the draft counts moved with them. Nothing the site PUBLISHES changed —
      # so the type-scoped published answer is unchanged too.
      program_box(
        query(total: 2, head: {"hello", "r1", "2026-07-28T10:00:00Z"}),
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

      assert {:duplicate, dup} = Deploy.enqueue(site, bp),
             "a draft-only / other-type mutation must not mint a new build of byte-identical output"

      assert dup.id == d1.id and dup.build_id == d1.build_id
      assert length(Registry.list_deployments(site, 10)) == 1
    end

    test "a real PUBLISHED change to the bound type DOES move the revision — the fix is not a constant" do
      {bp, site} = setup_site()

      program_box(query(total: 2, head: {"hello", "r1", "2026-07-28T10:00:00Z"}))

      assert {:ok, d1} = Deploy.enqueue(site, bp)

      # A published post is edited: same count, but the edit sets its
      # `updated_at`, so it is the head of the `_updatedAt:desc` order with a new
      # `_rev`. The site's output really does change, so the build must.
      program_box(query(total: 2, head: {"hello", "r2", "2026-07-28T10:05:00Z"}))

      # (deploy-truth W1: one active build per site, so each mint settles before
      # the next — three builds in flight at once is exactly what the re-keyed
      # index now refuses.)
      settle(d1)
      assert {:ok, d2} = Deploy.enqueue(site, bp)
      refute d2.content_rev == d1.content_rev
      refute d2.build_id == d1.build_id
      settle(d2)

      # …and so does a brand-new published document of the bound type.
      program_box(query(total: 3, head: {"world", "r3", "2026-07-28T10:09:00Z"}))

      assert {:ok, d3} = Deploy.enqueue(site, bp)
      refute d3.content_rev in [d1.content_rev, d2.content_rev]
    end

    test "an UNREADABLE box ships an EMPTY content_rev — never a fabricated one — and still rebuilds" do
      {bp, site} = setup_site()

      program_box({:ok, %{status: 502, body: "upstream down"}})

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

      program_box({:ok, %{status: 502, body: "upstream down"}})
      assert Deploy.content_rev_probe(site, bp) == :error

      program_box(query([]))
      assert {:ok, rev} = Deploy.content_rev_probe(site, bp)
      assert byte_size(rev) == 12
    end

    # The read is TYPE-SCOPED at the door, not filtered after the fact — the
    # difference the row is about. Asserted against the URL the fake actually
    # saw, so a projection that quietly went back to the dataset-wide firehose
    # reds here even if its hash happened to agree.
    test "the probe reads the type-scoped PUBLISHED query, never the dataset-wide activity window" do
      {bp, site} = setup_site()

      program_box(query([]))
      assert {:ok, _rev} = Deploy.content_rev_probe(site, bp)

      urls = Enum.map(StudioLinkFakeHttpClient.requests(), & &1.url)

      assert Enum.any?(urls, &String.contains?(&1, "/v1/data/query/production/post")),
             "expected a type-scoped published read, saw #{inspect(urls)}"

      assert Enum.any?(urls, &String.contains?(&1, "perspective=published")),
             "the admin token sees drafts too — the perspective must be pinned: #{inspect(urls)}"

      assert Enum.any?(urls, &String.contains?(&1, "count=true")),
             "the published TOTAL is half the projection: #{inspect(urls)}"

      refute Enum.any?(urls, &String.contains?(&1, "/v1/data/analytics/")),
             "the dataset-wide 50-event window is the defect — it must not be read at all"
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

      # cch-w63-s3: ARM THE RECORDER. `FakeBoxRelay.record/1` only appends under a
      # store key `program/1` created, so a test that never programs records
      # NOTHING and `calls()` answers `[]` no matter what the box was told to do.
      # MEASURED at this exact assertion: with three real box calls injected
      # immediately above it and no `program/1`, this test PASSED — the one
      # assertion that exists to prove the box was untouched could not lose. With
      # this line it fails and names all three verbs. (Narrow claim: only
      # `calls() == []` was vacuous; the row/status assertions above always bit.)
      FakeBoxRelay.program([])
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

    # deploy-truth W1 (charter D9). This test used to program the FLAT body
    # `%{"error" => "…"}` — a shape the real box has never sent — and assert the
    # row died `failed`. Both halves were wrong about production:
    #
    #   * `SiteDeployController` answers a busy slug `409` with a NESTED
    #     `%{error: %{code: "already_running", message: …}}`, which is what the
    #     relay decodes and what the driver must read;
    #   * writing that terminal-`failed` is the single largest failure class on
    #     the fleet (8,830 of 17,171 failed rows). `failed` is outside every
    #     recovery pass and nothing re-enqueued, so the publish was simply lost.
    #
    # It is now a COUNTED `deferred` row that carries the box's own words AND a
    # re-fired rebuild.
    test "a BUSY box (409 already_running) defers the row and RE-QUEUES the rebuild, box words intact" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      # The nested shape the box actually sends.
      FakeBoxRelay.program(
        start:
          {:ok, 409,
           %{
             "error" => %{
               "code" => "already_running",
               "message" => "a deploy for site '#{site.slug}' is already running"
             }
           }}
      )

      assert {:ok, :deferred} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      # COUNTED, not quietly dropped and not relabelled a success: the row is a
      # first-class `deferred` that a ledger can bucket on its own.
      assert row.status == "deferred"
      # The box's own words still travel — code AND message.
      assert row.failure_reason =~ "already_running"
      assert row.failure_reason =~ "is already running"
      # …plus the promise that makes `deferred` different from `failed`.
      assert row.failure_reason =~ "re-queued"
      # `detail` is the varchar(255) caption, `failure_reason` the whole story.
      # They were byte-equal until dr-w7 S1 gave the sentence a chain depth (D99,
      # PR #9905) — now the caption is `short_detail/1`'s clamp of the reason,
      # which is what keeps an over-long reason from RAISING 22001 mid-transition.
      assert String.length(row.detail) <= 255

      if String.length(row.failure_reason) <= 255 do
        assert row.detail == row.failure_reason
      else
        assert String.starts_with?(row.failure_reason, String.trim_trailing(row.detail, "…"))
        # The caption keeps the part an operator needs at a glance.
        assert row.detail =~ "refusal 1 of 6"
        assert row.detail =~ "re-queued"
      end

      # THE RE-FIRE, as a real Oban row: a debounced rebuild for THIS site is
      # pending. Nothing about the old path enqueued anything at all.
      assert [job] = pending_auto_deploy_jobs(site.id)
      assert job.args == %{"site_id" => site.id}

      # And the deferred row is NOT active, so it cannot block the very rebuild
      # it promised: a fresh build for this site still mints.
      assert {:ok, next} = Deploy.enqueue(site, bp, true, "content-auto")
      assert next.status == "queued"
      refute next.id == d.id
    end

    test "a busy box that never frees up stops deferring and FAILS honestly rather than looping forever" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        start:
          {:ok, 409, %{"error" => %{"code" => "already_running", "message" => "already running"}}}
      )

      # Six rounds of a box that is not busy but STUCK. Five defer (each minting
      # its own counted row + re-firing the rebuild); the sixth calls it what it
      # is. A chain that re-fired forever would be an infinite loop wearing a
      # counted status.
      outcomes =
        for _ <- 1..6 do
          {:ok, d} = Deploy.enqueue(site, bp, true, "content-auto")
          {:ok, outcome} = Deploy.run(d.id)
          {outcome, Repo.get(Deployment, d.id)}
        end

      assert Enum.map(outcomes, &elem(&1, 0)) ==
               [:deferred, :deferred, :deferred, :deferred, :deferred, :failed]

      {:failed, last} = List.last(outcomes)
      assert last.status == "failed"
      assert last.failure_reason =~ "stuck"

      # Every round is still ON THE RECORD — the failure count was never driven
      # down by making refusals stop being recorded.
      rows = Registry.list_deployments(site, 20)
      assert Enum.count(rows, &(&1.status == "deferred")) == 5
      assert Enum.count(rows, &(&1.status == "failed")) == 1
    end

    # dr-w3 S3. `consecutive_deferrals/1` used to count by STATUS alone, so a
    # chain of MIXED causes was one chain against one bound: five busy-slug
    # refusals followed by a single capacity refusal terminally FAILED the
    # capacity round — a lost publish charged to a cause that had happened once.
    test "a chain of MIXED deferral causes is not one chain — the capacity refusal keeps its own budget" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        start:
          {:ok, 409, %{"error" => %{"code" => "already_running", "message" => "already running"}}}
      )

      # Five busy-slug deferrals: one short of the busy bound.
      for _ <- 1..5 do
        {:ok, d} = Deploy.enqueue(site, bp, true, "content-auto")
        assert {:ok, :deferred} = Deploy.run(d.id)
      end

      # …and now the box refuses for a DIFFERENT reason: its concurrent-build cap.
      FakeBoxRelay.program(
        start:
          {:ok, 409,
           %{"error" => %{"code" => "box_at_capacity", "message" => "4 of 4 build slots in use"}}}
      )

      {:ok, sixth} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :deferred} = Deploy.run(sixth.id)

      row = Repo.get(Deployment, sixth.id)
      assert row.status == "deferred"
      assert row.failure_reason =~ "box_at_capacity"
      # NOT slandered as a stuck runner, and NOT lost.
      refute row.failure_reason =~ "stuck"
      assert row.failure_reason =~ "re-queued"

      assert DeployLedger.classify(row) == "BOX_AT_CAPACITY_DEFERRED"
      assert [_job] = pending_auto_deploy_jobs(site.id)

      # And the chain COUNT is cause-aware too, not just the bound: the busy-slug
      # run was BROKEN by the capacity row, so a fresh busy refusal starts over
      # instead of arriving as the seventh of a chain that never happened.
      # Counting by status alone, this round is 6-in-a-row and dies terminally.
      FakeBoxRelay.program(
        start:
          {:ok, 409, %{"error" => %{"code" => "already_running", "message" => "already running"}}}
      )

      {:ok, seventh} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :deferred} = Deploy.run(seventh.id)
      assert Repo.get(Deployment, seventh.id).status == "deferred"
    end

    # The bound still exists — a cap that refused every round of a long run has
    # builds that are not finishing — but it is the CAPACITY bound, and the
    # sentence it writes sends the operator to the cap, not to a deploy runner
    # that is working exactly as designed.
    test "a box at its build cap gets its OWN bound, and the terminal verdict names the cap" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        start:
          {:ok, 409,
           %{"error" => %{"code" => "box_at_capacity", "message" => "4 of 4 build slots in use"}}}
      )

      outcomes =
        for _ <- 1..12 do
          {:ok, d} = Deploy.enqueue(site, bp, true, "content-auto")
          {:ok, outcome} = Deploy.run(d.id)
          {outcome, Repo.get(Deployment, d.id)}
        end

      # Eleven deferrals then one honest terminal round — where the busy-slug
      # bound would have failed the SIXTH and lost six publishes to a healthy
      # refusal.
      assert Enum.map(outcomes, &elem(&1, 0)) == List.duplicate(:deferred, 11) ++ [:failed]

      {:failed, last} = List.last(outcomes)
      assert last.status == "failed"
      assert last.failure_reason =~ "concurrent-build cap"
      assert last.failure_reason =~ "raise the cap"
      # The verdict is DERIVED from the cause, so the busy-box accusation cannot
      # be aimed at a box that was never busy with this site.
      refute last.failure_reason =~ "not busy but stuck"
    end

    # dr-w7 S1 (deploy-reliability charter D99, PR #9905). The depth was computed
    # for the threshold, logged once, and DISCARDED: on the production ledger 63
    # capacity-deferred rows across five sites all carried the SAME sentence, so
    # refusal 1 and refusal 8 were byte-identical to the operator and the only
    # moment depth ever reached a human was the instant of the terminal drop.
    test "consecutive deferrals are no longer byte-identical — each names its own depth, bound, and what is being counted" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        start:
          {:ok, 409,
           %{
             "error" => %{
               "code" => "box_at_capacity",
               "message" => "1 of 1 build slots in use"
             }
           }}
      )

      rows =
        for _ <- 1..2 do
          {:ok, d} = Deploy.enqueue(site, bp, true, "content-auto")
          assert {:ok, :deferred} = Deploy.run(d.id)
          Repo.get(Deployment, d.id)
        end

      reasons = Enum.map(rows, & &1.failure_reason)
      [first, second] = reasons

      # THE WHOLE POINT: two rounds of the same refusal no longer read the same.
      refute first == second
      assert first =~ "refusal 1 of 12"
      assert second =~ "refusal 2 of 12"

      # All three facts, in every round: the depth, the cause's own bound, and
      # that the counter is a ZERO-PROGRESS guard rather than a countdown — a
      # bare "2 of 12" would promise a drop a merely-slow box may never reach.
      for r <- reasons do
        assert r =~ "in this site's current chain"
        assert r =~ "zero-progress guard, not a countdown"
        assert r =~ "any successful deploy resets it to 0"
        # …and the promise that makes `deferred` different from `failed` still
        # travels, unshadowed by the new clause.
        assert r =~ "re-queued"
      end

      # The clamped varchar(255) caption keeps the DEPTH — the clause sits ahead
      # of the parenthetical for exactly this reason.
      second_row = List.last(rows)
      assert second_row.detail =~ "refusal 2 of 12"
      assert String.length(second_row.detail) <= 255
    end

    # dr-w12 S6. The depth the previous test proves is REACHABLE ONLY THROUGH
    # ENGLISH: it lives inside `failure_reason`, and the Go CLI reads it back
    # with `siteDeferralChainRe` — a regex over a sentence. So every aggregate
    # over chain depth is a regex too, and one reworded clause zeroes them all
    # with nothing failing. This test reads the SAME three facts as data and
    # never touches `failure_reason` at all.
    #
    # IT CAN LOSE: delete the `deferral_depth:`/`deferral_bound:`/
    # `deferral_cause:` keys from the transition in `Deploy.defer/3` and every
    # assertion below reds on nil, while the prose assertions above stay green —
    # which is exactly the asymmetry that made the prose the only truth.
    test "the chain is READABLE AS DATA — depth, bound and cause come off the columns, with no regex over prose" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        start:
          {:ok, 409,
           %{"error" => %{"code" => "box_at_capacity", "message" => "1 of 1 build slots in use"}}}
      )

      rows =
        for _ <- 1..3 do
          {:ok, d} = Deploy.enqueue(site, bp, true, "content-auto")
          assert {:ok, :deferred} = Deploy.run(d.id)
          Repo.get(Deployment, d.id)
        end

      # The chain COUNTS, in a column an aggregate can sum — 1, 2, 3 — without
      # anyone parsing "refusal 2 of 12" out of a sentence.
      assert Enum.map(rows, & &1.deferral_depth) == [1, 2, 3]

      # The bound is the CAUSE's own budget on every row (capacity gets 12), and
      # the cause is the chain's identity: depth without it is meaningless,
      # because two deferrals of different causes are not one chain.
      assert Enum.map(rows, & &1.deferral_bound) == [12, 12, 12]
      assert Enum.map(rows, & &1.deferral_cause) == List.duplicate("BOX_AT_CAPACITY_DEFERRED", 3)

      # A DIFFERENT cause starts a NEW chain — and the columns say so on their
      # own, with its own shorter leash.
      FakeBoxRelay.program(
        start:
          {:ok, 409, %{"error" => %{"code" => "already_running", "message" => "already running"}}}
      )

      {:ok, busy} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :deferred} = Deploy.run(busy.id)
      busy_row = Repo.get(Deployment, busy.id)

      assert busy_row.deferral_depth == 1
      assert busy_row.deferral_bound == 6
      assert busy_row.deferral_cause == "BOX_BUSY_DEFERRED"

      # THE SENTENCE SURVIVES. The columns are the aggregate's; the prose is the
      # operator's, and it says the thing no integer can — that this is a
      # zero-progress guard, not a countdown. Replacing one with the other would
      # be a regression in either direction.
      last = List.last(rows)
      assert last.failure_reason =~ "refusal 3 of 12 in this site's current chain"
      assert last.failure_reason =~ "zero-progress guard, not a countdown"

      # And the columns agree with the sentence beside them, because ONE write
      # produced both.
      assert last.failure_reason =~ "refusal #{last.deferral_depth} of #{last.deferral_bound}"

      # Structure is for DEFERRALS ONLY: a row that never deferred carries no
      # chain, so `deferral_depth IS NOT NULL` is itself a truthful predicate.
      {:ok, clean} = Deploy.enqueue(site, bp, true, "manual")
      assert Repo.get(Deployment, clean.id).deferral_depth == nil
    end

    # dr-bl-deferral-scheduled-vs-actual-gap. The chain's SHAPE is data (above);
    # its PACE was not. Nobody could tell whether a retry waited because the box
    # was busy or because our OWN ladder told it to — the question the
    # concurrency-cap experiment turns on — without hand SQL over `inserted_at`.
    #
    # The two columns describe THE SAME interval (previous round → this round),
    # so this test backdates the first deferral by a known 61 seconds and reads
    # BOTH numbers off the second row: 61 actual against the 60s window the
    # ladder asked for. A ratio, from one row, with no self-join.
    #
    # IT CAN LOSE, twice over: delete `deferral_actual_gap_s:` from the
    # transition in `Deploy.defer/3` and the 61 assertion reds on nil; delete
    # `deferral_scheduled_s:` and the ladder assertion reds on nil. Neither
    # deletion touches a single assertion in the two tests around it.
    test "the chain's PACE is data too — the scheduled window and the actual gap, on the same row" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        start:
          {:ok, 409,
           %{"error" => %{"code" => "box_at_capacity", "message" => "1 of 1 build slots in use"}}}
      )

      {:ok, first} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :deferred} = Deploy.run(first.id)
      first_row = Repo.get(Deployment, first.id)

      # ROUND 1 RECORDS NOTHING, and that is the honest reading: there is no
      # previous round, so no interval elapsed. A 0 here would say the rebuild
      # fired instantly.
      assert first_row.deferral_depth == 1
      assert first_row.deferral_scheduled_s == nil
      assert first_row.deferral_actual_gap_s == nil

      # Age the first round by a KNOWN gap, so the second row's measurement is
      # a number this test chose rather than whatever the suite's clock did.
      backdated = DateTime.add(first_row.inserted_at, -61, :second)

      {1, _} =
        Repo.update_all(
          from(d in Deployment, where: d.id == ^first.id),
          set: [inserted_at: backdated]
        )

      {:ok, second} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :deferred} = Deploy.run(second.id)
      second_row = Repo.get(Deployment, second.id)

      assert second_row.deferral_depth == 2

      # ACTUAL: the difference of the two rows' `inserted_at` — the SAME column
      # and the same arithmetic the 2,262-deferral hand measurement used.
      #
      # DERIVED, NEVER A LITERAL. A literal 61 here asserts that ZERO wall-clock
      # time passed between the backdate and the second enqueue, which is false
      # the moment the suite crosses a second boundary in between — under CI
      # load it reds with `left: 62, right: 61` on PRs that touch nothing near
      # this file (run 34555593107, 2026-09-11). The expected value is read off
      # the two rows' OWN stamps, so the assertion measures what the column
      # recorded against what the rows say, and the floor below is what proves
      # the 61s backdate actually took.
      assert second_row.deferral_actual_gap_s ==
               DateTime.diff(second_row.inserted_at, backdated)

      assert second_row.deferral_actual_gap_s >= 61

      # SCHEDULED: the window the ladder asked for when round 1 re-queued. Read
      # off `deferral_backoff_seconds/1` and never a literal, so an operator who
      # stretched `AUTODEPLOY_DEBOUNCE_S` does not red this test with a config.
      assert second_row.deferral_scheduled_s == Deploy.deferral_backoff_seconds(1)

      # Round 3 climbs the ladder with the chain: depth 3's scheduled window is
      # the one depth 2 asked for, which is a longer window than depth 1's.
      {:ok, third} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :deferred} = Deploy.run(third.id)
      third_row = Repo.get(Deployment, third.id)

      assert third_row.deferral_depth == 3
      assert third_row.deferral_scheduled_s == Deploy.deferral_backoff_seconds(2)
      assert third_row.deferral_scheduled_s > second_row.deferral_scheduled_s
      assert is_integer(third_row.deferral_actual_gap_s)
    end

    # dr-w28 S6. The previous test makes every DEFERRED round queryable — and
    # left the one row that matters most out of it. The terminal round is the
    # publish the fleet GAVE UP ON, and `fail/2` wrote only status /
    # failure_reason / detail, so all seven abandonments on the live control
    # plane carried NULL depth, NULL bound and NULL cause: `deferral_cause =
    # 'BOX_AT_CAPACITY_DEFERRED'` returned the eleven survivable refusals and
    # NOT the drop, and the drop itself was reachable only by
    # `failure_reason LIKE '%rebuilds in a row for this site%'`.
    #
    # IT CAN LOSE: delete the third argument from the `fail(ctx,
    # abandonment_reason(...), %{…})` call in `Deploy.defer/3` and every column
    # assertion below reds on nil, while the prose assertions stay green — the
    # same asymmetry, one row further down the chain.
    test "the ABANDONMENT is readable as data too — the terminal row stamps its own depth, bound and cause" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        start:
          {:ok, 409,
           %{"error" => %{"code" => "box_at_capacity", "message" => "4 of 4 build slots in use"}}}
      )

      rows =
        for _ <- 1..12 do
          {:ok, d} = Deploy.enqueue(site, bp, true, "content-auto")
          {:ok, _outcome} = Deploy.run(d.id)
          Repo.get(Deployment, d.id)
        end

      abandoned = List.last(rows)
      assert abandoned.status == "failed"

      # THE ARITHMETIC, pinned. `defer/3` abandons at `prior >= bound - 1`, so
      # the bound-th round is written `failed` and NEVER `deferred`: the deepest
      # DEFERRED row is 11, and the abandonment above it is 12 — the same number
      # the sentence interpolates. An off-by-one here would make the terminal
      # round indistinguishable from the last survivable one.
      assert Enum.map(Enum.take(rows, 11), & &1.deferral_depth) == Enum.to_list(1..11)
      assert abandoned.deferral_depth == 12
      assert abandoned.deferral_bound == 12
      assert abandoned.deferral_cause == "BOX_AT_CAPACITY_DEFERRED"

      # FINDABLE BY COLUMN, not by a LIKE over prose. This is the query an
      # operator (or a census) actually runs, and before this it returned the
      # eleven refusals the fleet SURVIVED while omitting the one it lost.
      by_column =
        Repo.all(
          from(d in Deployment,
            where:
              d.site_id == ^site.id and d.status == "failed" and
                d.deferral_cause == "BOX_AT_CAPACITY_DEFERRED" and
                d.deferral_depth == d.deferral_bound,
            select: d.id
          )
        )

      assert by_column == [abandoned.id]

      # …and the prose is UNCHANGED, because `deploy_ledger.ex`'s `@abandoned`
      # regex is deliberately coupled to it: the columns are added beside the
      # sentence, never in place of it.
      assert abandoned.failure_reason =~ "refused 12 rebuilds in a row for this site"
      assert abandoned.failure_reason =~ "concurrent-build cap"
      assert DeployLedger.classify(abandoned) == "ABANDONED_AT_CAPACITY"

      # ONE WRITE, ONE TRUTH: the stamped depth is the number the sentence says.
      assert abandoned.failure_reason =~ "refused #{abandoned.deferral_depth} rebuilds in a row"
    end

    # The busy/stuck cause has a SHORTER leash, and its abandonment must stamp
    # ITS bound — 6, not 12 — or an aggregate over `deferral_bound` would report
    # every drop against the capacity budget.
    test "a busy-box abandonment stamps the busy bound: depth 6 of 6, not 5 and not 12" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        start:
          {:ok, 409, %{"error" => %{"code" => "already_running", "message" => "already running"}}}
      )

      rows =
        for _ <- 1..6 do
          {:ok, d} = Deploy.enqueue(site, bp, true, "content-auto")
          {:ok, _outcome} = Deploy.run(d.id)
          Repo.get(Deployment, d.id)
        end

      abandoned = List.last(rows)
      assert abandoned.status == "failed"

      # Five deferrals then the drop — so the terminal depth is 6, the bound
      # itself, and the deepest DEFERRED row is 5.
      assert Enum.map(Enum.take(rows, 5), & &1.deferral_depth) == Enum.to_list(1..5)
      assert abandoned.deferral_depth == 6
      assert abandoned.deferral_bound == 6
      assert abandoned.deferral_cause == "BOX_BUSY_DEFERRED"

      assert abandoned.failure_reason =~ "refused 6 rebuilds in a row for this site"
      assert DeployLedger.classify(abandoned) == "ABANDONED_BOX_STUCK"
    end

    # STRUCTURE IS FOR CHAINS ONLY. A failure that never deferred must keep
    # writing NULL — `fail/…`'s `extra` defaults to empty — because a zero would
    # read as "a chain of depth 0" and put every ordinary build failure into the
    # abandonment numerator.
    test "an ordinary failure carries NO chain columns — the abandonment stamp is not blanket" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        start: {:ok, 500, %{"error" => %{"code" => "runner_start_failed", "message" => "boom"}}}
      )

      {:ok, d} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :failed} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      assert row.status == "failed"
      assert row.deferral_depth == nil
      assert row.deferral_bound == nil
      assert row.deferral_cause == nil
    end

    # The bound is READ FROM THE CAUSE (`max_consecutive_deferrals/1`), never a
    # literal: a capacity chain gets 12 and a busy/stuck chain gets 6, so a
    # sentence that hardcoded either would misstate the other cause's whole
    # budget to the operator reading it.
    # dr-w4-bl-deferral-raw-column-ambiguous — THE SPOOF, DRIVEN END TO END.
    #
    # Both runs below go through the REAL `start_on_box` → `box_refusal/3` →
    # `defer/4` path. The only difference between the two 409 bodies is the
    # presence of the `code` key: the codeless one's `message` is
    # `"box_at_capacity — " <> <the verbatim capacity prose>`, so
    # `refusal_detail/1` renders it to THE SAME BYTES the coded one renders to,
    # and the test asserts that byte-identity rather than assuming it.
    #
    # Before the column, both rows classified BOX_AT_CAPACITY_DEFERRED and took
    # the capacity leash of 12 — a forged cause with no code involved anywhere.
    test "a CODELESS 409 forging the capacity bytes is deferred as BUSY, not as capacity" do
      {bp, site} = setup_site()

      # The verbatim body, READ from the fixture the api-side conformance test
      # pins — never retyped here (#16598).
      forged_message = "box_at_capacity — " <> BoxCapacityRefusalFixture.message()

      # NO `code` KEY. This is the whole specimen.
      FakeBoxRelay.program(start: {:ok, 409, %{"error" => %{"message" => forged_message}}})

      {:ok, spoof} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :deferred} = Deploy.run(spoof.id)
      spoof_row = Repo.get(Deployment, spoof.id)

      FakeBoxRelay.program(
        start:
          {:ok, 409,
           %{
             "error" => %{
               "code" => "box_at_capacity",
               "message" => BoxCapacityRefusalFixture.message()
             }
           }}
      )

      {:ok, coded} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :deferred} = Deploy.run(coded.id)
      coded_row = Repo.get(Deployment, coded.id)

      # THE PRECONDITION: the box's half of the two reasons is byte-identical.
      # (`defer/3` appends its own `" — deferred: refusal N of B …"` clause,
      # which is DOWNSTREAM of the classification and therefore differs — that
      # divergence is the finding, not a flaw in the comparison.)
      box_words = fn reason -> reason |> String.split(" — deferred: ") |> hd() end
      assert box_words.(spoof_row.failure_reason) === box_words.(coded_row.failure_reason)

      # THE COLUMN IS WHERE THEY DIFFER, and it was written at refusal time.
      assert spoof_row.box_refusal_code == DeployLedger.no_box_code()
      assert coded_row.box_refusal_code == "box_at_capacity"

      # THE CRITERION, on the persisted rows.
      refute DeployLedger.classify(spoof_row) == "BOX_AT_CAPACITY_DEFERRED"
      assert DeployLedger.classify(spoof_row) == "BOX_BUSY_DEFERRED"
      assert DeployLedger.classify(coded_row) == "BOX_AT_CAPACITY_DEFERRED"

      # …and the producer's OWN stamped cause agrees with the ledger, because it
      # is computed through the same column-first reader. A forged capacity
      # refusal takes the BUSY leash of 6, not the capacity leash of 12.
      assert spoof_row.deferral_cause == "BOX_BUSY_DEFERRED"
      assert spoof_row.deferral_bound == 6
      assert coded_row.deferral_cause == "BOX_AT_CAPACITY_DEFERRED"
      assert coded_row.deferral_bound == 12
    end

    test "the rendered bound is the CAUSE's own bound — 12 for capacity, 6 for a busy box" do
      {bp, site} = setup_site()

      # THE BOX'S VERBATIM BODY — READ, not retyped. The one copy lives in
      # api/test/support/fixtures/box_capacity_refusal.json, and
      # BarkparkWeb.SiteDeployCapacityBodyConformanceTest drives the REAL
      # controller to a 409 and asserts `capacity_message/3 <> peer_tail/1`
      # still emits exactly that. A reword there reds THERE, on the api diff.
      #
      # What stood here was a hand-typed copy under a "VERBATIM" comment, plus
      # a shape assertion that checked a literal in this file against a regex
      # in this file — it could not fail, and it did not stop the invented
      # "4 of 4 build slots are in use" from sitting here and in
      # deploy_ledger_test.exs for a day (#16598) while the emitter said
      # something else.
      capacity_body = BoxCapacityRefusalFixture.message()

      FakeBoxRelay.program(
        start:
          {:ok, 409, %{"error" => %{"code" => "box_at_capacity", "message" => capacity_body}}}
      )

      {:ok, capacity} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :deferred} = Deploy.run(capacity.id)
      capacity_row = Repo.get(Deployment, capacity.id)
      capacity_reason = capacity_row.failure_reason

      # The bound itself, asserted directly and not only through the sentence:
      # the verbatim body classifies BOX_AT_CAPACITY_DEFERRED and takes the
      # capacity leash of 12, never the busy leash of 6.
      assert capacity_row.deferral_cause == "BOX_AT_CAPACITY_DEFERRED"
      assert capacity_row.deferral_bound == 12

      FakeBoxRelay.program(
        start:
          {:ok, 409, %{"error" => %{"code" => "already_running", "message" => "already running"}}}
      )

      {:ok, busy} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :deferred} = Deploy.run(busy.id)
      busy_reason = Repo.get(Deployment, busy.id).failure_reason

      assert capacity_reason =~ "refusal 1 of 12"
      refute capacity_reason =~ "of 6"

      # A DIFFERENT cause breaks the chain, so this is refusal 1 again — and it
      # is measured against the busy box's shorter leash.
      assert busy_reason =~ "refusal 1 of 6"
      refute busy_reason =~ "of 12"
    end

    # REVIEW GUARD (dr-w7 S1 review). The depth clause was placed AHEAD of the
    # re-queue promise precisely because `detail` is `short_detail/1`'s
    # varchar(255) clamp, so whatever is appended LAST is what the operator-visible
    # caption loses. Nothing pinned that ordering against a LONG box message,
    # which is the only case where the budget actually bites — so a future clause
    # appended in defer/3 could push the depth out of the caption and every
    # existing assertion (all on short reasons) would stay green. This is that
    # missing guard: the box says 180 characters about itself, the caption is
    # forced to clamp, and the DEPTH still survives it.
    test "the clamped caption keeps the chain depth even when the box's own message is long" do
      {bp, site} = setup_site()

      long_message =
        "all 1 of 1 build slots on this instance are in use by site astro-search " <>
          "(build 0f3c9a12, started 4m ago, stage BUILD) and the queue is not draining"

      FakeBoxRelay.program(
        start: {:ok, 409, %{"error" => %{"code" => "box_at_capacity", "message" => long_message}}}
      )

      {:ok, d} = Deploy.enqueue(site, bp, true, "content-auto")
      assert {:ok, :deferred} = Deploy.run(d.id)
      row = Repo.get(Deployment, d.id)

      # The clamp genuinely fired — otherwise this test proves nothing.
      assert String.length(row.failure_reason) > 255
      assert String.length(row.detail) <= 255
      assert String.ends_with?(row.detail, "…")

      # …and the depth is still in the part that survived.
      assert row.detail =~ "refusal 1 of 12"

      # The whole story is never lost: `failure_reason` is uncapped, and it is
      # what the CLI's deferral render reads first.
      assert row.failure_reason =~ "zero-progress guard, not a countdown"
    end

    # THE FIRST TEST THIS BRANCH HAS EVER HAD. `git grep 'could NOT be
    # re-queued' -- cloud/test` returned zero before dr-w3 S3: the arm that
    # decides whether a LOST publish is counted had never been exercised, and it
    # wrote no `status` at all — so the row kept `deferred`, sat outside the
    # failure numerator, and carried the label "the rebuild was re-queued, not
    # lost" while its own reason said the opposite. Its comment claimed the Oban
    # job would retry; `Deploy.run/1`'s return value is discarded by the
    # supervised Task that drives it, so nothing retried anything.
    test "a deferral whose re-queue FAILS is a lost publish: it settles FAILED, in the numerator" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        start:
          {:ok, 409, %{"error" => %{"code" => "already_running", "message" => "already running"}}}
      )

      # The re-queue seam: the promise cannot be made.
      Process.put(:site_deploy_requeue, fn _site_id -> {:error, :oban_unavailable} end)

      assert {:error, {:deferral_requeue_failed, :oban_unavailable}} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      # THE STATUS, not merely the prose: a lost publish is a failure.
      assert row.status == "failed"
      assert row.failure_reason =~ "could NOT be re-queued"
      assert row.failure_reason =~ "publish again to retry"

      # IN THE NUMERATOR — the ledger counts it as the failure it is…
      class = DeployLedger.classify(row)
      assert class in DeployLedger.classes()
      refute DeployLedger.deferred?(class)
      # …and it no longer wears the label that says it was not lost.
      refute DeployLedger.label(class) =~ "re-queued, not lost"

      # No promise was made, and none is pretended.
      assert pending_auto_deploy_jobs(site.id) == []
    end

    test "a PREBUILT deploy is never deferred — it fails honestly, since the rebuild path would refuse it" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp, false, "manual", nil, "prebuilt")

      FakeBoxRelay.program(
        start:
          {:ok, 409, %{"error" => %{"code" => "already_running", "message" => "already running"}}}
      )

      assert {:ok, :failed} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      assert row.status == "failed"
      # No false promise: the debounced rebuild refuses prebuilt sites outright
      # (it would overwrite bytes this fleet cannot reproduce), so the row must
      # name the human action instead.
      assert row.failure_reason =~ "re-run the upload"
      assert pending_auto_deploy_jobs(site.id) == []
    end

    test "a NON-409 refusal is still terminal — the deferral is scoped to the box's one transient no" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        start:
          {:ok, 400,
           %{"error" => %{"code" => "E_NO_INDEX", "message" => "the archive has no index.html"}}}
      )

      assert {:ok, :failed} = Deploy.run(d.id)
      row = Repo.get(Deployment, d.id)
      assert row.status == "failed"
      assert row.failure_reason =~ "E_NO_INDEX"
      assert pending_auto_deploy_jobs(site.id) == []
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

    # deploy-truth W2 — THE POOL BLIP. The box's 500s on this door are not box
    # faults at all: they are `DBConnection.ConnectionError` (Postgres pool
    # starvation, dominated by SEARCH) crashing the deploy door's OWN auth plug
    # and rendered by the CRASH path into the UNTYPED `internal_error / unknown
    # error` envelope. 91% of them land on the POLL arm — where the loop used to
    # be terminal on the first one, so a blip on beat 37 of a nearly-finished
    # build killed it, exactly as the first-blip `{:error, _}` fail used to.
    # A transient answer now buys the same bounded grace a transient silence does.
    test "one untyped 5xx poll beat no longer kills a build that then finishes" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        polls: [
          crash_500(),
          FakeBoxRelay.walk(all_stages(), url: "#{@instance_url}/sites/#{site.slug}/")
        ]
      )

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "live"
      assert final.stage == "RETIRE"
      assert Repo.get(Site, site.id).current_deployment_id == d.id
    end

    # THE DISCRIMINATION, and the reason this is not the minimal arm: grace is
    # scoped to the UNTYPED crash envelope. A box that answers a TYPED 500 —
    # `runner_start_failed` is one `SiteDeployController` documents — is stating a
    # real fault about itself, and waiting 45 beats to repeat it would only make
    # the user wait for a verdict the box already gave. It stays terminal on the
    # FIRST beat: one poll, then failed.
    test "a TYPED box 500 is still terminal on the first beat — grace is only for the untyped crash envelope" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        polls: [
          {:ok, 500,
           %{
             "error" => %{
               "code" => "runner_start_failed",
               "message" => "could not spawn site-deploy.sh"
             }
           }}
        ]
      )

      assert {:ok, :failed} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "failed"
      assert final.failure_reason =~ "runner_start_failed"
      assert final.failure_reason =~ "could not spawn"
      # No grace was burned: exactly ONE poll happened before the verdict.
      assert Enum.count(FakeBoxRelay.calls(), &match?({:poll_deploy, _}, &1)) == 1
    end

    # The other half of the bargain: an untyped 5xx that NEVER clears is a real
    # box fault wearing a transient shape, so the grace must still be able to
    # fail — and the refusal it swallowed on the way must SURFACE, counted, in
    # the caption. Grace (3) + the terminal beat = 4 polls, then failed.
    test "an untyped 5xx that never clears exhausts the grace and names the refusals it swallowed" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(polls: [crash_500()])

      assert {:ok, :failed} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "failed"
      # The box's own words, the phase, and the swallowed count all travel.
      assert final.failure_reason =~ "internal_error"
      assert final.failure_reason =~ "HTTP 500"
      assert final.failure_reason =~ "build poll"
      assert final.failure_reason =~ "3 transient box 5xx"
      # Bounded: grace (3) + the beat that spends the last of it.
      assert Enum.count(FakeBoxRelay.calls(), &match?({:poll_deploy, _}, &1)) == 4
      assert is_nil(Repo.get(Site, site.id).current_deployment_id)
    end

    # 2,544 refusal rows say "the instance refused the deploy (HTTP 500)" and
    # nothing else — they cannot be told apart from each other, cannot be told
    # apart from a START refusal, and cannot be joined to the box journal that
    # holds the stack trace. The caption now carries the PHASE and the box's own
    # `request_id` (the envelope has always had it; `refusal_detail/1` dropped it).
    test "a refusal caption names its phase and carries the box's request_id" do
      {bp, site} = setup_site()

      # START: the box refuses the trigger itself.
      {:ok, d1} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        start:
          {:ok, 400,
           %{
             "error" => %{
               "code" => "E_NO_INDEX",
               "message" => "the archive has no index.html",
               "request_id" => "F9-start-abc"
             }
           }}
      )

      assert {:ok, :failed} = Deploy.run(d1.id)
      start_reason = Repo.get(Deployment, d1.id).failure_reason
      assert start_reason =~ "refused the deploy"
      assert start_reason =~ "E_NO_INDEX"
      assert start_reason =~ "request_id: F9-start-abc"

      # POLL: the box accepted the build, then refused a beat of it. Same helper,
      # a caption a reader (and a journal join) can tell apart.
      #
      # THE SHAPE HAS TO BE ONE THE PRODUCER CAN MAKE (dr-w14 S3). This used to
      # program a poll answer of 503 `feature_not_configured`, which the real box
      # cannot emit from the GET: unlike `trigger/2`, which opens with
      # `if DeployRunner.enabled?()`, `status/2` has NO apply-flag gate at all,
      # and `feature_not_configured/1` has exactly one caller. A green off a
      # scenario the producer cannot produce is the stamped-evidence
      # overstatement this epic exists to refuse. So the caption is driven from
      # the path that IS reachable: an untyped 5xx that outlives the poll grace
      # and falls out of the graced arm.
      {:ok, d2} = Deploy.enqueue(site, bp, true, "content-auto")

      FakeBoxRelay.program(polls: [crash_500("F9-poll-xyz")])

      assert {:ok, :failed} = Deploy.run(d2.id)
      poll_reason = Repo.get(Deployment, d2.id).failure_reason
      assert poll_reason =~ "refused the build poll"
      assert poll_reason =~ "internal_error"
      assert poll_reason =~ "request_id: F9-poll-xyz"
      # The grace really was spent — this is the exhaustion path, not a first-beat
      # verdict wearing its caption.
      assert poll_reason =~ "3 transient box 5xx"
      # The two phases are genuinely distinguishable, which is the whole point.
      refute poll_reason =~ "refused the deploy"

      # …and the caption the producer just wrote is one the LEDGER can read. Both
      # of its anchors used to require the START caption, so this row classified
      # as UNCLASSIFIED with its status and its code word sitting unread in the
      # string (charter D218). Asserted from the row the driver wrote, not from a
      # literal, so a reworded caption reds here at edit time.
      assert DeployLedger.classify(Repo.get(Deployment, d2.id)) == "BOX_500"
      assert DeployLedger.refusal_phase(poll_reason) == :poll
      assert DeployLedger.refusal_phase(start_reason) == :start
    end

    # THE CAPTION LIED ABOUT A BUILD THAT FINISHED (dr-bl-500-caption-lie).
    #
    # 1,322 rows read exactly "the instance refused the deploy/build poll
    # (HTTP 500)" — the caption of a box that would not take the job — on deploys
    # that had already walked PLAN -> BUILD -> STAGE. Row
    # b928fb2f-65b7-45ee-ab8b-80fa44cad42c is the shape, verbatim: PLAN done,
    # BUILD done ("npm ci && npm run build (next standalone)"), STAGE done
    # ("standalone(+static+public) -> releases/2141dca9a5d58149 (39M)"), HEALTH
    # running. A 39MB artifact really existed on the box, and the row says the
    # instance refused the deploy.
    #
    # The two want OPPOSITE responses from a reader — "your box would not start a
    # build" sends you to the runner flag, "your build finished and then the
    # control plane lost the box at HEALTH" sends you to the health probe — so a
    # caption that cannot tell them apart is not merely terse, it misdirects.
    test "a refusal on a build that already completed BUILD and STAGE names the stage it died at" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      # The incident's console, beat for beat.
      staged =
        {:ok, 200,
         %{
           "state" => "running",
           "stages" => [
             %{"name" => "PLAN", "status" => "done", "detail" => "next standalone"},
             %{
               "name" => "BUILD",
               "status" => "done",
               "detail" => "npm ci && npm run build (next standalone)"
             },
             %{
               "name" => "STAGE",
               "status" => "done",
               "detail" => "standalone(+static+public) -> releases/2141dca9a5d58149 (39M)"
             },
             %{"name" => "HEALTH", "status" => "running", "detail" => nil}
           ]
         }}

      # ...and then the pool blip answers every remaining beat until the grace
      # runs out. This is the live path: an untyped 5xx that never clears.
      FakeBoxRelay.program(polls: [staged, crash_500("F9-health-39mb")])

      assert {:ok, :failed} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      assert row.status == "failed"
      assert row.stage == "HEALTH"
      reason = row.failure_reason

      # THE LIE: the row used to OPEN with the caption of a box that never took
      # the job. It must not any more.
      refute String.starts_with?(reason, "the instance refused")

      # What the row says instead names both halves of the truth: the build got
      # as far as a staged artifact, and the stage it actually died at.
      assert String.starts_with?(
               reason,
               "the build completed and staged; the deploy then failed at HEALTH — " <>
                 "the instance refused the build poll (HTTP 500)"
             )

      assert reason =~ "the build completed and staged"
      assert reason =~ "HEALTH"

      # The caption ADDS; it never replaces. The box's own words, its status and
      # its request_id (the journal join) all still travel.
      assert reason =~ "refused the build poll"
      assert reason =~ "HTTP 500"
      assert reason =~ "internal_error"
      assert reason =~ "request_id: F9-health-39mb"
      assert reason =~ "3 transient box 5xx"

      # ...and the caption stays READABLE TO THE LEDGER. Both of its anchors are
      # `^`-anchored on the refusal template, so a re-caption that forgot them
      # would silently drop 1,322 rows into UNCLASSIFIED — a fix that trades one
      # blind spot for another.
      assert DeployLedger.classify(row) == "BOX_500"
      assert DeployLedger.refusal_phase(reason) == :poll

      # The site's live pointer never moved: a build that failed at HEALTH is
      # still a build that never shipped.
      assert is_nil(Repo.get(Site, site.id).current_deployment_id)
    end

    # The fence is the CRITERION's fence, not "any stage at all": a deploy that
    # died before it staged an artifact has no completed build to mis-report, so
    # its refusal caption is left exactly as it was.
    test "a refusal before STAGE completed keeps the plain refusal caption" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      planning =
        {:ok, 200,
         %{
           "state" => "running",
           "stages" => [
             %{"name" => "PLAN", "status" => "done", "detail" => "next standalone"},
             %{"name" => "BUILD", "status" => "running", "detail" => "npm ci"}
           ]
         }}

      FakeBoxRelay.program(polls: [planning, crash_500("F9-early")])

      assert {:ok, :failed} = Deploy.run(d.id)

      reason = Repo.get(Deployment, d.id).failure_reason
      assert String.starts_with?(reason, "the instance refused the build poll")
      refute reason =~ "the build completed and staged"
      assert DeployLedger.refusal_phase(reason) == :poll
    end

    # The START arm gets the same grace — and it is safe BY CONSTRUCTION, which
    # is what this test pins. If the pool blip ate the RESPONSE but the box did
    # start the run, the retry hits a slug that is already in flight and the box
    # answers 409 `already_running` — which charter D9 already converts into a
    # counted `deferred` row plus a re-fired debounce. So the worst case of a
    # start retry is a DEFERRAL, never a second build.
    test "a start retry that races an in-flight slug degrades to a counted deferral, never a second build" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        start: [
          # The blip: the response died on the pool, but the box took the job.
          crash_500(),
          # The retry meets the run it already started.
          {:ok, 409, %{"error" => %{"code" => "already_running", "message" => "already running"}}}
        ]
      )

      assert {:ok, :deferred} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      assert row.status == "deferred"
      assert row.failure_reason =~ "already_running"
      assert row.failure_reason =~ "re-queued"

      # Exactly two trigger calls, both naming the SAME build — the retry is a
      # retry, not a second build.
      starts = for {:start_deploy, payload} <- FakeBoxRelay.calls(), do: payload
      assert length(starts) == 2
      build_ids = starts |> Enum.map(fn p -> p[:build_id] || p["build_id"] end) |> Enum.uniq()
      assert build_ids == [d.build_id]
      # And ONE deployment row for this site, not two.
      assert length(Registry.list_deployments(site, 10)) == 1
      # …with the debounced rebuild the deferral promises.
      assert [_job] = pending_auto_deploy_jobs(site.id)
    end

    # dr-w8-s2, THE CO-MERGE. The api door stops calling a wedged Runner an unset
    # flag — but a rename alone would make deploys WORSE: `feature_not_configured`
    # and the new `deploy_runner_unavailable` are both TYPED, and a typed 5xx is
    # terminal here on the first beat. The allowlist arm is what turns the rename
    # into a recovery. Delete `"deploy_runner_unavailable" -> true` from
    # `transient_refusal?/1` and these two go red — a lost build wearing a better
    # name, which is the failure mode charter D114 exists to prevent.
    test "a wedged-Runner start refusal buys the start retry instead of spending the build" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        start: [
          # The Runner did not answer the trigger — but it may well have TAKEN
          # the job, which is exactly why the retry is safe by construction.
          runner_unavailable_503(),
          {:ok, 409, %{"error" => %{"code" => "already_running", "message" => "already running"}}}
        ]
      )

      assert {:ok, :deferred} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      assert row.status == "deferred"
      assert row.failure_reason =~ "already_running"
      # One build, two triggers — a retry, never a second build.
      assert length(Registry.list_deployments(site, 10)) == 1
      assert [_job] = pending_auto_deploy_jobs(site.id)
    end

    test "a wedged-Runner poll beat is graced, and the build that then finishes goes live" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        polls: [
          runner_unavailable_503(),
          FakeBoxRelay.walk(all_stages(), url: "#{@instance_url}/sites/#{site.slug}/")
        ]
      )

      assert {:ok, :live} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "live"
      assert Repo.get(Site, site.id).current_deployment_id == d.id
    end

    # Grace still has to be able to LOSE: a Runner that never answers is a real
    # box fault wearing a transient shape, and the row that lands must name the
    # box's own last words and how many beats were tolerated first.
    test "a wedged Runner that never clears exhausts the grace and says what it swallowed" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(polls: [runner_unavailable_503("F9-wedged-forever")])

      assert {:ok, :failed} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "failed"
      assert final.failure_reason =~ "deploy_runner_unavailable"
      assert final.failure_reason =~ "transient box 5xx"
      # And it never blames the operator's configuration.
      refute final.failure_reason =~ "BARKPARK_SITE_DEPLOY_APPLY"
    end

    # THE OTHER 503, and the only phase that can write it (dr-w14 S3). The api
    # door's `trigger/2` opens with `if DeployRunner.enabled?()` and answers
    # `feature_not_configured` when it is off; `status/2` has NO such gate, so
    # this cause exists on the START arm and NOWHERE else. It is the 265-row
    # shape that named the whole 503 split — the box was demonstrably UP and the
    # operator was sent to check its health — so the producer side owes it a
    # test, and the ledger's label gauge scrapes its wire vocabulary from this
    # file (`deploy_ledger_test.exs`, assertion A): delete this and the gauge
    # goes red rather than quietly measuring five words instead of six.
    test "a switched-off deploy flag is a TERMINAL start refusal, named as configuration" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        start:
          {:ok, 503,
           %{
             "error" => %{
               "code" => "feature_not_configured",
               "message" =>
                 "site deploys are not enabled on this instance (set BARKPARK_SITE_DEPLOY_APPLY=1)",
               "request_id" => "F9-flag-off"
             }
           }}
      )

      assert {:ok, :failed} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      assert row.status == "failed"
      assert row.failure_reason =~ "refused the deploy"
      assert row.failure_reason =~ "feature_not_configured"
      # TYPED, so no grace is spent repeating a question a flag already answered.
      assert Enum.count(FakeBoxRelay.calls(), &match?({:start_deploy, _}, &1)) == 1
      refute row.failure_reason =~ "transient box 5xx"

      # The class an operator reads, from the row the driver wrote: the flag,
      # never the box's health.
      assert DeployLedger.classify(row) == "BOX_DEPLOY_DISABLED_503"
      refute DeployLedger.label("BOX_DEPLOY_DISABLED_503") =~ "unavailable"
      assert DeployLedger.refusal_phase(row.failure_reason) == :start
    end
  end

  # dr-bl-w8-graced-deploys-are-uncounted. THE SAVES WERE THE UNCOUNTED HALF.
  #
  # Grace has always been able to say what it could not save: `with_graced_note/2`
  # puts "after tolerating 3 transient box 5xx" into the `failure_reason` of a row
  # that failed anyway, and four tests above assert exactly that. Nothing said
  # what grace DID save, in any outcome — because `forget_graced_refusals/1`
  # `Map.drop`s the ctx tally on every poll that reached the box, and a poll that
  # reached the box is what a working grace LOOKS LIKE. The start-retry arm
  # recorded nothing at all, win or lose.
  #
  # Charter D114 is the bill for that: one wire literal falling out of
  # `transient_refusal?/1` deletes 3 start retries and 45 poll-grace beats per
  # deploy, and with no counter the loss reads only as a higher failure rate with
  # nothing naming the cause.
  #
  # THE MUTATION THESE TESTS ANSWER TO: reinstate the silent drop — delete the
  # `record_grace(...)` call from `record_graced_refusal/2` and from the start
  # `>= 500` arm of `start_on_box/6` — and every test in this block goes red.
  describe "the grace that WORKED is counted (dr-bl-w8)" do
    setup do
      ref = make_ref()
      test = self()

      :telemetry.attach(
        "grace-#{inspect(ref)}",
        [:barkpark_cloud, :sites, :deploy, :grace],
        fn event, measurements, metadata, _ ->
          send(test, {:grace_telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("grace-#{inspect(ref)}") end)
      :ok
    end

    test "graced poll refusals are counted on the row and SURVIVE the reaching poll that clears the caption tally" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      # Two blips, then the box comes back and the build finishes. This is the
      # save: the deploy goes LIVE, so `with_graced_note/2` never runs and the
      # ctx tally is dropped by the very poll that made the run a success.
      FakeBoxRelay.program(
        polls: [
          crash_500(),
          crash_500(),
          FakeBoxRelay.walk(all_stages(), url: "#{@instance_url}/sites/#{site.slug}/")
        ]
      )

      assert {:ok, :live} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      assert row.status == "live"
      # The pre-W8 record of those two saves, in full:
      assert is_nil(row.failure_reason)

      # The post-W8 record: a NUMBER on the row the grace saved.
      assert row.graced_poll_refusals == 2
      assert row.graced_start_retries == 0
      assert %DateTime{} = row.last_graced_at

      # …and the in-process signal, carrying the box's own caption so a reader
      # can tell WHICH refusal was swallowed, not merely how many.
      assert_received {:grace_telemetry, [:barkpark_cloud, :sites, :deploy, :grace], %{count: 1},
                       %{
                         kind: :poll_refusal,
                         deployment_id: id,
                         site_slug: slug,
                         caption: caption
                       }}

      assert id == d.id
      assert slug == site.slug
      assert caption =~ "internal_error"
      assert_received {:grace_telemetry, _, %{count: 1}, %{kind: :poll_refusal}}
    end

    test "a start retry that then succeeds is counted — the arm that recorded nothing in any outcome" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      # The blip ate the response and the box did NOT take the job; the retry
      # lands and the build runs to live. Nothing about this row used to say a
      # retry had happened.
      FakeBoxRelay.program(
        start: [crash_500(), {:ok, 202, %{"status" => "started"}}],
        polls: [FakeBoxRelay.walk(all_stages(), url: "#{@instance_url}/sites/#{site.slug}/")]
      )

      assert {:ok, :live} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      assert row.status == "live"
      assert row.graced_start_retries == 1
      assert row.graced_poll_refusals == 0
      assert %DateTime{} = row.last_graced_at

      assert_received {:grace_telemetry, _, %{count: 1},
                       %{kind: :start_retry, deployment_id: id, caption: caption}}

      assert id == d.id
      assert caption =~ "refused the deploy"

      # Two triggers, one build — the retry is a retry (the D9 guarantee the
      # count now has a number behind it).
      assert Enum.count(FakeBoxRelay.calls(), &match?({:start_deploy, _}, &1)) == 2
    end

    test "a wedged-Runner save is counted too — the exact literal charter D114 shows a rename deletes" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        polls: [
          runner_unavailable_503(),
          FakeBoxRelay.walk(all_stages(), url: "#{@instance_url}/sites/#{site.slug}/")
        ]
      )

      assert {:ok, :live} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      assert row.status == "live"
      # Drop `"deploy_runner_unavailable"` from `transient_refusal?/1` and this
      # deploy stops going live at all — but BEFORE this column, the only visible
      # difference between the two worlds was a failure rate.
      assert row.graced_poll_refusals == 1
    end

    test "the counter also survives the FAILING path, alongside the caption it does not replace" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(polls: [crash_500()])

      assert {:ok, :failed} = Deploy.run(d.id)

      row = Repo.get(Deployment, d.id)
      # The prose is the operator's and is untouched; the column is the
      # aggregate's. Both, never one instead of the other.
      assert row.failure_reason =~ "3 transient box 5xx"
      assert row.graced_poll_refusals == 3
    end

    test "the count is reachable from a NAMED QUERY over a pinned window, not only from one row" do
      {bp, site} = setup_site()

      {:ok, saved} = Deploy.enqueue(site, bp)

      FakeBoxRelay.program(
        polls: [
          crash_500(),
          FakeBoxRelay.walk(all_stages(), url: "#{@instance_url}/sites/#{site.slug}/")
        ]
      )

      assert {:ok, :live} = Deploy.run(saved.id)

      from_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      to_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      census = Registry.deploy_grace_census(from_at, to_at, site_ids: [site.id])

      assert census.deployments == 1
      assert census.graced_poll_refusals == 1
      assert census.graced_start_retries == 0
      assert census.deployments_graced == 1
      # THE NUMBER THE TASK EXISTS FOR: deploys that reached `live` only because
      # grace held. Kill grace and this goes to zero while failures climb.
      assert census.saved == 1
      # A zero that means "nobody was counting" is kept apart from a zero that
      # means "no saves" — a census that summed them could not be read.
      assert census.unmeasured == 0

      # The window is PINNED, so a census that excludes the row reports zero
      # rather than silently reusing the fleet's answer.
      past =
        Registry.deploy_grace_census(
          DateTime.add(from_at, -7200, :second),
          from_at,
          site_ids: [site.id]
        )

      assert past.deployments == 0
      assert past.saved == 0
    end
  end

  # dr-w8-s2 (D). `stage_caption/2`'s non-failed arm was a bare `scrub/1`, and a
  # scrub alone is not a boundary on build-log bytes: a build tool colourises its
  # own output, so the ESC runs land INSIDE the shape the scrubber matches and the
  # credential walks out in cleartext — with raw 0x1B attached, which a console
  # then interprets. Strip first, then redact.
  describe "stage_caption/2 — a colourised secret" do
    test "a colourised credential is redacted, and no ESC byte survives" do
      raw =
        "\e[33mBUILD\e[0m env \e[1mBARKPARK_TOKEN\e[22m=\e[31mbppat_9Xq2LmT4vB7nR1zC8kW5\e[0m"

      caption = Deploy.stage_caption("ok", raw)

      assert caption =~ "[redacted]"
      refute caption =~ "bppat_9Xq2LmT4vB7nR1zC8kW5"
      refute String.contains?(caption, "\e")
      # The narration a person needs still survives the fold.
      assert caption =~ "BUILD env"
    end
  end

  describe "rollback/2 — the sub-second symlink flip (charter D5)" do
    test "blocks on the real flip, then repoints the site at the build that is now live" do
      {bp, site} = setup_site()

      # Two builds: the previous good one, and the one currently live. The
      # previous one is SETTLED (it finished — that is what makes it previous),
      # which is also what the re-keyed active index requires: one build in
      # flight per site at a time.
      {:ok, prev} = Registry.create_deployment(site, %{build_id: "prevbuild0000001"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "building"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "pushing"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "live"})
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

    # deploy-reliability W12 — WHICH KEY NAMES THE TARGET. `rollback/2` used to
    # read `body["build_id"] || body["target_build"] || body["current_build"]`,
    # which reads as "whichever key the box happened to send wins" — a live
    # identity divergence, since the three keys could name different builds.
    # They cannot: the box's raw body never reaches `rollback/2`. The only
    # producer of a 2xx rollback reply is `BoxRelay.HTTP.rollback/2`, which
    # CONSTRUCTS `%{"status" => "rolled_back", "build_id" => target_build(body)}`
    # from the box's `TARGET_BUILD=<id>` stdout line, so the other two keys could
    # never fire. These two tests pin the collapsed contract in both directions.
    test "the target is read from `build_id` ALONE — the retired fallback keys are not read" do
      {bp, site} = setup_site()

      {:ok, prev} = Registry.create_deployment(site, %{build_id: "prevbuild0000001"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "building"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "pushing"})
      {:ok, prev} = Registry.transition_deployment(prev, %{status: "live"})
      {:ok, live} = Registry.create_deployment(site, %{build_id: "livebuild0000001"})
      {:ok, site} = Registry.set_site_current_deployment(site, live.id)

      # A body shaped like the retired second and third arms. No transport in
      # this repo can produce it, so it must NOT move the live pointer — reading
      # it would mean the plane trusts a key its own relay never sends.
      FakeBoxRelay.program(
        rollback:
          {:ok, 200,
           %{
             "status" => "rolled_back",
             "target_build" => "prevbuild0000001",
             "current_build" => "prevbuild0000001"
           }}
      )

      assert {:ok, result} = Deploy.rollback(site, bp)
      assert result.deployment_id == nil
      assert result.previous_deployment_id == live.id
      assert Repo.get(Site, site.id).current_deployment_id == live.id
      refute prev.id == Repo.get(Site, site.id).current_deployment_id
    end

    test "a 2xx rollback body with NO build_id skips the pointer write and still answers ok" do
      {bp, site} = setup_site()

      {:ok, live} = Registry.create_deployment(site, %{build_id: "livebuild0000002"})
      {:ok, site} = Registry.set_site_current_deployment(site, live.id)

      # The REAL nil case: `BoxRelay.HTTP` puts the "build_id" key in every 2xx
      # reply, but its value is nil when the box printed no `TARGET_BUILD=` line.
      # The route answers 200 and the CLI gates on status alone — so the recorded
      # truth is that the pointer still names the build we rolled AWAY from.
      FakeBoxRelay.program(rollback: {:ok, 200, %{"status" => "rolled_back"}})

      assert {:ok, result} = Deploy.rollback(site, bp)
      assert result.deployment_id == nil
      assert Repo.get(Site, site.id).current_deployment_id == live.id
    end

    test "a box with no previous release is a FAILURE, not a cheerful no-op" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(rollback: {:ok, 422, %{"error" => "no_previous"}})

      # cch-w62-bl: the typed code now rides the tuple; the CLI still gates on
      # status alone and the console classifies on the code.
      assert {:error, status, detail, "no_previous"} = Deploy.rollback(site, bp)
      # Non-2xx is load-bearing: the CLI gates success on the HTTP status ALONE.
      refute status in 200..299
      assert detail =~ "no previous build"
    end

    test "a deploy holding the box's lock answers 409, in plain words" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(rollback: {:ok, 409, %{"error" => "lock_held"}})

      # cch-w62-bl: lock_held is typed on the wire now, still transient in the
      # console (the 409 arm's copy is the honest recovery).
      assert {:error, 409, detail, "lock_held"} = Deploy.rollback(site, bp)
      assert detail =~ "deploy is running"
    end

    # W70 (D847/D854) — THE NESTED ENVELOPE, the box's REAL pre-poll refusal
    # transport. `SiteDeployController` answers EVERY refusal
    # `%{error: %{code, message}}` (409 already_running, 409 box_at_capacity,
    # 400, 404, 500, 503) and `BoxRelay.HTTP` relays a non-2xx VERBATIM before
    # it ever polls (`other -> other`). The pre-fix chain
    # `body["error"] || body["detail"] || body["reason"]` bound that MAP, failed
    # `is_binary`, and the box's own sentence died into the generic fallback.
    # Both refusal readers now ride `refusal_detail/1`, the extractor the deploy
    # path already trusts, which composes "code — message".
    #
    # TYPED-TOKEN FATE (decided, on purpose): `rollback_copy/2`'s bare-token
    # clauses (`no_previous` / `not_supported` / `lock_held`) match EXACT flat
    # strings and deliberately do NOT fire on a nested composite — a nested
    # refusal carries the box's own message, which travels VERBATIM instead of
    # being replaced by canned prose. The bare tokens remain reachable only via
    # the FLAT `%{"error" => token}` shape, which today's transports mint solely
    # in fixtures (settle_* mints sentences, pre-poll refusals are nested) — the
    # clauses are KEPT as the friendly rendering for that shape, not deleted.
    test "a NESTED box refusal relays the box's own words — code and message both travel" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        rollback:
          {:ok, 409,
           %{
             "error" => %{
               "code" => "already_running",
               "message" => "deploy already running for blog"
             }
           }}
      )

      assert {:error, 409, detail} = Deploy.rollback(site, bp)
      assert detail == "already_running — deploy already running for blog"
    end

    test "the settle-minted FLAT failure sentence still passes through untouched" do
      {bp, site} = setup_site()

      # The shape `settle_flip/1` mints from the poll's failure_reason.
      FakeBoxRelay.program(
        rollback:
          {:ok, 422, %{"error" => "HEALTH gate failed (exit 14): bp-content-rev marker is empty"}}
      )

      assert {:error, 422, detail} = Deploy.rollback(site, bp)
      assert detail == "HEALTH gate failed (exit 14): bp-content-rev marker is empty"
    end

    test "an undecodable body ({}) still falls to the honest status fallback" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(rollback: {:ok, 500, %{}})

      assert {:error, 422, detail} = Deploy.rollback(site, bp)
      assert detail == "the instance could not roll this site back (HTTP 500)"
    end

    test "an unreachable box is a 502, never a 200" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(rollback: {:error, :instance_error})

      assert {:error, 502, detail} = Deploy.rollback(site, bp)
      assert detail =~ "unreachable"
    end

    # cch-w62-bl — THE BOX'S TYPED REFUSALS TRAVEL AS A CODE the console can
    # classify, via the 4-tuple relay cch-w63-s3 minted for identity_refused.
    # Allowlisted (no_previous / not_supported / lock_held); everything else —
    # including the nested already_running composite the W70 flat-detail law
    # test pins at the route — keeps the 3-tuple and the route's constant
    # `rollback_failed`. Mutation-proven: make `typed_rollback_code/1` return
    # nil and every assert below on the 4th element reds.
    test "a NESTED no_previous refusal mints the typed 4-tuple — prose in detail, code alongside" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        rollback:
          {:ok, 422,
           %{"error" => %{"code" => "no_previous", "message" => "no previous release (exit 21)"}}}
      )

      assert {:error, 422, detail, "no_previous"} = Deploy.rollback(site, bp)
      assert detail == "no_previous — no previous release (exit 21)"
    end

    test "a FLAT no_previous token mints the same typed code, with rollback_copy's prose" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(rollback: {:ok, 422, %{"error" => "no_previous"}})

      assert {:error, 422, detail, "no_previous"} = Deploy.rollback(site, bp)
      assert detail =~ "no previous build"
    end

    test "not_supported and lock_held mint their codes too — lock_held keeps its 409" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(rollback: {:ok, 422, %{"error" => "not_supported"}})
      assert {:error, 422, detail, "not_supported"} = Deploy.rollback(site, bp)
      assert detail =~ "no live release"

      FakeBoxRelay.program(rollback: {:ok, 409, %{"error" => "lock_held"}})
      assert {:error, 409, detail409, "lock_held"} = Deploy.rollback(site, bp)
      assert detail409 =~ "deploy is running"
    end

    test "an UNLISTED code stays the 3-tuple — already_running is pinned to the route constant" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        rollback:
          {:ok, 409,
           %{"error" => %{"code" => "already_running", "message" => "deploy already running"}}}
      )

      assert {:error, 409, _detail} = Deploy.rollback(site, bp)
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
      # The settle-minted FLAT sentence passes through VERBATIM — this is
      # transport shape (b), kept and proven, not merely "some binary".
      assert detail == "caddy validate rejected the disarm"
    end

    # W70 (D847/D854) — same nested envelope, teardown verb. See the rollback
    # twin above for the transport story and the typed-token fate decision;
    # `teardown_refusal/2` rides the same `refusal_detail/1` extractor, keeping
    # only its one verb-neutral typed sentence (`lock_held`, exact flat token).
    test "a NESTED teardown refusal relays the box's own words — code and message both travel" do
      {bp, site} = setup_site()

      FakeBoxRelay.program(
        teardown:
          {:ok, 409,
           %{
             "error" => %{
               "code" => "already_running",
               "message" => "deploy already running for blog"
             }
           }}
      )

      assert {:error, 422, detail} = Deploy.teardown(site, bp)
      assert detail == "already_running — deploy already running for blog"
    end

    test "an undecodable teardown body ({}) still falls to the honest status fallback" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(teardown: {:ok, 500, %{}})

      assert {:error, 422, detail} = Deploy.teardown(site, bp)
      assert detail == "the instance could not tear this site down (HTTP 500)"
    end
  end

  ## ---------------------------------------------------------------------------
  ## cloud-console-hardening W63 (D741/D757/D763) — THE SITE-WRITE FENCE.
  ##
  ## A box whose `update_unavailable_reason` is "identity_refused" answered our
  ## stored admin credential with a 401. `Registry.relay_admin_post/3` has refused
  ## INSTANCE writes to such a box since #11287; the SITE writes ride
  ## `relay_admin/4` and bypassed that fence, so every deploy / rollback / teardown
  ## for the one refused row on the live fleet spent a real request to be told no
  ## again — and was then reported as an UNREACHABLE box, a claim about the network
  ## nobody measured.
  ##
  ## The fence is at the DISPATCHER, so the assertions below are at the box_relay
  ## seam (`FakeBoxRelay.calls()`), not at the trigger: deleting the fence must red
  ## these, and it does — the recorder is armed with `program/1` in every one.
  ## ---------------------------------------------------------------------------

  describe "the site-write fence (a box that refused our credential)" do
    defp refused_barkpark(team) do
      team
      |> live_barkpark()
      |> Ecto.Changeset.change(update_unavailable_reason: "identity_refused")
      |> Repo.update!()
    end

    test "a rollback is refused BEFORE the wire: zero box calls, a typed 409, never a 502" do
      bp = team_fixture() |> refused_barkpark()
      site = static_site(bp)
      FakeBoxRelay.program([])

      assert {:error, 409, detail, "identity_refused"} = Deploy.rollback(site, bp)

      # The status is a CONFLICT about identity, not a 502 about reachability, and
      # the sentence never claims a network fault that did not happen.
      assert detail =~ "the instance rejected our access credential"
      refute detail =~ "unreachable"

      # THE WHOLE POINT: nothing was driven on the box.
      assert FakeBoxRelay.calls() == []
    end

    test "a teardown is refused the same way, with the same typed code" do
      bp = team_fixture() |> refused_barkpark()
      site = static_site(bp)
      FakeBoxRelay.program([])

      assert {:error, 409, detail, "identity_refused"} = Deploy.teardown(site, bp)
      assert detail =~ "the instance rejected our access credential"
      assert FakeBoxRelay.calls() == []
    end

    test "a deploy never starts on a refused box — the row fails with the honest reason" do
      bp = team_fixture() |> refused_barkpark()
      site = static_site(bp)
      FakeBoxRelay.program([])
      {:ok, d} = Deploy.enqueue(site, bp)

      assert {:ok, :failed} = Deploy.run(d.id)

      final = Repo.get(Deployment, d.id)
      assert final.status == "failed"
      assert final.failure_reason =~ "the instance rejected our access credential"

      # No build was spent asking a box that had already said no.
      assert FakeBoxRelay.calls() == []
    end

    test "the READ stays open — poll_deploy still reaches a refused box" do
      bp = team_fixture() |> refused_barkpark()
      FakeBoxRelay.program([])

      # A refused box is exactly the box a human most needs to READ. Fencing one
      # seam up (in Sites.Deploy) would have refused this too.
      assert {:ok, 200, _} = BarkparkCloud.Sites.BoxRelay.poll_deploy(bp, "blog", "build-1")
      assert [{:poll_deploy, %{slug: "blog", build_id: "build-1"}}] = FakeBoxRelay.calls()
    end

    test "a HEALTHY box is untouched by the fence — the writes still go through" do
      {bp, site} = setup_site()
      FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

      assert :ok = Deploy.teardown(site, bp)
      assert [{:teardown, _}] = FakeBoxRelay.calls()
    end
  end

  ## ---------------------------------------------------------------------------
  ## site-spawner W9 — PREBUILT: the build leaves the serving box (charter D86/D91)
  ## ---------------------------------------------------------------------------

  describe "prebuilt deploys" do
    # The bytes ride the EXISTING transport: Registry.relay_admin already
    # Jason.encode!s whatever map it is handed, so this is zero new transport
    # code. What it is NOT free of is a handshake — see the echo tests below.
    defp prebuilt_deployment(site, bytes) do
      bp = Registry.get_barkpark(site.barkpark_id)
      {:ok, d} = Deploy.enqueue(site, bp, false, "manual", nil, "prebuilt")
      sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      {:ok, stamped} = Deploy.store_artifact(d, bytes, sha)
      {stamped, sha}
    end

    defp echoing_start(sha),
      do: {:ok, 202, %{"status" => "started", "prebuilt" => true, "artifact_sha256" => sha}}

    test "the box payload carries artifact_b64 + artifact_sha256, and a box build carries neither" do
      {_bp, site} = setup_site()
      bytes = :crypto.strong_rand_bytes(512)
      {d, sha} = prebuilt_deployment(site, bytes)

      FakeBoxRelay.program(start: echoing_start(sha), polls: [FakeBoxRelay.walk(all_stages())])

      assert {:ok, :live} = Deploy.run(d.id)

      assert [{:start_deploy, payload} | _] = FakeBoxRelay.calls()
      assert payload.source == "prebuilt"
      assert payload.artifact_sha256 == sha
      # The bytes themselves, intact — base64 because the payload is JSON.
      assert Base.decode64!(payload.artifact_b64) == bytes
    end

    test "a BOX build's payload is byte-identical to pre-W9 — no artifact keys at all" do
      {bp, site} = setup_site()
      {:ok, d} = Deploy.enqueue(site, bp)
      FakeBoxRelay.program(polls: [FakeBoxRelay.walk(all_stages())])

      assert {:ok, :live} = Deploy.run(d.id)

      assert [{:start_deploy, payload} | _] = FakeBoxRelay.calls()
      refute Map.has_key?(payload, :artifact_b64)
      refute Map.has_key?(payload, :artifact_sha256)
      refute Map.has_key?(payload, :source)
    end

    test "a 202 WITHOUT the prebuilt echo FAILS the deployment — it never polls the box" do
      {_bp, site} = setup_site()
      {d, _sha} = prebuilt_deployment(site, "dist-bytes")

      # An UN-UPGRADED box: its deploy-request decoder silently drops unknown
      # top-level params, so it accepts the run, ignores the artifact, and builds
      # from source on the very cores this wave exists to free — while the ledger
      # says "prebuilt". Without this check that deploy goes GREEN.
      FakeBoxRelay.program(
        start: {:ok, 202, %{"status" => "started"}},
        polls: [FakeBoxRelay.walk(all_stages())]
      )

      assert {:ok, :failed} = Deploy.run(d.id)

      failed = Registry.get_deployment(d.id)
      assert failed.status == "failed"
      assert failed.failure_reason =~ "did not confirm the prebuilt artifact"

      # And the box was never polled: the run stopped at the handshake.
      refute Enum.any?(FakeBoxRelay.calls(), &match?({:poll_deploy, _}, &1))
    end

    test "a 202 echoing a DIFFERENT digest fails too, naming both digests" do
      {_bp, site} = setup_site()
      {d, sha} = prebuilt_deployment(site, "dist-bytes")

      FakeBoxRelay.program(
        start: echoing_start("0000000000000000000000000000000000000000000000000000000000000000"),
        polls: [FakeBoxRelay.walk(all_stages())]
      )

      assert {:ok, :failed} = Deploy.run(d.id)

      failed = Registry.get_deployment(d.id)
      assert failed.failure_reason =~ sha
      assert failed.failure_reason =~ "0000000000"
    end

    test "the stored bytes are DROPPED once the deployment settles live" do
      {_bp, site} = setup_site()
      {d, sha} = prebuilt_deployment(site, "dist-bytes")

      assert Deploy.artifact_for(d.id)

      FakeBoxRelay.program(start: echoing_start(sha), polls: [FakeBoxRelay.walk(all_stages())])
      assert {:ok, :live} = Deploy.run(d.id)

      # The box has them; a terminal deployment is never re-driven. Keeping them
      # would leak up to 32 MB per build onto the control plane's only volume.
      assert Deploy.artifact_for(d.id) == nil
      # The digest STAYS on the row — that is the record of what was served.
      assert Registry.get_deployment(d.id).artifact_sha256 == sha
    end

    test "the stored bytes are dropped on a FAILED deploy too" do
      {_bp, site} = setup_site()
      {d, sha} = prebuilt_deployment(site, "dist-bytes")

      FakeBoxRelay.program(
        start: echoing_start(sha),
        polls: [FakeBoxRelay.failed_at("HEALTH", "the build marker was missing")]
      )

      assert {:ok, :failed} = Deploy.run(d.id)
      assert Deploy.artifact_for(d.id) == nil
    end

    test "a prebuilt mint is non-idempotent; a box-build mint is not" do
      {bp, site} = setup_site()

      {:ok, p1} = Deploy.enqueue(site, bp, false, "manual", nil, "prebuilt")
      # One active build per site (deploy-truth W1) — settle before the next mint.
      settle(p1)
      {:ok, p2} = Deploy.enqueue(site, bp, false, "manual", nil, "prebuilt")
      settle(p2)

      # NOTE: this refute is NOT the proof of the restart-reset defect (clk-w4).
      # It is same-VM, so the pre-fix `unique_integer([:positive, :monotonic])`
      # counter never resets and this passes on the unfixed code too. It is kept
      # only as a regression guard that prebuilt stays non-idempotent at all.
      # The deciding assertion is the VALUE-DOMAIN one below.
      refute p1.build_id == p2.build_id
      assert p1.source == "prebuilt"
      assert p2.source == "prebuilt"

      # The pre-W9 no-op is untouched — the two nonces are separate keys because
      # they mean different things (force = "re-run this exact content";
      # prebuilt = "the content is not knowable from here").
      {:ok, b1} = Deploy.enqueue(site, bp)
      assert {:duplicate, dup} = Deploy.enqueue(site, bp)
      assert dup.id == b1.id
    end

    test "the prebuilt nonce is a WALL CLOCK, so a control-plane restart cannot repeat it" do
      # The defect this pins: `System.unique_integer([:positive, :monotonic])` is
      # a node-global counter that restarts from 1 on every BEAM boot, so after a
      # restart the Nth prebuilt mint deterministically re-mints an earlier
      # build_id — refused by the (site_id, build_id) partial unique index,
      # answered `{:duplicate, _}` → HTTP 200 with the OLD row, and `record_audit`
      # only runs in the `{:ok, _}` arm, so the uploaded dist is discarded with
      # zero trace.
      #
      # A restart cannot be staged inside `mix test`, and a difference assertion
      # passes on the unfixed code (same VM). So the assertion is on the VALUE
      # DOMAIN instead: a boot-relative counter is a small integer (1, 2, 3…),
      # while a wall clock is ~1.8e18. Unfixed this reads 1 and reds.
      nonce = Deploy.prebuilt_nonce()

      assert is_integer(nonce)

      assert nonce > 1_000_000_000_000,
             "prebuilt nonce #{nonce} is boot-relative, not wall-clock — it repeats after a restart"

      # And it tracks the wall clock rather than merely being large.
      assert_in_delta nonce,
                      System.system_time(),
                      System.convert_time_unit(60, :second, :native)
    end
  end

  # ── dr-w32 S5 ──────────────────────────────────────────────────────────────
  #
  # THE SEVEN HISTORICAL ABANDONMENTS, and the backfill that has to land before
  # the predicate swap. `dr-w28-rv-abandonment-predicate-replaces-the-prose-regex`
  # replaces the prose-anchored classifier with a `deferral_cause`-based one; the
  # seven abandonments on cloud-db-1 all predate the W28 writer (first stamped
  # triple 2026-08-07 10:12:35.033826, last abandonment 03:41:33.865677) and carry
  # NULL in all three columns, so that swap without this backfill turns the whole
  # historical cohort into a zero the cleanup manufactured itself.
  #
  # These tests run the migration's OWN statements — not a paraphrase — so a
  # predicate change there is a predicate change here.
  #
  # IT CAN LOSE: drop the three `IS NULL` legs and the cause's LIKE pattern from
  # `backfill_statements/0` and "an ordinary failure that never deferred is NOT
  # touched" reds with a stamped 0-depth chain on a plain build failure, while the
  # abandonment assertions stay green — the vacuous-green shape this test exists
  # to refuse.
  describe "the historical abandonment backfill (20260809180000)" do
    @backfill BarkparkCloud.Repo.Migrations.BackfillAbandonmentDeferralStructure

    # The two production episodes, at their real depths and timestamps: the
    # 2026-08-05 busy abandonment at 6 rounds, and one of the six 2026-08-07
    # capacity abandonments at 12.
    @busy_at ~U[2026-08-05 22:57:53.830161Z]
    @capacity_at ~U[2026-08-07 01:20:14.000000Z]

    test "stamps depth, bound and cause off the row's own sentence — and an ordinary failure that never deferred is NOT touched" do
      {bp, site} = setup_site()

      capacity =
        seed_failed(site, bp,
          failure_reason:
            Deploy.abandonment_reason(
              "the instance was at its concurrent-build cap",
              12,
              "BOX_AT_CAPACITY_DEFERRED"
            ),
          inserted_at: @capacity_at
        )

      busy =
        seed_failed(site, bp,
          failure_reason:
            Deploy.abandonment_reason(
              "the instance was already deploying",
              6,
              "BOX_BUSY_DEFERRED"
            ),
          inserted_at: @busy_at
        )

      # A FAILURE THAT NEVER DEFERRED. It is `failed` like the two above and it
      # sits in the same table — the only thing separating it from an abandonment
      # is the chain sentence, which is exactly what the predicate keys on.
      ordinary =
        seed_failed(site, bp,
          failure_reason: "the box refused the build (HTTP 500 runner_start_failed)",
          inserted_at: @capacity_at
        )

      # BEFORE: the structured predicate the W28 swap will rely on returns NOTHING
      # for this site, which is the production reading (0 of 32,953 rows).
      assert structured_abandonments(site) == 0

      assert run_backfill() == 2

      capacity = Repo.get(Deployment, capacity.id)
      assert capacity.deferral_depth == 12
      assert capacity.deferral_bound == 12
      assert capacity.deferral_cause == "BOX_AT_CAPACITY_DEFERRED"

      # The SHORTER leash is read off the busy row's own sentence, not off the
      # capacity constant — one blanket bound would misstate this whole episode.
      busy = Repo.get(Deployment, busy.id)
      assert busy.deferral_depth == 6
      assert busy.deferral_bound == 6
      assert busy.deferral_cause == "BOX_BUSY_DEFERRED"

      # THE NON-VACUOUS HALF: a migration that stamped every failed row would put
      # ordinary build failures into the abandonment numerator forever.
      ordinary = Repo.get(Deployment, ordinary.id)
      assert ordinary.deferral_depth == nil
      assert ordinary.deferral_bound == nil
      assert ordinary.deferral_cause == nil

      # AFTER: the predicate the swap keys on now finds both, so the swap can land
      # without erasing history.
      assert structured_abandonments(site) == 2
    end

    # THE POPULATION THAT ACTUALLY OUTNUMBERS EVERYTHING ELSE (review, wave 32).
    # "An ordinary build failure" is the neighbour the brief named, but the
    # neighbour with THOUSANDS of rows is the pre-W28 DEFERRED row: same site,
    # same table, NULLs in all three columns, and a sentence that also counts
    # refusals ("refusal 3 of 12 in this site's current chain"). If the predicate
    # keyed on the round count alone it would stamp every one of them, and each
    # stamped row would satisfy `deferral_depth = deferral_bound` only by
    # accident — silently inflating the abandonment cohort the W28 swap is about
    # to trust. The terminal verdict is what separates the two, and this pins it.
    test "a pre-writer DEFERRED row that also counts refusals is NOT stamped" do
      {bp, site} = setup_site()

      deferred =
        seed_failed(site, bp,
          status: "deferred",
          failure_reason:
            "the instance was at its concurrent-build cap — deferred: refusal 3 of 12 in " <>
              "this site's current chain — a rebuild carrying this content has been re-queued",
          inserted_at: @capacity_at
        )

      abandoned =
        seed_failed(site, bp,
          failure_reason: Deploy.abandonment_reason("at the cap", 12, "BOX_AT_CAPACITY_DEFERRED"),
          inserted_at: @capacity_at
        )

      # ONE row is stamped, and it is the abandonment — not the deferral that
      # merely sits in the same chain.
      assert run_backfill() == 1

      deferred = Repo.get(Deployment, deferred.id)
      assert deferred.deferral_depth == nil
      assert deferred.deferral_bound == nil
      assert deferred.deferral_cause == nil

      abandoned = Repo.get(Deployment, abandoned.id)
      assert abandoned.deferral_depth == 12
      assert abandoned.deferral_cause == "BOX_AT_CAPACITY_DEFERRED"
    end

    test "the bound is the DERIVED depth, never today's constant" do
      {bp, site} = setup_site()

      # A capacity abandonment written under a cap of 9 — a bound that is not the
      # constant in force today. Reading `@max_consecutive_capacity_deferrals`
      # here instead of the sentence would rewrite this row's history to 12.
      row =
        seed_failed(site, bp,
          failure_reason: Deploy.abandonment_reason("at the cap", 9, "BOX_AT_CAPACITY_DEFERRED"),
          inserted_at: @capacity_at
        )

      assert run_backfill() == 1

      row = Repo.get(Deployment, row.id)
      assert row.deferral_depth == 9
      assert row.deferral_bound == 9
      refute row.deferral_bound == 12
    end

    test "is idempotent — a second run stamps zero rows and changes nothing" do
      {bp, site} = setup_site()

      row =
        seed_failed(site, bp,
          failure_reason: Deploy.abandonment_reason("at the cap", 12, "BOX_AT_CAPACITY_DEFERRED"),
          inserted_at: @capacity_at
        )

      assert run_backfill() == 1
      after_first = Repo.get(Deployment, row.id)

      assert run_backfill() == 0
      after_second = Repo.get(Deployment, row.id)

      assert {after_second.deferral_depth, after_second.deferral_bound,
              after_second.deferral_cause} ==
               {after_first.deferral_depth, after_first.deferral_bound,
                after_first.deferral_cause}
    end

    test "the down clears exactly what the up set — a writer-era abandonment survives it" do
      {bp, site} = setup_site()

      reason = Deploy.abandonment_reason("at the cap", 12, "BOX_AT_CAPACITY_DEFERRED")

      historical = seed_failed(site, bp, failure_reason: reason, inserted_at: @capacity_at)

      # A row `Sites.Deploy.defer/3` stamped ITSELF, after the W28 writer landed.
      # It matches the same prose and carries the same triple — the ONLY thing
      # separating it from a backfilled row is that it is newer than the writer,
      # which is why the down is fenced on `inserted_at`.
      writer_era =
        seed_failed(site, bp,
          failure_reason: reason,
          inserted_at: DateTime.add(@backfill.writer_landed_at(), 3600, :second),
          deferral_depth: 12,
          deferral_bound: 12,
          deferral_cause: "BOX_AT_CAPACITY_DEFERRED"
        )

      assert run_backfill() == 1

      cleared =
        for {sql, params} <- @backfill.clear_statements(), reduce: 0 do
          acc -> acc + Repo.query!(sql, params).num_rows
        end

      assert cleared == 1

      historical = Repo.get(Deployment, historical.id)
      assert historical.deferral_depth == nil
      assert historical.deferral_bound == nil
      assert historical.deferral_cause == nil

      writer_era = Repo.get(Deployment, writer_era.id)
      assert writer_era.deferral_depth == 12
      assert writer_era.deferral_bound == 12
      assert writer_era.deferral_cause == "BOX_AT_CAPACITY_DEFERRED"
    end

    # A row carrying whatever the fixture says, minted through the real enqueue
    # path so every NOT NULL column is what production would hold. `failed` is the
    # default because that is what an abandonment is; `put_new` so a fixture can
    # seed the neighbouring `deferred` population instead.
    defp seed_failed(site, bp, attrs) do
      {:ok, d} = Deploy.enqueue(site, bp, true, "content-auto")

      d
      |> Ecto.Changeset.change(Keyword.put_new(attrs, :status, "failed"))
      |> Repo.update!()
    end

    defp run_backfill do
      for {sql, params} <- @backfill.backfill_statements(), reduce: 0 do
        acc -> acc + Repo.query!(sql, params).num_rows
      end
    end

    # The query the W28 predicate swap will run: an abandonment is the only row
    # that can satisfy `deferral_depth = deferral_bound`, because `defer/3`
    # abandons AT the bound and a deferred row caps at bound-1.
    defp structured_abandonments(site) do
      Repo.aggregate(
        from(d in Deployment,
          where:
            d.site_id == ^site.id and d.status == "failed" and
              d.deferral_depth == d.deferral_bound
        ),
        :count
      )
    end
  end
end
