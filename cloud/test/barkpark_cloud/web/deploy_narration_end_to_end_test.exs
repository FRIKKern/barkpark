defmodule BarkparkCloud.Web.DeployNarrationEndToEndTest do
  @moduledoc """
  dwb-18 criterion 3 — NARRATION FROM WEBHOOK RECEIPT THROUGH BUILDER
  COMPLETION OR FAILURE, driven over the REAL HTTP surface.

  Everything dwb-18 built is already on main: the control plane narrates a
  builder claim onto `deployments.console` (`Registry.narrate_transition/2`,
  written in the claim's own changeset), the array is capped by the canonical
  `Registry.cap_console/1`, and `deployment_json/1` ships it to the dashboard.
  What did NOT exist was a test that STARTS where a real deploy starts — a
  signed GitHub push — and walks the same row to a terminal status, reading the
  narration back through the route the dashboard actually fetches.

  Every existing test covers one SEGMENT:

    * `deploy_claim_narration_test.exs` — the claim entry, called in-process.
    * `sites_deploy_console_cap_test.exs` — the cap at `Sites.Deploy.record_stage/2`
      (the STATIC driver, a different pipeline).
    * `router_github_webhook_test.exs` — the webhook's status codes and dedup.

  None of them crosses a process boundary between the push and the terminal, so
  a regression anywhere in the handoff (the webhook minting a row the builder
  route cannot claim, the claim narration lost on the way out of
  `deployment_json/1`, the console reordered by the serializer) reds nothing.

  ## THE SPAN THIS TEST ACTUALLY DRIVES, and where it stops

  All four legs are REAL HTTP calls into `BarkparkCloud.Web.Router`, each with
  the credential production uses (HMAC for the webhook, the box's own agent
  token for the builder and agent routes, a user session for the read):

      POST /v1/webhooks/github/:site_id          (HMAC)      queued
      POST /v1/builder/claim                     (agent)     -> building
      POST /v1/builder/deployments/:id/console   (agent)     builder lines
      POST /v1/builder/deployments/:id/transition(agent)     -> pushing | failed
      POST /v1/agent/deployments/claim           (agent)     on-box pickup
      POST /v1/agent/deployments/:id/transition  (agent)     -> live
      GET  /v1/sites/:id/deployments/:dep_id     (session)   the dashboard read

  WHAT IT IS NOT. It is not a deploy against a live box: no builder process, no
  clone, no nixpacks, no container, no health check. It drives the control
  plane's side of the contract by making exactly the calls a builder makes. A
  real builder could still send different payloads than these; that gap is not
  closeable from ExUnit and is not claimed here.

  ## THE HONEST SHAPE OF THE NARRATION (asserted, not assumed)

  Three legs of this span narrate NOTHING, and the test asserts each silence
  rather than skipping past it, because a silence nobody asserts is one a later
  change can fill or widen unnoticed:

    * WEBHOOK RECEIPT writes no console entry — the row is born with `[]`.
    * The ON-BOX AGENT CLAIM (`pushing`, claim_worker stamped) writes none.
    * The TERMINAL transition itself (`live` / `failed`) writes none — the
      status column carries it.

  The control plane authors exactly ONE entry across the whole span: the builder
  claim. Everything else in the console is relayed from the build.

  Shared test database: every assertion reads the row by the id THIS test
  created, never a table-wide query, so a peer agent's rows cannot colour it.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @secret "the-webhook-secret"

  ## ------------------------------------------------------------------
  ## Fixtures
  ## ------------------------------------------------------------------

  defp setup_pipeline do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    # kind defaults to "container" — the only kind the off-box builder claims.
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    {:ok, site} = Registry.set_site_github(site, "owner/repo", "main", @secret)

    {:ok, session} = Accounts.create_user_session_token(user)
    {:ok, agent, _} = Registry.mint_agent_token(bp.id, "report")

    %{site: site, session: session, agent: agent}
  end

  ## ------------------------------------------------------------------
  ## Request helpers — one per credential kind
  ## ------------------------------------------------------------------

  defp github_push(site_id, sha, delivery) do
    body = %{"ref" => "refs/heads/main", "after" => sha}
    raw = Jason.encode!(body)
    mac = :crypto.mac(:hmac, :sha256, @secret, raw) |> Base.encode16(case: :lower)

    conn(:post, "/v1/webhooks/github/#{site_id}", raw)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", "push")
    |> put_req_header("x-hub-signature-256", "sha256=" <> mac)
    |> put_req_header("x-github-delivery", delivery)
    |> Router.call(@opts)
  end

  defp post_as(path, body, token) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp get_as(path, token) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  # THE DASHBOARD'S OWN READ. Nothing below reaches into the Repo for the
  # console: if `deployment_json/1` drops, reorders or mangles it, these
  # assertions are the ones that fail.
  defp dashboard_read(ctx, dep_id) do
    conn = get_as("/v1/sites/#{ctx.site.id}/deployments/#{dep_id}", ctx.session)
    assert conn.status == 200
    body_of(conn)["deployment"]
  end

  defp console_lines(deployment_json),
    do: Enum.map(deployment_json["console"] || [], & &1["line"])

  # Monotone non-decreasing `at` stamps == the array is in the order the entries
  # were written. Every writer stamps the SERVER clock, so this is a real check
  # on ordering and not on a worker's clock.
  defp stamps_non_decreasing?(deployment_json) do
    ats = Enum.map(deployment_json["console"] || [], & &1["at"])
    ats == Enum.sort(ats)
  end

  ## ------------------------------------------------------------------
  ## ARM 1 — the SUCCESS span: push -> claim -> build lines -> pushing -> live
  ## ------------------------------------------------------------------

  describe "webhook receipt through builder completion" do
    test "the whole span narrates, in order, and the dashboard read carries it" do
      ctx = setup_pipeline()
      sha = String.duplicate("a1", 20)

      # -- LEG 1: the signed push mints a queued row ------------------------
      conn = github_push(ctx.site.id, sha, "delivery-success-#{System.unique_integer([:positive])}")
      assert conn.status == 201
      minted = body_of(conn)
      dep_id = minted["deployment_id"]
      assert minted["status"] == "queued"
      assert minted["sha"] == sha

      # THE SILENCE AT RECEIPT, asserted: a webhook narrates nothing.
      born = dashboard_read(ctx, dep_id)
      assert born["status"] == "queued"
      assert console_lines(born) == []

      # -- LEG 2: the builder claims -> the ONE control-plane entry ---------
      conn = post_as("/v1/builder/claim", %{worker_id: "builder-alpha"}, ctx.agent)
      assert conn.status == 200
      claim = body_of(conn)
      assert claim["deployment"]["id"] == dep_id
      assert claim["deployment"]["status"] == "building"
      epoch = claim["observed_epoch"]

      claimed = dashboard_read(ctx, dep_id)
      assert console_lines(claimed) == ["BUILD — claimed by builder builder-alpha"]
      assert [entry] = claimed["console"]
      # Authored HERE, not relayed from the build — the distinction a reader of
      # the console needs to tell the pipeline's narration from the build's output.
      assert entry["source"] == "control-plane"
      assert is_binary(entry["at"])

      # -- LEG 3: the builder relays its own lines --------------------------
      for line <- ["Fetching source…", "Building image…", "Pushing image…"] do
        conn =
          post_as("/v1/builder/deployments/#{dep_id}/console", %{line: line}, ctx.agent)

        assert conn.status == 200
      end

      # -- LEG 4: builder hands off (building -> pushing) -------------------
      conn =
        post_as(
          "/v1/builder/deployments/#{dep_id}/transition",
          %{
            worker_id: "builder-alpha",
            observed_epoch: epoch,
            status: "pushing",
            image_tag: "img:#{sha}",
            claim_worker: nil,
            claim_epoch: 0
          },
          ctx.agent
        )

      assert conn.status == 200
      assert body_of(conn)["deployment"]["status"] == "pushing"

      # -- LEG 5: the ON-BOX agent picks the row up ------------------------
      conn = post_as("/v1/agent/deployments/claim", %{worker_id: "agent-1"}, ctx.agent)
      assert conn.status == 200
      agent_claim = body_of(conn)
      assert agent_claim["deployment"]["id"] == dep_id
      agent_epoch = agent_claim["observed_epoch"]

      # THE SECOND SILENCE, asserted: the on-box claim narrates nothing. Four
      # lines before it, four lines after it.
      mid = dashboard_read(ctx, dep_id)
      assert length(mid["console"]) == 4

      # -- LEG 6: terminal — live ------------------------------------------
      conn =
        post_as(
          "/v1/agent/deployments/#{dep_id}/transition",
          %{
            worker_id: "agent-1",
            observed_epoch: agent_epoch,
            status: "live",
            make_current: true,
            site_port: 4101,
            became_live_at: DateTime.utc_now() |> DateTime.to_iso8601()
          },
          ctx.agent
        )

      assert conn.status == 200

      # -- THE WHOLE NARRATION, READ BACK AT THE TERMINAL -------------------
      final = dashboard_read(ctx, dep_id)
      assert final["status"] == "live"

      # ORDERED: the control plane's claim entry FIRST, then the build's own
      # lines in the order the builder sent them. An exact list, not a subset —
      # a subset assertion would not see a duplicated or reordered entry.
      assert console_lines(final) == [
               "BUILD — claimed by builder builder-alpha",
               "Fetching source…",
               "Building image…",
               "Pushing image…"
             ]

      assert stamps_non_decreasing?(final)

      # THE THIRD SILENCE: going live added nothing. The status column carries it.
      assert length(final["console"]) == 4
    end
  end

  ## ------------------------------------------------------------------
  ## ARM 2 — the FAILURE span: push -> claim -> build lines -> failed
  ## ------------------------------------------------------------------

  describe "webhook receipt through builder failure" do
    test "the claim narration survives to the terminal failed read, in order" do
      ctx = setup_pipeline()
      sha = String.duplicate("b2", 20)

      conn = github_push(ctx.site.id, sha, "delivery-failure-#{System.unique_integer([:positive])}")
      assert conn.status == 201
      dep_id = body_of(conn)["deployment_id"]
      assert console_lines(dashboard_read(ctx, dep_id)) == []

      conn = post_as("/v1/builder/claim", %{worker_id: "builder-beta"}, ctx.agent)
      assert conn.status == 200
      epoch = body_of(conn)["observed_epoch"]

      conn =
        post_as(
          "/v1/builder/deployments/#{dep_id}/console",
          %{line: "npm ERR! build failed"},
          ctx.agent
        )

      assert conn.status == 200

      conn =
        post_as(
          "/v1/builder/deployments/#{dep_id}/transition",
          %{
            worker_id: "builder-beta",
            observed_epoch: epoch,
            status: "failed",
            failure_reason: "build exited 1"
          },
          ctx.agent
        )

      assert conn.status == 200

      final = dashboard_read(ctx, dep_id)
      assert final["status"] == "failed"

      # The failure path keeps the SAME ordered narration — the claim entry is
      # not rewritten or dropped when the row goes terminal, which is what makes
      # the console readable AFTER a failure rather than only during a build.
      assert console_lines(final) == [
               "BUILD — claimed by builder builder-beta",
               "npm ERR! build failed"
             ]

      assert stamps_non_decreasing?(final)
    end
  end

  ## ------------------------------------------------------------------
  ## ARM 3 — ORDERED where order can actually be OBSERVED: a RE-CLAIM
  ## ------------------------------------------------------------------

  describe "a re-claimed row narrates the second claim AFTER the build's lines" do
    # WHY THIS ARM EXISTS, and it is the reason arms 1-2 are not enough.
    #
    # `narrate_transition/2` appends with `existing ++ [entry]`. On a FIRST claim
    # `existing` is `[]`, so `[entry] ++ existing` and `existing ++ [entry]`
    # produce the identical array — the concat order is UNOBSERVABLE there, and a
    # test that only ever claims a fresh row cannot fail when that concat is
    # reversed. (Measured: reversing it reds nothing in arms 1-2.)
    #
    # A RE-CLAIM is the one place in this pipeline where the control plane
    # narrates onto a console that is already non-empty: the stale-builder reaper
    # requeues a `building` row (`reap_stale_deployments/0` pass (ii): status back
    # to `queued`, claim dropped, console UNTOUCHED), and the next builder claims
    # it. The second claim entry must land BEHIND the first builder's output, not
    # in front of it.
    #
    # The requeue is applied DIRECTLY to this test's own row rather than by
    # calling `reap_stale_deployments/0`, which sweeps table-wide: in a shared
    # test database that sweep would mutate peer agents' rows inside this
    # transaction. The columns set here are exactly the ones pass (ii) sets.
    test "the second claim entry lands behind the first builder's output" do
      ctx = setup_pipeline()
      sha = String.duplicate("d4", 20)

      conn = github_push(ctx.site.id, sha, "delivery-reclaim-#{System.unique_integer([:positive])}")
      assert conn.status == 201
      dep_id = body_of(conn)["deployment_id"]

      conn = post_as("/v1/builder/claim", %{worker_id: "builder-first"}, ctx.agent)
      assert conn.status == 200

      conn =
        post_as(
          "/v1/builder/deployments/#{dep_id}/console",
          %{line: "half a build, then the builder died"},
          ctx.agent
        )

      assert conn.status == 200

      # The reaper's requeue, applied to THIS row only.
      Registry.get_deployment(dep_id)
      |> Ecto.Changeset.change(%{status: "queued", claim_worker: nil, claimed_at: nil})
      |> BarkparkCloud.Repo.update!()

      conn = post_as("/v1/builder/claim", %{worker_id: "builder-second"}, ctx.agent)
      assert conn.status == 200
      assert body_of(conn)["deployment"]["id"] == dep_id

      final = dashboard_read(ctx, dep_id)

      assert console_lines(final) == [
               "BUILD — claimed by builder builder-first",
               "half a build, then the builder died",
               "BUILD — claimed by builder builder-second"
             ]

      assert stamps_non_decreasing?(final)
    end
  end

  ## ------------------------------------------------------------------
  ## ARM 4 — BOUNDED
  ## ------------------------------------------------------------------

  describe "the narration is bounded" do
    # THE CAP, WRITTEN DOWN. `Registry`'s `@max_console_lines` is private, so this
    # is a LITERAL and deliberately not a probe of `cap_console/1`: a test that
    # asks the capper how much it caps at cannot fail when the capper stops
    # capping — it would just adapt. The literal is cross-checked against the
    # capper in its own assertion below, so a deliberate cap change reds HERE,
    # loudly, with both numbers printed.
    #
    # It is 300. dwb-18's own description says the console is "capped at 100
    # per PR #811"; that is WRONG on today's main and always was for this column.
    @console_cap 300

    test "a chatty build cannot push the console past the cap, and the drop is disclosed" do
      # The cross-check, first and on its own: the canonical capper really does
      # cap, and at the number this test then drives the pipeline with.
      assert Registry.cap_console(Enum.map(1..5_000, &%{"line" => "x#{&1}"})) |> length() ==
               @console_cap

      ctx = setup_pipeline()
      sha = String.duplicate("c3", 20)

      conn = github_push(ctx.site.id, sha, "delivery-bounded-#{System.unique_integer([:positive])}")
      assert conn.status == 201
      dep_id = body_of(conn)["deployment_id"]

      conn = post_as("/v1/builder/claim", %{worker_id: "builder-gamma"}, ctx.agent)
      assert conn.status == 200

      # Exactly `@console_cap` builder lines on top of the ONE claim entry — the
      # smallest overflow that can exist, so the assertion below is about the
      # BOUND and not about a large number. These go through
      # `append_deployment_console/2`, the same writer
      # POST /v1/builder/deployments/:id/console calls; the route itself is
      # exercised in arms 1 and 2. Driving 300 HTTP requests here would test Plug,
      # not the bound.
      for i <- 1..@console_cap do
        {:ok, _} = Registry.append_deployment_console(dep_id, "build line #{i}")
      end

      final = dashboard_read(ctx, dep_id)

      assert length(final["console"]) == @console_cap

      # The OLDEST entry was dropped: the claim line is gone and line 1 is now the
      # head. This is the half a bare length check cannot see — an implementation
      # that REFUSED new lines at the cap would also be `@console_cap` long.
      lines = console_lines(final)
      refute "BUILD — claimed by builder builder-gamma" in lines
      assert List.first(lines) == "build line 1"
      assert List.last(lines) == "build line #{@console_cap}"

      # AND the chop is DISCLOSED. A console that hides what it dropped reads as a
      # complete log when it is a tail.
      assert List.first(final["console"])["dropped_before"] == 1

      assert stamps_non_decreasing?(final)
    end
  end
end
