defmodule BarkparkCloud.DeployLedgerTenancyTest do
  @moduledoc """
  THE TEAM-SCOPED CENSUS — `GET /v1/deploy-ledger/census` (dr-w16-s6).

  Sixteen waves of this epic built a deploy census that is correct to the row and
  that NOBODY CAN READ: the only route over it is
  `GET /v1/operator/deploy-ledger/census`, gated by
  `Auth.require_platform_operator`, and `PLATFORM_ADMIN_EMAILS` is unset in
  production — measured live this wave, that route answers
  `403 {"error":"forbidden","scope":"platform","required":"platform_operator"}`
  to a real token in the same minute `GET /v1/sites` answers it 200. The operator
  population is zero BY CONSTRUCTION. This file covers the read that reaches a
  real, non-admin caller.

  FOUR PROPERTIES, and the census is worse than useless without any of them:

    1. THE SCOPE IS DERIVED FROM THE TEAM, NEVER SUPPLIED BY THE CALLER.
       `deployments` has no `team_id` column at all, so team scope must hop
       through `sites.team_id`. If a client-supplied `?site_ids=` became the
       SOURCE of the filter instead of a NARROWING of the team's own set, team
       B's rows would render inside team A's census body — an IDOR on a number.
       THIS FIXTURE MANUFACTURES A SECOND TEAM WITH ITS OWN SITE AND DEPLOYMENTS
       precisely so that defect can be exhibited: on the live control plane 26 of
       27 teams own zero sites, so a production-drawn fixture is green by
       construction and proves nothing.

    2. THE PREDICATE LIVES IN THE QUERY, NOT IN A POST-FILTER over the rendered
       `sites` node. Asserted by CONSEQUENCE, not by inspection: with
       `site_limit: 3`, one quiet own site and three louder foreign ones, a
       post-filter design leaves every fleet total untouched AND drops the
       caller's own site entirely, because `site_rows/2` sorts by volume and
       takes `site_limit` before any downstream filter could run.

    3. THE INTERSECTION IS COMPUTED IN ELIXIR, NOT IN SQL. `sites.id` /
       `deployments.site_id` are `binary_id`: a client-supplied non-UUID reaching
       either column raises `Ecto.Query.CastError` — a 500, i.e. a brand-new
       silent failure on the route this epic built to end silent failures. The
       counter-proof is here too, as an executed `assert_raise`, so the 500 that
       was avoided is a measured fact rather than a claim in a comment.

    4. THE CREDENTIAL IS `require_user_or_pat` + `require_ability("read")`, NOT a
       session. D219 measured the session-only default PAT-dead; shipping this
       route session-only would reproduce, on the new route, the exact
       unreadable-by-construction defect the route exists to end. A read PAT gets
       200 here, and it is still fenced to its own team.

  `async: true`: nothing here touches the process-global operator allowlist.
  """
  use BarkparkCloud.DataCase, async: true

  import Ecto.Query
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, DeployLedger, Registry, Repo}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Registry.Site
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

  # A team with an owner. Returns {user, team}.
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

  # Deployments are inserted as STRUCTS: `Deployment.changeset/2` refuses to cast
  # `status`, and the census needs rows pinned to an exact `inserted_at`.
  defp deployments!(site, rows) do
    entries =
      Enum.map(rows, fn r ->
        at = usec(Map.get(r, :inserted_at, @from))

        %{
          id: Ecto.UUID.generate(),
          site_id: site.id,
          status: Map.get(r, :status, "failed"),
          stage: Map.get(r, :stage),
          failure_reason: Map.get(r, :failure_reason),
          environment: "production",
          inserted_at: at,
          updated_at: at
        }
      end)

    Repo.insert_all(Deployment, entries)
  end

  defp usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp failed(n, reason \\ "the instance refused the deploy (HTTP 409)") do
    for _ <- 1..n, do: %{status: "failed", stage: "start", failure_reason: reason}
  end

  defp live(n), do: for(_ <- 1..n, do: %{status: "live"})

  ## ── Credentials ───────────────────────────────────────────────────────────

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp read_pat(user, team) do
    {:ok, plaintext, _pat} =
      Accounts.create_personal_access_token(user, team, %{
        name: "ci-read-key",
        abilities: ["read"]
      })

    plaintext
  end

  defp call(path, token) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp rendered_site_ids(body), do: Enum.map(body["sites"], & &1["site_id"])

  ## ── The two-team fixture ──────────────────────────────────────────────────
  #
  # Team A owns ONE site with 3 failed rows. Team B — the team that must never
  # appear in A's answer — owns one site with 7 failed rows, which is LOUDER, so
  # any leak is both visible and top-of-list.
  defp two_teams do
    {user_a, team_a} = owned_team()
    site_a = site_fixture(team_a)
    deployments!(site_a, failed(3))

    {_user_b, team_b} = owned_team()
    site_b = site_fixture(team_b)
    deployments!(site_b, failed(7))

    %{
      user_a: user_a,
      team_a: team_a,
      site_a: site_a,
      team_b: team_b,
      site_b: site_b
    }
  end

  ## ── 1. Tenancy: the foreign team is not reachable, over the wire ──────────

  describe "the scope is derived from the caller's team" do
    test "a team reads its OWN rows and never the other team's" do
      f = two_teams()
      conn = call("/v1/deploy-ledger/census?#{@window}", session_token(f.user_a))

      assert conn.status == 200
      b = body(conn)

      # THE IDOR ASSERTION. If the intersection clause in the router is mutated
      # so the client-supplied list becomes the SOURCE rather than a narrowing,
      # team B's site renders here and this names it.
      assert rendered_site_ids(b) == [f.site_a.id],
             "team #{f.team_a.slug} was shown site rows it does not own: " <>
               "#{inspect(rendered_site_ids(b))} (team #{f.team_b.slug} owns #{f.site_b.id})"

      assert b["volume"] == 3
      assert b["failed"] == 3
    end

    test "naming ANOTHER team's site id over the wire is 200 volume 0, not 403 and not its rows" do
      f = two_teams()

      conn =
        call(
          "/v1/deploy-ledger/census?#{@window}&site_ids=#{f.site_b.id}",
          session_token(f.user_a)
        )

      # 200, not 403: the caller asked a question about a population that is
      # empty for them, and the honest answer to that is a zero — a 403 would
      # confirm the foreign id EXISTS.
      assert conn.status == 200
      b = body(conn)

      # NAMED FIRST, on purpose: when the intersection clause is mutated so the
      # client list becomes the source, THIS is the message that prints, and it
      # prints the foreign site id — the leak, not just a wrong number.
      refute f.site_b.id in rendered_site_ids(b),
             "team #{f.team_b.slug}'s site #{f.site_b.id} leaked into team " <>
               "#{f.team_a.slug}'s census body: #{inspect(rendered_site_ids(b))}"

      assert b["volume"] == 0
      assert b["failed"] == 0
      assert b["sites"] == []
      assert b["scope"]["site_ids"] == []
    end

    test "a read PAT gets 200 — and is fenced to its own team exactly as a session is" do
      f = two_teams()
      pat = read_pat(f.user_a, f.team_a)

      conn = call("/v1/deploy-ledger/census?#{@window}", pat)
      assert conn.status == 200
      b = body(conn)
      assert b["volume"] == 3
      assert rendered_site_ids(b) == [f.site_a.id]
      assert b["scope"]["team"] == f.team_a.slug

      # The same PAT, naming team B's site: still zero, never B's seven rows.
      foreign = call("/v1/deploy-ledger/census?#{@window}&site_ids=#{f.site_b.id}", pat)
      assert foreign.status == 200
      assert body(foreign)["volume"] == 0
    end

    test "an unauthenticated caller is 401 and a PAT without `read` is 403" do
      f = two_teams()

      unauth =
        conn(:get, "/v1/deploy-ledger/census?#{@window}") |> Router.call(@opts)

      assert unauth.status == 401

      {:ok, deploy_only, _} =
        Accounts.create_personal_access_token(f.user_a, f.team_a, %{
          name: "launcher",
          abilities: ["deploy"]
        })

      # `deploy` IMPLIES `read` in the read direction (the ability table), so
      # this is a 200 — asserted so the gate's actual shape is pinned rather
      # than guessed at.
      assert call("/v1/deploy-ledger/census?#{@window}", deploy_only).status == 200
    end
  end

  ## ── 2. A teamless caller: 403 no_team, not 404 ────────────────────────────

  describe "a teamless caller" do
    test "gets 403 no_team — a 404 would lie about a route that exists" do
      # THE REASON, in one line: every 404 nil-team arm in this router belongs to
      # a PATH-ID route, where 404 correctly conflates "wrong team" with "no such
      # id". This route has NO path id, so 404 would deny the route itself.
      #
      # cch-w40-bl: the STATUS is 403, not 422. Holding no team is an AUTHORITY
      # answer — the body was fine, the caller simply holds no grant — and this
      # inline emitter now speaks the same shape `Auth.gate_role/4` has emitted
      # since cch-w38-s2, so one condition has exactly one wire answer.
      user = user_fixture()

      conn = call("/v1/deploy-ledger/census?#{@window}", session_token(user))

      assert conn.status == 403
      assert body(conn) == %{"error" => "forbidden", "reason" => "no_team", "scope" => "team"}
    end
  end

  ## ── 3. Junk ids never reach a binary_id column ────────────────────────────

  describe "the intersection is computed in Elixir, not in SQL" do
    test "?site_ids=nope answers 200 volume 0 and does not raise" do
      f = two_teams()

      conn = call("/v1/deploy-ledger/census?#{@window}&site_ids=nope", session_token(f.user_a))

      assert conn.status == 200
      b = body(conn)
      assert b["volume"] == 0
      assert b["sites"] == []
      assert b["scope"]["site_ids"] == []
    end

    test "COUNTER-PROOF: the same junk string in an SQL-side scope RAISES Ecto.Query.CastError" do
      # The 500 that was avoided, executed rather than asserted in prose. This is
      # what the "obvious" single-query design ships: the client string reaches
      # a binary_id column and Ecto refuses to build the query at all.
      assert_raise Ecto.Query.CastError, fn ->
        Repo.all(from(s in Site, where: s.id in ^["nope"]))
      end

      assert_raise Ecto.Query.CastError, fn ->
        DeployLedger.census(@from, @to, site_ids: ["nope"])
      end
    end

    test "a mixed list keeps the well-formed OWN id and drops the junk" do
      f = two_teams()

      conn =
        call(
          "/v1/deploy-ledger/census?#{@window}&site_ids=nope,#{f.site_a.id},",
          session_token(f.user_a)
        )

      assert conn.status == 200
      b = body(conn)
      assert b["scope"]["site_ids"] == [f.site_a.id]
      assert b["volume"] == 3
    end
  end

  ## ── 4. The predicate is in the QUERY, proved by consequence ───────────────

  describe "the scope narrows the SOURCE, not the rendered site list" do
    test "with site_limit 3, a quiet own site survives three louder foreign ones" do
      {_user_a, team_a} = owned_team()
      own = site_fixture(team_a)
      deployments!(own, failed(3))

      {_user_b, team_b} = owned_team()

      loud =
        for _ <- 1..3 do
          s = site_fixture(team_b)
          deployments!(s, failed(20))
          s
        end

      scoped = DeployLedger.census(@from, @to, site_limit: 3, site_ids: [own.id])

      # A post-filter over the rendered node would answer volume 63 / failed 60
      # (every fleet total untouched) AND would render the three loud sites while
      # dropping `own` entirely — `site_rows/2` sorts by volume and takes
      # site_limit BEFORE anything downstream could filter.
      assert scoped.volume == 3
      assert scoped.failed == 3
      assert Enum.map(scoped.sites, & &1.site_id) == [own.id]

      refute Enum.any?(loud, &(&1.id in Enum.map(scoped.sites, fn r -> r.site_id end))),
             "a louder foreign site survived a scoped census — the predicate is not in the query"

      # And the UNSCOPED census over the same rows still sees all four, so the
      # narrowing above is a real narrowing and not an empty fixture.
      unscoped = DeployLedger.census(@from, @to, site_limit: 10)
      assert unscoped.volume >= 63
    end

    test "an EMPTY scope is empty, and a nil scope is the whole fleet" do
      site = site_fixture(elem(owned_team(), 1))
      deployments!(site, failed(5))

      assert DeployLedger.census(@from, @to, site_ids: []).volume == 0
      assert DeployLedger.census(@from, @to, site_ids: nil).volume >= 5
      assert DeployLedger.census(@from, @to).volume >= 5
    end
  end

  ## ── 5. The scope line ─────────────────────────────────────────────────────

  describe "the scope line" do
    test "prints the team SLUG on every response, never the team_id" do
      f = two_teams()
      b = body(call("/v1/deploy-ledger/census?#{@window}", session_token(f.user_a)))

      assert b["scope"]["team"] == f.team_a.slug
      refute b["scope"]["team"] == f.team_a.id
      refute Map.has_key?(b["scope"], "team_id")
    end

    test "the site count names its population: REGISTERED sites, not sites that deployed" do
      {user, team} = owned_team()
      deployed = site_fixture(team)
      deployments!(deployed, live(2))
      # A registered site that has never deployed — the `auto-proof` shape. It is
      # inside the scope and absent from `sites`, and the count must say so.
      _never = site_fixture(team)

      b = body(call("/v1/deploy-ledger/census?#{@window}", session_token(user)))

      assert b["scope"]["registered_sites"] == 2
      assert length(b["sites"]) == 1
      assert rendered_site_ids(b) == [deployed.id]

      assert b["scope"]["registered_sites_population"] =~ "registered to this team"

      assert b["scope"]["registered_sites_population"] =~ "never",
             "the count must state that a site which never deployed is inside it"
    end

    test "the scope prints even when the answer is empty" do
      {user, _team} = owned_team()
      conn = call("/v1/deploy-ledger/census?#{@window}", session_token(user))

      assert conn.status == 200
      b = body(conn)
      assert b["scope"]["registered_sites"] == 0
      assert b["volume"] == 0
    end
  end

  ## ── 6. The window is still required ───────────────────────────────────────

  describe "the window" do
    test "422 invalid_window with no from/to — there is no default window here either" do
      {user, _team} = owned_team()
      conn = call("/v1/deploy-ledger/census", session_token(user))

      assert conn.status == 422
      assert body(conn)["error"] == "invalid_window"
    end
  end

  ## ── 7. ONE census computation ─────────────────────────────────────────────

  test "the team route reads the SAME census/3 as the operator route" do
    source = File.read!(Path.expand("../../lib/barkpark_cloud/deploy_ledger.ex", __DIR__))

    assert length(Regex.scan(~r/^\s*def census\(/m, source)) == 1,
           "a SECOND census entry point appeared in deploy_ledger.ex — the team route " <>
             "must scope the one that exists, never fork it"
  end
end
