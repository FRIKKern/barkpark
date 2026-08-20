defmodule BarkparkCloud.DeployLedgerDeliveryScopeTest do
  @moduledoc """
  THE DELIVERY GAUGE STOPS BEING DARK — `delivery` on the TEAM census route
  (dr-w21-s6, paying dr-w18-bl-team-census-has-no-delivery-node).

  WHAT WAS BROKEN, PROVEN BY RUN AND NOT BY READING. `bp cloud deployments -o
  table` against the live control plane rendered, to every real operator:

      delivery — how long content waited to reach the web
        NOT MEASURED — this control plane sends no delivery census.

  `DeployLedger.delivery/3` shipped in W11 and was ROUTED in W15 S3 — but only
  by `Web.Router.deploy_census_json/2`, which serves
  `GET /v1/operator/deploy-ledger/census`, gated by `require_platform_operator`,
  which answers `403 {"error":"forbidden","scope":"platform","required":
  "platform_operator"}` to a real account token. The route `bp` actually reads is
  the TEAM one, `GET /v1/deploy-ledger/census`, and it `Map.put` only `:scope`.
  So the reader landed on a route nobody can reach, and the ONLY arm production
  ever executed was the `d == nil` arm its Go test forbids — a vacuous green
  asserted against a fixture that test builds itself.

  THIS FILE ASSERTS ON THE ROUTE, THROUGH A CONN. Never on a hand-built
  envelope: that substitution is exactly the defect above.

  ## The tenancy trap, which is the high-risk judgment of the slice

  `delivery/3` accepted only `:site_limit` and `:as_of`, and its query filtered
  `inserted_at` and `environment` and NOTHING ELSE — FLEET-WIDE by
  construction. A naive `Map.put(:delivery, DeployLedger.delivery(from, to))` on
  a team-scoped body would have pooled another team's waits into this team's
  percentiles and named their `site_id`s in the `sites` list beneath them. The
  fix threads `:site_ids` through, mirroring `census/3`, and it is proved here
  with a two-team fixture IN BOTH DIRECTIONS — A never sees B, B never sees A —
  because a one-directional check passes against a filter that is simply
  constant.

  ## The refusal arms must SURVIVE scoping

  Scoping makes populations SMALLER, so refusals get MORE likely, not less. A
  scoped node that cannot identify a quantile must still render
  `NO NUMBER — <reason>` beside its population (`sample`), its still-waiting
  count, its window width and its `as_of` instant. A bare number is a lie and a
  silent `0` is a worse one: this file asserts the seconds are `nil`, the
  reason names the cause, and all four companions ride with it.

  ## The mutation that proves the route arm can lose

  BOTH mutations were RUN on this tree, observed, and restored.

  Deleting `|> Map.put(:delivery, DeployLedger.delivery(from, to, site_ids:
  scoped))` from the team route in `router.ex` reds 6 of these 10 tests, headed
  by "the TEAM route carries a delivery node":

      the team census route emitted NO delivery node — `bp cloud deployments`
      renders "NOT MEASURED — this control plane sends no delivery census" for
      exactly this reason. Keys present: ["boundaries", "cancelled", "classes",
      … "scope", "sites", "total_sites", "truncated", "volume", "window"]

  Dropping only the SCOPE — `DeployLedger.delivery(from, to)`, the naive
  `Map.put` this slice exists to refuse — reds 4, headed by "the routed node is
  SCOPED":

      team t-2850's delivery node named site rows it does not own:
      ["a0bf57e2-…", "635151e1-…"] (team t-2946 owns a0bf57e2-…)

  ## The bound that keeps this honest

  This block's clock is `deployment row: inserted_at -> became_live_at`
  (`@delivery_clock`) over SITE CONTENT deploys. It is NOT the platform's own
  merge-to-serving code lag — different clock, different population, different
  source — and that gauge has no recorder at all
  (`dr-w21-bl-merge-to-serving-lag-has-no-recorder`).

  `async: true`: nothing here touches the process-global operator allowlist.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, DeployLedger, Registry, Repo}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  @from ~U[2026-08-01 00:00:00Z]
  @to ~U[2026-08-02 00:00:00Z]
  @window "from=2026-08-01&to=2026-08-02"

  ## ── Fixtures ──────────────────────────────────────────────────────────────

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp owned_team do
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

  # Struct inserts, not changesets: `Deployment.changeset/2` refuses to cast
  # `status`, and the delivery clock needs both instants pinned exactly.
  defp deployments!(site, rows) do
    entries =
      Enum.map(rows, fn r ->
        at = usec(Map.fetch!(r, :inserted_at))

        %{
          id: Ecto.UUID.generate(),
          site_id: site.id,
          status: Map.get(r, :status, "live"),
          stage: Map.get(r, :stage),
          failure_reason: Map.get(r, :failure_reason),
          environment: Map.get(r, :environment, "production"),
          became_live_at: r |> Map.get(:became_live_at) |> maybe_usec(),
          inserted_at: at,
          updated_at: at
        }
      end)

    Repo.insert_all(Deployment, entries)
  end

  defp maybe_usec(nil), do: nil
  defp maybe_usec(%DateTime{} = dt), do: usec(dt)

  defp usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  # `n` delivered rows, each waiting exactly `seconds`, spaced an hour apart so
  # nothing collides on `inserted_at`.
  defp delivered(n, seconds) do
    for i <- 1..n do
      at = DateTime.add(@from, i * 3600, :second)
      %{status: "live", inserted_at: at, became_live_at: DateTime.add(at, seconds, :second)}
    end
  end

  # An instant strictly AFTER the `n`th hourly row, i.e. past a site's last live
  # mark when `n` is its row count — the only place a row can be CENSORED.
  defp still_waiting_at(n), do: DateTime.add(@from, n * 3600 + 1800, :second)

  # TEAM A: 4 rows that each waited 60s. TEAM B: 9 rows that each waited 9,000s
  # — LOUDER in volume and 150x slower, so a leak is both top-of-list in `sites`
  # and unmissable in every percentile.
  defp two_teams do
    {user_a, team_a} = owned_team()
    site_a = site_fixture(team_a)
    deployments!(site_a, delivered(4, 60))

    {user_b, team_b} = owned_team()
    site_b = site_fixture(team_b)
    deployments!(site_b, delivered(9, 9_000))

    %{
      user_a: user_a,
      team_a: team_a,
      site_a: site_a,
      user_b: user_b,
      team_b: team_b,
      site_b: site_b
    }
  end

  ## ── Credentials ───────────────────────────────────────────────────────────

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(path, token) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp delivery_site_ids(delivery), do: Enum.map(delivery["sites"], & &1["site_id"])

  ## ── 1. delivery/3 honours :site_ids, in BOTH directions ───────────────────

  describe "DeployLedger.delivery/3 :site_ids" do
    test "restricts the measured rows to the named sites — A never sees B" do
      f = two_teams()

      d = DeployLedger.delivery(@from, @to, site_ids: [f.site_a.id], as_of: @to)

      assert d.sample == 4,
             "team A owns 4 delivered rows; a fleet-wide read would report 13"

      assert Enum.map(d.sites, & &1.site_id) == [f.site_a.id],
             "team A's delivery sites named a foreign site: " <>
               "#{inspect(Enum.map(d.sites, & &1.site_id))} (team B owns #{f.site_b.id})"

      assert d.total_sites == 1
      assert d.p50.seconds == nil or d.p50.seconds == 60.0
    end

    test "the OTHER direction — B never sees A" do
      f = two_teams()

      d = DeployLedger.delivery(@from, @to, site_ids: [f.site_b.id], as_of: @to)

      assert d.sample == 9
      assert Enum.map(d.sites, & &1.site_id) == [f.site_b.id]
      refute f.site_a.id in Enum.map(d.sites, & &1.site_id)
    end

    test "the still-waiting count is scoped too, not only the measured rows" do
      f = two_teams()

      # One row of A's and THREE of B's that never reached live: if the censored
      # fold were computed off an unscoped query, A's `censored.count` would read
      # 4 instead of 1 and its `still_waiting_at_least_seconds` would carry B's
      # much older bound.
      #
      # Each sits AFTER its own site's last live mark, which is what makes it
      # censored at all: a row is DELIVERED by the first live mark at or after
      # it, so an in-flight row before one is resolved, not still waiting.
      deployments!(f.site_a, [%{status: "in_flight", inserted_at: still_waiting_at(4)}])

      deployments!(f.site_b, [
        # PAST B's last live mark: B's 9th row lands at +9h and answers 9,000s
        # later, so anything before +11.5h is DELIVERED by it, not waiting.
        %{status: "in_flight", inserted_at: still_waiting_at(12)},
        %{status: "in_flight", inserted_at: still_waiting_at(13)},
        %{status: "in_flight", inserted_at: still_waiting_at(14)}
      ])

      a = DeployLedger.delivery(@from, @to, site_ids: [f.site_a.id], as_of: @to)
      b = DeployLedger.delivery(@from, @to, site_ids: [f.site_b.id], as_of: @to)

      assert a.censored.count == 1,
             "A's still-waiting count folded rows outside its scope: #{a.censored.count}"

      assert b.censored.count == 3
    end

    test "nil is the whole fleet and [] is EMPTY — they are different facts" do
      f = two_teams()

      assert DeployLedger.delivery(@from, @to, as_of: @to).sample >= 13
      assert DeployLedger.delivery(@from, @to, site_ids: nil, as_of: @to).sample >= 13

      empty = DeployLedger.delivery(@from, @to, site_ids: [], as_of: @to)
      assert empty.sample == 0
      assert empty.sites == []
      # Fail CLOSED: an empty scope refuses a number, it does not print 0s.
      assert empty.p50.refused
      assert empty.p50.seconds == nil
      refute f.site_a.id in Enum.map(empty.sites, & &1.site_id)
    end
  end

  ## ── 2. The ROUTE carries it — asserted through a conn ─────────────────────

  describe "GET /v1/deploy-ledger/census carries a scoped delivery node" do
    test "the TEAM route carries a delivery node" do
      f = two_teams()

      b = body(call("/v1/deploy-ledger/census?#{@window}", session_token(f.user_a)))

      # THE MUTATION-BEARING ASSERTION. Delete the route's
      # `Map.put(:delivery, …)` and this is the line that reds.
      assert is_map(b["delivery"]),
             "the team census route emitted NO delivery node — `bp cloud deployments` " <>
               "renders \"NOT MEASURED — this control plane sends no delivery census\" " <>
               "for exactly this reason. Keys present: #{inspect(Map.keys(b))}"

      assert b["delivery"]["clock"] =~ "inserted_at",
             "the delivery node must carry the NAME of its clock: a latency number " <>
               "whose t0 is not printed beside it cannot be audited"

      assert b["delivery"]["window"]["width_seconds"] == 86_400
      assert b["delivery"]["as_of"]
      assert b["delivery"]["environment"] == "production"
    end

    test "the routed node is SCOPED — team A's body never names team B's site" do
      f = two_teams()

      b = body(call("/v1/deploy-ledger/census?#{@window}", session_token(f.user_a)))
      d = b["delivery"]

      assert delivery_site_ids(d) == [f.site_a.id],
             "team #{f.team_a.slug}'s delivery node named site rows it does not own: " <>
               "#{inspect(delivery_site_ids(d))} (team #{f.team_b.slug} owns #{f.site_b.id})"

      assert d["sample"] == 4,
             "the routed sample is fleet-wide (#{d["sample"]}) — the percentiles under " <>
               "it are pooled from another team's waits"

      refute conn_body_mentions?(b, f.site_b.id),
             "team B's site id appears somewhere in team A's census body"
    end

    test "the OTHER direction over the wire — team B never sees team A" do
      f = two_teams()

      b = body(call("/v1/deploy-ledger/census?#{@window}", session_token(f.user_b)))

      assert delivery_site_ids(b["delivery"]) == [f.site_b.id]
      assert b["delivery"]["sample"] == 9
      refute conn_body_mentions?(b, f.site_a.id)
    end

    test "a team with no sites gets a delivery node that REFUSES, not an absent one" do
      {user, _team} = owned_team()

      b = body(call("/v1/deploy-ledger/census?#{@window}", session_token(user)))

      assert is_map(b["delivery"])
      assert b["delivery"]["sample"] == 0
      assert b["delivery"]["p50"]["refused"]
      assert b["delivery"]["p50"]["seconds"] == nil
    end
  end

  ## ── 3. The refusal arms survive scoping ───────────────────────────────────

  describe "a thin SCOPED population still refuses, with its evidence" do
    test "no bare number and no silent 0 — the reason rides with n, waiting, width and as-of" do
      f = two_teams()
      # Deliberately thin: 4 delivered rows, far below `min_sample` 200. Scoping
      # is what MAKES it thin — the fleet has 13 — which is the whole point:
      # a smaller population makes refusals more likely, never less.
      deployments!(f.site_a, [%{status: "in_flight", inserted_at: still_waiting_at(4)}])

      b = body(call("/v1/deploy-ledger/census?#{@window}", session_token(f.user_a)))
      d = b["delivery"]

      for label <- ["p50", "p95", "max"] do
        node = d[label]

        assert node["refused"], "#{label} printed a number off a population of #{node["sample"]}"
        assert node["seconds"] == nil, "#{label} carried seconds beside refused: true"

        assert is_binary(node["reason"]) and node["reason"] != "",
               "#{label} refused with no reason — a refusal that does not say why is a blank"

        # THE POPULATION TRAVELS WITH THE REFUSAL. Every one of these is what
        # keeps the CLI's `NO NUMBER — <reason>` line from being an unfalsifiable
        # shrug.
        assert node["sample"] == 5
        assert node["censored"] == 1
        assert node["window_seconds"] == 86_400
        assert node["min_sample"] == DeployLedger.min_sample()
      end

      assert d["reason"] == nil or is_binary(d["reason"])
      assert d["censored"]["count"] == 1
      assert d["censored"]["as_of"]
      assert d["censored"]["still_waiting_at_least_seconds"] > 0
      assert d["as_of"]
      assert d["window"]["width_seconds"] == 86_400
    end

    test "the refusal names the SCOPED sample, not the fleet's" do
      f = two_teams()

      b = body(call("/v1/deploy-ledger/census?#{@window}", session_token(f.user_a)))

      assert b["delivery"]["p50"]["reason"] =~ "sample 4",
             "the refusal quoted a population other than the caller's own: " <>
               inspect(b["delivery"]["p50"]["reason"])
    end
  end

  # A whole-body scan, not a keyed one: the tenancy question is "does this id
  # appear ANYWHERE in the bytes team A receives", and a keyed check would miss
  # a leak into a node this test did not think to name.
  defp conn_body_mentions?(body, id), do: body |> Jason.encode!() |> String.contains?(id)
end
