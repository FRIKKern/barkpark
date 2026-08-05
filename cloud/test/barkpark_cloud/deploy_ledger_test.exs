defmodule BarkparkCloud.DeployLedgerTest do
  @moduledoc """
  The fleet deploy ledger — deploy-reliability W1 S2.

  Four properties, each of which the ledger is worthless without:

    1. THE TAXONOMY IS KEYED ON THE RAW COLUMN AND ON (stage, prefix). Every
       fixture string below is a VERBATIM sample re-derived from the control
       plane on 2026-08-05 (`cloud-db-1`, 26,671 rows / 17,395 failed), not an
       invented one — including the bare pre-2026-07-30 `HTTP 409` with no
       `already_running` clause, which is 3,814 of 8,970 409-rows and which a
       classifier keyed on the code word silently loses.

    2. UNCLASSIFIED CAN GO UP. An unrecognised reason lands in UNCLASSIFIED, not
       in the nearest bucket, and the census COUNTS it there.

    3. EVERY RATE CARRIES ITS DENOMINATOR, and below `min_sample/0` there is no
       percentage at all — the refusal is behaviour, asserted here, not a
       docstring. `GITHUB_PUSH_UNBUILDABLE` is out of the denominator entirely.

    4. THE CURSOR REACHES PAST 200. Two pages, non-overlapping, over a 250-row
       site — the read `?offset=200` could never do.

  `async: false`: the operator allowlist is process-global Application config
  (`:platform_admin_emails`), mirroring RouterOperatorTest.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, DeployLedger, Registry, Repo}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # ── Verbatim corpus samples (2026-08-05 re-derivation) ────────────────────

  # 5,147 rows. The post-fe264a35b shape, with the machine-readable code.
  @r409_coded "the instance refused the deploy (HTTP 409): already_running — a deploy is already in flight"
  # 3,814 rows (43% of all 409s). The BARE pre-2026-07-30 shape: no code word at
  # all. This string is the whole reason BOX_BUSY keys on "HTTP 409".
  @r409_bare "the instance refused the deploy (HTTP 409)"
  @r500 "the instance refused the deploy (HTTP 500)"
  @r503 "the instance refused the deploy (HTTP 503): feature_not_configured"
  @r429 "the instance refused the deploy (HTTP 429): rate_limited — try again shortly"
  # An HTTP status the ledger has never named: 2 rows. Must be UNCLASSIFIED.
  @r404 "the instance refused the deploy (HTTP 404)"
  @doc_id "HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty"
  @doc_id_alt "HEALTH failed — bp-doc-id marker is empty — the SSR rendered nothing"
  @health_slot "HEALTH gate failed — not switched (exit 14): slot a on :8404 returned 502"
  # 1,082 rows: the site build fetched its corpus from the Barkpark API and was
  # refused. Real 0x1B bytes, exactly as captured from the build PTY.
  @build_403 "BUILD failed (exit 12): \e[31m\e[1m04:34:24\e[22m [ERROR] [build]\e[39m Caught error rendering /graph.json: Error: graph corpus fetch failed: 403"
  @build_plain "BUILD failed (exit 12): at async #getPathsForRoute (file:///opt/barkpark/sites/demo/node_modules/astro/dist/core/build.js:12:3)"
  @unreachable "instance guerrilla is unreachable — the deploy could not be delivered; check instance health"
  @timeout "the build did not finish in time — the box is still working, or it stalled; deploy again to retry"
  @stale_lease "exceeded max deploy claim attempts (stale builder lease)"
  @died "deploy process died abnormally"
  @artifact_empty "artifact: artifact_url is empty (P6 bp deploy must populate it)"
  @gh_push "github push builds require the GitHub App integration (not yet available) — deploy an artifact via bp deploy"
  # 2 rows: nixpacks. Genuinely unnamed — the honest tail.
  @nixpacks "nixpacks build: exit status 1"

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp site_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Deployments are inserted as STRUCTS on purpose: `Deployment.changeset/2`
  # forbids casting `status` (transition_changeset is the sole status mutator)
  # and the census needs rows pinned to an exact `inserted_at`.
  defp deployment!(site, attrs) do
    # `timestamps(type: :utc_datetime_usec)` — a `~U[…Z]` sigil is second
    # precision and Ecto refuses it, so every pinned instant is widened here.
    now = attrs |> Map.get(:inserted_at, DateTime.utc_now()) |> usec()

    Repo.insert!(
      struct(
        %Deployment{
          site_id: site.id,
          status: "failed",
          environment: "production",
          inserted_at: now,
          updated_at: now
        },
        Map.drop(attrs, [:inserted_at])
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      )
    )
  end

  defp usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, token) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## ── 1. The taxonomy ──────────────────────────────────────────────────────

  describe "classify/2 — the named taxonomy over (stage, RAW failure_reason)" do
    test "BOX_BUSY_409 keys on HTTP 409, NEVER on already_running" do
      # The whole point: both shapes are one class. 43% of the largest class
      # carries no code word at all.
      assert DeployLedger.classify("PLAN", @r409_coded) == "BOX_BUSY_409"
      assert DeployLedger.classify("PLAN", @r409_bare) == "BOX_BUSY_409"
      refute String.contains?(@r409_bare, "already_running")
    end

    test "the box-refusal statuses each get their own name; an unnamed one does not" do
      assert DeployLedger.classify("BUILD", @r500) == "BOX_500"
      assert DeployLedger.classify("HEALTH", @r500) == "BOX_500"
      assert DeployLedger.classify("PLAN", @r503) == "BOX_UNAVAILABLE_503"
      assert DeployLedger.classify("BUILD", @r429) == "BOX_RATE_LIMITED_429"
      # An unnamed refusal status is UNCLASSIFIED, not a catch-all BOX_REFUSED.
      assert DeployLedger.classify("PLAN", @r404) == "UNCLASSIFIED"
    end

    test "the refusal prefix is ANCHORED — a build log that merely prints 500 is not a box 500" do
      log = "BUILD failed (exit 12): request to /api returned 500 after 3 retries"
      assert DeployLedger.classify("BUILD", log) == "BUILD_FAILED"

      # …and the same string with the refusal prefix in the MIDDLE is not a
      # refusal either: only the producer's own template at position 0 counts.
      quoted = "BUILD failed (exit 12): the instance refused the deploy (HTTP 409)"
      assert DeployLedger.classify("BUILD", quoted) == "BUILD_FAILED"
    end

    test "DOC_ID_EMPTY needs the HEALTH stage — the same text elsewhere stays UNCLASSIFIED" do
      assert DeployLedger.classify("HEALTH", @doc_id) == "DOC_ID_EMPTY"
      assert DeployLedger.classify("HEALTH", @doc_id_alt) == "DOC_ID_EMPTY"
      assert DeployLedger.classify("HEALTH", @health_slot) == "HEALTH_GATE_FAILED"

      # Every one of the 3,584 doc-id rows is HEALTH. If that stops being true,
      # the ledger says UNCLASSIFIED rather than quietly widening the class.
      assert DeployLedger.classify("BUILD", @doc_id) == "UNCLASSIFIED"
    end

    test "a BUILD failure splits on what the build could not READ" do
      assert DeployLedger.classify("BUILD", @build_403) == "FORBIDDEN_403"
      assert DeployLedger.classify("BUILD", @build_plain) == "BUILD_FAILED"
    end

    test "the long tail is named too" do
      assert DeployLedger.classify("PLAN", @unreachable) == "BOX_UNREACHABLE"
      assert DeployLedger.classify("HEALTH", @timeout) == "DEPLOY_TIMEOUT"
      assert DeployLedger.classify("BUILD", @stale_lease) == "STALE_LEASE"
      assert DeployLedger.classify("RETIRE", @died) == "PROCESS_DIED"
      assert DeployLedger.classify(nil, @artifact_empty) == "SOURCE_UNFETCHABLE"
      assert DeployLedger.classify(nil, @gh_push) == "GITHUB_PUSH_UNBUILDABLE"
    end

    test "UNCLASSIFIED CAN GO UP: an unrecognised reason is NOT absorbed by the nearest bucket" do
      novel = "the boxcar shim refused the handshake (code BLERG-7)"
      assert DeployLedger.classify("PLAN", novel) == "UNCLASSIFIED"
      assert DeployLedger.classify("BUILD", @nixpacks) == "UNCLASSIFIED"
      assert DeployLedger.classify("STAGE", nil) == "UNCLASSIFIED"

      # And it is not merely "not the biggest class" — it is the sentinel name,
      # so a taxonomy that stops covering the corpus SAYS SO.
      assert "UNCLASSIFIED" in DeployLedger.classes()
    end

    test "classify/1 over a row is nil for anything that did not fail" do
      assert DeployLedger.classify(%{status: "live", stage: "SWITCH", failure_reason: nil}) == nil

      assert DeployLedger.classify(%{status: "failed", stage: "PLAN", failure_reason: @r409_bare}) ==
               "BOX_BUSY_409"
    end

    test "GITHUB_PUSH_UNBUILDABLE is not in the ordinary taxonomy at all" do
      refute "GITHUB_PUSH_UNBUILDABLE" in DeployLedger.classes()
      assert DeployLedger.not_attempted?("GITHUB_PUSH_UNBUILDABLE")
      refute DeployLedger.not_attempted?("BOX_BUSY_409")
    end
  end

  ## ── 2. The census: rate with volume, over a pinned window ────────────────

  describe "census/3 — the rate always carries its denominator" do
    setup do
      {user, team} = user_team()
      site = site_fixture(team)
      %{user: user, team: team, site: site}
    end

    test "REFUSES a percentage below min_sample, and says why", %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..10 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      census = DeployLedger.census(from, to)

      assert census.volume == 10
      assert census.failed == 10
      # The number a naive implementation would print here is 100% off n=10.
      assert census.failure_rate.pct == nil
      assert census.failure_rate.refused
      assert census.failure_rate.sample == 10
      assert census.failure_rate.min_sample == DeployLedger.min_sample()
      assert census.failure_rate.reason =~ "below min_sample"
    end

    test "reports the rate WITH its sample once the window is big enough", %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      # 150 failed + 100 live = 250 attempted → 60.00%.
      for i <- 1..150 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      for i <- 1..100 do
        deployment!(site, %{
          status: "live",
          stage: "SWITCH",
          failure_reason: nil,
          inserted_at: DateTime.add(from, 1000 + i, :second)
        })
      end

      census = DeployLedger.census(from, to)

      refute census.failure_rate.refused
      assert census.failure_rate.pct == 60.0
      # The denominator rides IN the node — a caller cannot print the pct alone.
      assert census.failure_rate.sample == 250
      assert census.failure_rate.numerator == 150
      assert census.volume == 250
      assert census.failed == 150
    end

    test "the window is PINNED — rows outside the bound are not counted", %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      deployment!(site, %{stage: "PLAN", failure_reason: @r409_bare, inserted_at: from})

      deployment!(site, %{
        stage: "PLAN",
        failure_reason: @r409_bare,
        inserted_at: ~U[2026-07-25 23:59:59Z]
      })

      # `to` is EXCLUSIVE — a half-open window is the only shape two adjacent
      # windows can tile without double-counting the boundary row.
      deployment!(site, %{stage: "PLAN", failure_reason: @r409_bare, inserted_at: to})

      assert DeployLedger.census(from, to).volume == 1
    end

    test "GITHUB_PUSH_UNBUILDABLE is OUT of the denominator and in its own bucket", %{site: site} do
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..10 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      for i <- 1..7 do
        deployment!(site, %{
          stage: nil,
          failure_reason: @gh_push,
          inserted_at: DateTime.add(from, 100 + i, :second)
        })
      end

      census = DeployLedger.census(from, to)

      # 17 rows exist; 10 were attempts. A denominator of 17 would report a rate
      # this epic can never move (only the human-gated gh-1 can).
      assert census.volume == 10
      assert census.failed == 10
      assert census.failure_rate.sample == 10

      assert [%{class: "GITHUB_PUSH_UNBUILDABLE", count: 7}] =
               Enum.map(census.not_attempted, &Map.take(&1, [:class, :count]))

      refute Enum.any?(census.classes, &(&1.class == "GITHUB_PUSH_UNBUILDABLE"))
    end

    test "counts per class and per site, with an unrecognised reason visibly in UNCLASSIFIED", %{
      team: team,
      site: site
    } do
      other = site_fixture(team)
      from = ~U[2026-07-26 00:00:00Z]
      to = ~U[2026-07-27 00:00:00Z]

      for i <- 1..5 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(from, i, :second)
        })
      end

      deployment!(site, %{
        stage: "HEALTH",
        failure_reason: @doc_id,
        inserted_at: DateTime.add(from, 60, :second)
      })

      deployment!(other, %{
        stage: "PLAN",
        failure_reason: "a brand new refusal nobody has named yet",
        inserted_at: DateTime.add(from, 90, :second)
      })

      census = DeployLedger.census(from, to)
      by_class = Map.new(census.classes, &{&1.class, &1.count})

      assert by_class["BOX_BUSY_409"] == 5
      assert by_class["DOC_ID_EMPTY"] == 1
      # The tail rose because the corpus changed — which is the signal.
      assert by_class["UNCLASSIFIED"] == 1

      # Per-class share is a rate node too, so it also carries its denominator.
      busy = Enum.find(census.classes, &(&1.class == "BOX_BUSY_409"))
      assert busy.share.sample == 7
      assert busy.label =~ "already deploying"

      sites = Map.new(census.sites, &{&1.site_id, &1})
      assert sites[site.id].volume == 6
      assert sites[site.id].failed == 6
      assert sites[site.id].top_class == "BOX_BUSY_409"
      assert sites[other.id].volume == 1
      # A one-row site gets a refusal, not a 100%.
      assert sites[other.id].failure_rate.refused
    end
  end

  describe "parse_window/2 — the window is required, never floating" do
    test "both bounds required" do
      assert {:error, detail} = DeployLedger.parse_window(nil, "2026-08-01")
      assert detail =~ "from is required"
      assert {:error, detail} = DeployLedger.parse_window("2026-08-01", nil)
      assert detail =~ "to is required"
    end

    test "accepts a bare date or a full instant, and rejects an inverted window" do
      assert {:ok, ~U[2026-07-26 00:00:00Z], ~U[2026-08-06 00:00:00Z]} =
               DeployLedger.parse_window("2026-07-26", "2026-08-06")

      assert {:ok, ~U[2026-07-26 12:30:00Z], _} =
               DeployLedger.parse_window("2026-07-26T12:30:00Z", "2026-08-06")

      assert {:error, "from must be earlier than to"} =
               DeployLedger.parse_window("2026-08-06", "2026-07-26")

      assert {:error, detail} = DeployLedger.parse_window("last tuesday", "2026-08-06")
      assert detail =~ "ISO-8601"
    end
  end

  ## ── 3. The cursor ────────────────────────────────────────────────────────

  describe "list_page/2 — reading past the 200-row cap" do
    setup do
      {user, team} = user_team()
      site = site_fixture(team)
      base = ~U[2026-08-01 00:00:00Z]

      # 250 rows: more than the hard cap, so the second page is only reachable
      # with a cursor. Newest is i = 250.
      for i <- 1..250 do
        deployment!(site, %{
          stage: "PLAN",
          git_ref: "ref-#{i}",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(base, i, :second)
        })
      end

      %{user: user, site: site}
    end

    test "two pages, non-overlapping, covering all 250 rows", %{site: site} do
      assert {:ok, %{deployments: page1, next_cursor: cursor}} =
               DeployLedger.list_page(site, limit: 200)

      assert length(page1) == 200
      assert cursor

      assert {:ok, %{deployments: page2, next_cursor: nil}} =
               DeployLedger.list_page(site, limit: 200, before: cursor)

      assert length(page2) == 50

      refs1 = Enum.map(page1, & &1.git_ref)
      refs2 = Enum.map(page2, & &1.git_ref)

      # NON-overlapping (the `?offset=200` bug returned page one again) …
      assert MapSet.disjoint?(MapSet.new(refs1), MapSet.new(refs2))
      # … and COMPLETE: every row is reachable.
      assert length(Enum.uniq(refs1 ++ refs2)) == 250
      # Newest-first is preserved across the page boundary.
      assert hd(refs1) == "ref-250"
      assert List.last(refs2) == "ref-1"
    end

    test "the last page hands back no cursor even when it is exactly `limit` long", %{site: site} do
      # 250 rows, two pages of exactly 125. The second page is EXACTLY `limit`
      # long, which is the case a naive `length(page) == limit` cursor rule gets
      # wrong — it hands back a cursor to an empty page.
      assert {:ok, %{deployments: page1, next_cursor: cursor}} =
               DeployLedger.list_page(site, limit: 125)

      assert length(page1) == 125
      assert cursor

      assert {:ok, %{deployments: page2, next_cursor: nil}} =
               DeployLedger.list_page(site, limit: 125, before: cursor)

      assert length(page2) == 125
    end

    test "a garbage cursor is an error, never a silent page one", %{site: site} do
      assert {:error, :invalid_cursor} = DeployLedger.list_page(site, before: "not-a-cursor")
      assert :error = DeployLedger.decode_cursor("!!!!")
      assert {:ok, nil} = DeployLedger.decode_cursor(nil)
    end

    test "limit is clamped to the 200 cap", %{site: site} do
      assert {:ok, %{deployments: rows}} = DeployLedger.list_page(site, limit: 5000)
      assert length(rows) == 200
    end
  end

  ## ── 4. The routes ────────────────────────────────────────────────────────

  describe "GET /v1/sites/:id/deployments — the cursor over HTTP" do
    setup do
      {user, team} = user_team()
      site = site_fixture(team)
      %{user: user, site: site, token: login_token(user)}
    end

    test "?before= walks past 200 rows", %{site: site, token: token} do
      base = ~U[2026-08-01 00:00:00Z]

      for i <- 1..250 do
        deployment!(site, %{
          stage: "PLAN",
          git_ref: "ref-#{i}",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(base, i, :second)
        })
      end

      conn = call(:get, "/v1/sites/#{site.id}/deployments?limit=200", token)
      assert conn.status == 200
      body1 = json_body(conn)
      assert length(body1["deployments"]) == 200
      cursor = body1["next_cursor"]
      assert is_binary(cursor)

      conn2 = call(:get, "/v1/sites/#{site.id}/deployments?limit=200&before=#{cursor}", token)
      assert conn2.status == 200
      body2 = json_body(conn2)
      assert length(body2["deployments"]) == 50
      assert body2["next_cursor"] == nil

      ids1 = MapSet.new(body1["deployments"], & &1["id"])
      ids2 = MapSet.new(body2["deployments"], & &1["id"])
      assert MapSet.disjoint?(ids1, ids2)
      assert MapSet.size(MapSet.union(ids1, ids2)) == 250
    end

    test "a garbage cursor is 422, not a silent first page", %{site: site, token: token} do
      deployment!(site, %{stage: "PLAN", failure_reason: @r409_bare})
      conn = call(:get, "/v1/sites/#{site.id}/deployments?before=zzz!!", token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid_cursor"
    end
  end

  describe "deployment_json/1 — the honest payload" do
    setup do
      {user, team} = user_team()
      site = site_fixture(team)
      %{site: site, token: login_token(user)}
    end

    test "emits stage + failure_class, and a RAW reason that is scrubbed AND ANSI-free", %{
      site: site,
      token: token
    } do
      # A real astro BUILD-exit-12 capture (0x1B bytes) with a credential spliced
      # into it — the two hazards this field must survive at once.
      reason = @build_403 <> " (authorization: Bearer sk-live-AbC123dEf456GhI789jkl)"
      deployment!(site, %{stage: "BUILD", failure_reason: reason})

      conn = call(:get, "/v1/sites/#{site.id}/deployments", token)
      assert conn.status == 200
      [row] = json_body(conn)["deployments"]

      assert row["stage"] == "BUILD"
      assert row["failure_class"] == "FORBIDDEN_403"

      raw = row["failure_reason_raw"]
      # RAW of the REWRITE, not raw of the SECRETS: the box's own words survive…
      assert raw =~ "graph corpus fetch failed: 403"
      # …the credential does not…
      refute raw =~ "sk-live-AbC123dEf456GhI789jkl"
      assert raw =~ "[redacted]"
      # …and no ESC byte reaches the screen, in either field.
      refute String.contains?(raw, "\e")
      refute String.contains?(row["failure_reason"], "\e")
    end

    test "failure_class is nil on a row that did not fail", %{site: site, token: token} do
      deployment!(site, %{status: "live", stage: "SWITCH", failure_reason: nil})

      conn = call(:get, "/v1/sites/#{site.id}/deployments", token)
      [row] = json_body(conn)["deployments"]

      assert row["failure_class"] == nil
      assert row["failure_reason_raw"] == nil
    end
  end

  describe "GET /v1/operator/deploy-ledger/census — the cross-site read" do
    setup do
      prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
      on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prior) end)

      {user, team} = user_team()
      site = site_fixture(team)
      %{user: user, team: team, site: site}
    end

    test "no session → 401; a non-operator session → 403", %{user: user} do
      Application.put_env(:barkpark_cloud, :platform_admin_emails, [])

      conn =
        conn(:get, "/v1/operator/deploy-ledger/census?from=2026-07-26&to=2026-08-06")
        |> Router.call(@opts)

      assert conn.status == 401

      conn =
        call(
          :get,
          "/v1/operator/deploy-ledger/census?from=2026-07-26&to=2026-08-06",
          login_token(user)
        )

      assert conn.status == 403
    end

    test "an operator gets counts per class and per site in ONE call", %{user: user, site: site} do
      Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
      base = ~U[2026-07-26 00:00:00Z]

      for i <- 1..3 do
        deployment!(site, %{
          stage: "PLAN",
          failure_reason: @r409_bare,
          inserted_at: DateTime.add(base, i, :second)
        })
      end

      conn =
        call(
          :get,
          "/v1/operator/deploy-ledger/census?from=2026-07-26&to=2026-08-06",
          login_token(user)
        )

      assert conn.status == 200
      body = json_body(conn)

      assert body["volume"] == 3
      assert body["failed"] == 3
      # Three rows is not a rate, and the payload says so rather than printing 100%.
      assert body["failure_rate"]["pct"] == nil
      assert body["failure_rate"]["refused"] == true
      assert body["failure_rate"]["sample"] == 3
      assert body["min_sample"] == DeployLedger.min_sample()

      assert [%{"class" => "BOX_BUSY_409", "count" => 3}] =
               Enum.map(body["classes"], &Map.take(&1, ["class", "count"]))

      assert [%{"site_id" => sid, "volume" => 3}] =
               Enum.map(body["sites"], &Map.take(&1, ["site_id", "volume"]))

      assert sid == site.id
      assert body["window"]["from"] =~ "2026-07-26"
    end

    test "a missing window is 422 — there is no default", %{user: user} do
      Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])

      conn = call(:get, "/v1/operator/deploy-ledger/census", login_token(user))
      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid_window"
      assert json_body(conn)["detail"] =~ "pinned, never floating"
    end
  end
end
