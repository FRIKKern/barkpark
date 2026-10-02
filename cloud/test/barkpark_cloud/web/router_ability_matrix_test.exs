defmodule BarkparkCloud.Web.RouterAbilityMatrixTest do
  @moduledoc """
  THE ABILITY MATRIX — the whole PAT ability surface driven as a grid, plus the
  two invariants that make the grid safe to widen (site-spawner wave 10).

  Why this file exists. PAT abilities are minted EXCLUSIVELY (`root` collapses to
  ["root"], `deploy` collapses to ["deploy"] — `UserToken.normalize_abilities/1`,
  mirroring Coolify), so a `write` PAT holds literally ["write"] and carries no
  `read`. `require_ability/2` used to honour only the literal string plus `root`,
  which made the programmatic surface unusable: a write PAT could START a deploy
  (POST /v1/sites/:id/deploy) but was 403'd on the two GETs `bp cloud site
  deploy` itself walks — ListSites to resolve the handle, then the deployment
  poll. The prebuilt lane was UNWALKABLE by the credential it was designed for;
  it worked only because the stored `cloud_token` happened to be a session
  (root).

  The repair is an explicit READ-DIRECTION implication table in
  `BarkparkCloud.Web.Auth` (`write ⊇ read`, `deploy ⊇ read`, and nothing else).
  Three things are pinned here:

    1. THE GRID — every (credential × tier) cell, admitted or refused, including
       the ten formerly-refused read cells.
    2. THE REJECTED WIDENING — a `deploy` PAT is still refused by every
       write-gated route. `deploy ⊇ write` would hand a launch-only credential
       DELETE /v1/sites/:id; if anyone adds it, the PATCH pin reds.
    3. THE BLAST-RADIUS BOUND — every route gated on `read` is a GET. This is
       not a convention to remember: the test SCANS router.ex on each run and
       fails NAMING the offending route.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.{Auth, Router}

  @opts Router.init([])
  @password "correct-horse-battery"

  @router_source Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__)

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # An owner + a fresh team + a site + a deployment on that site — everything the
  # site-scoped rows of the matrix need to reach a real handler.
  defp scope do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")

    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "Site #{n}", slug: "site-#{n}"})
    {:ok, dep} = Registry.create_deployment(site, %{git_ref: "main", trigger: "manual"})

    %{user: user, team: team, site: site, deployment: dep}
  end

  defp pat(%{user: user, team: team}, abilities) do
    {:ok, token, stored} =
      Accounts.create_personal_access_token(user, team, %{
        name: "matrix-#{Enum.join(abilities, "-")}-#{System.unique_integer([:positive])}",
        abilities: abilities
      })

    {token, stored}
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  # The session twin of `call/4` — the team-role and platform-operator gates are
  # reachable only by a browser credential (a PAT carries no team role axis).
  defp session_call(method, path, body, user) do
    call(method, path, body, session_token(user))
  end

  defp call(method, path, body, token) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  ## The route census the matrix drives, derived from the gates in router.ex.

  # The five READ-gated routes — all GET (machine-checked below). These are the
  # ten flip cells: {write, deploy} × these five.
  #
  # `GET /v1/sites/:id/deployments` joined this list in the D219 re-tiering
  # (dr-w14-bl-pat-cannot-read-the-owners-number). It spent its whole life in
  # `session_routes/1` below, pinned at 401 for EVERY PAT tier; the pin's own
  # comment said "when it IS re-tiered, this test flips to admitted and the flip
  # is the proof". This is that flip. It is the only route that can express a
  # DENOMINATOR — a window of deployments rather than the single row the poll
  # returns — so it is what lets an automation credential compute the site
  # owner's own deploy number at all.
  defp read_routes(%{site: site, deployment: dep}) do
    [
      {:get, "/v1/me", nil},
      {:get, "/v1/barkparks", nil},
      {:get, "/v1/sites", nil},
      {:get, "/v1/sites/#{site.id}/deployments", nil},
      {:get, "/v1/sites/#{site.id}/deployments/#{dep.id}", nil}
    ]
  end

  # The six WRITE-gated routes. A `deploy` PAT must be refused by every one of
  # them — that is the rejected `deploy ⊇ write` widening, tripwired.
  defp write_routes(%{site: site, deployment: dep}) do
    [
      {:patch, "/v1/sites/#{site.id}", %{name: "Renamed"}},
      {:post, "/v1/sites/#{site.id}/deploy", %{artifact_url: "file:///tmp/a.tar.gz"}},
      {:post, "/v1/sites/#{site.id}/rollback", %{}},
      {:post, "/v1/sites/#{site.id}/deployments/#{dep.id}/promote", %{}},
      {:post, "/v1/sites/#{site.id}/deployments/#{dep.id}/artifact", %{}},
      # DELETE is driven LAST: on the admitted row it destroys the site, and every
      # later row would then answer 404 (admitted, but vacuously so).
      {:delete, "/v1/sites/#{site.id}", nil}
    ]
  end

  # The SESSION-TIER read (deploy-reliability W14 S4, narrowed to one by the D219
  # re-tiering). It is not gated on an ability at all: `GET /v1/sites/:id` calls
  # `Auth.require_user/2` directly, so NO PAT of any tier reaches it — the refusal
  # is 401 (no session token was ever seen), never the ability gate's 403. It was
  # ABSENT from @driven_routes entirely, and the census's own anti-vacuity
  # tripwire (`missing_routes/1`) only polices routes already IN the census — so
  # an absent route is invisible to it and nothing asserted its tier in EITHER
  # direction.
  #
  # ITS FORMER TWIN, `GET /v1/sites/:id/deployments`, MOVED to `read_routes/1`:
  # the D219 ruling re-tiered the LIST route and only the list route. The
  # single-site read stays session-only and stays pinned here, so this census
  # still proves the session tier is a live tier and not an empty one — and so a
  # future widening of `/v1/sites/:id` has to delete an assertion rather than
  # slip past one.
  defp session_routes(%{site: site}) do
    [
      {:get, "/v1/sites/#{site.id}", nil}
    ]
  end

  # The same census in router.ex's own spelling, checked against the source on
  # every run (§4 below).
  #
  # Why this list exists. The census above substitutes real ids, so a route that
  # has been DELETED answers 404 — and 404 is admitted-shaped: `assert_admitted`
  # deliberately allows it, because a live handler may legitimately 404 on its
  # own terms. `POST /v1/sites/:id/artifact` was deleted as legacy (#7867) and
  # sat in this census afterwards, passing the three admitted rows vacuously
  # while the two refusal rows reddened with a status nobody could read as
  # "the route is gone". This pin makes the deletion the loud failure instead.
  @driven_routes [
    {"get", "/v1/me"},
    {"get", "/v1/barkparks"},
    {"get", "/v1/sites"},
    # Re-tiered from `:session` to `{:ability, "read"}` by D219
    # (dr-w14-bl-pat-cannot-read-the-owners-number). It stays in @driven_routes
    # across the move — that is the point of this list: the ROUTE is pinned as
    # existing, and which census drives it is what says the tier.
    {"get", "/v1/sites/:id/deployments"},
    {"get", "/v1/sites/:id/deployments/:dep_id"},
    # The session-tier read — in the census so a deletion is loud, and driven
    # below so its tier is asserted at all.
    {"get", "/v1/sites/:id"},
    {"patch", "/v1/sites/:id"},
    {"post", "/v1/sites/:id/deploy"},
    {"post", "/v1/sites/:id/rollback"},
    {"post", "/v1/sites/:id/deployments/:dep_id/promote"},
    {"post", "/v1/sites/:id/deployments/:dep_id/artifact"},
    {"delete", "/v1/sites/:id"},
    {"post", "/v1/go-live"}
  ]

  # router.ex writes routes two ways — `post "/p" do … end` and the one-liner
  # `post("/p", do: …)`. Both are scanned; missing either would make this
  # tripwire fail-open on the very spelling it is meant to police.
  defp declared_routes(source) do
    ~r/^\s*(get|post|patch|put|delete)\(?\s*"([^"]+)"/m
    |> Regex.scan(source)
    |> Enum.map(fn [_, verb, path] -> {verb, path} end)
    |> MapSet.new()
  end

  defp missing_routes(source) do
    declared = declared_routes(source)
    Enum.reject(@driven_routes, &MapSet.member?(declared, &1))
  end

  defp missing_message(missing) do
    listed =
      missing
      |> Enum.map(fn {verb, path} -> "  #{String.upcase(verb)} #{path}" end)
      |> Enum.join("\n")

    "the matrix drives #{length(missing)} route(s) router.ex no longer declares:\n" <>
      listed <>
      "\n\nA deleted route answers 404, which the admitted rows accept — so the " <>
      "census would keep passing on a route that does not exist. Delete the row " <>
      "from read_routes/write_routes AND from @driven_routes, or restore the route."
  end

  defp label(method, path), do: "#{method |> Atom.to_string() |> String.upcase()} #{path}"

  # "Admitted" means the ability gate PASSED — the request reached the handler.
  # It deliberately does not mean 200: a handler may still answer 404/422 on its
  # own terms. 401 (no credential) and 403 (forbidden) are the gate's own voices.
  defp assert_admitted(status, who, method, path) do
    refute status in [401, 403],
           "#{who} should be ADMITTED by #{label(method, path)} but got #{status}"
  end

  defp assert_refused(status, who, method, path) do
    assert status == 403,
           "#{who} should be REFUSED 403 by #{label(method, path)} but got #{status}"
  end

  ## 1. The implication table itself

  describe "the ability implication table" do
    test "runs in the read direction only — root ⊇ all, write/deploy ⊇ read, and no more" do
      table = Auth.ability_implies()

      assert Enum.sort(table["root"]) == ~w(deploy read root write)
      assert Enum.sort(table["write"]) == ~w(read write)
      assert Enum.sort(table["deploy"]) == ~w(deploy read)
      assert table["read"] == ~w(read)

      # The two REJECTED implications, stated as pins so a future widening has to
      # delete an assertion rather than slip past one.
      refute "write" in table["deploy"]
      refute "deploy" in table["write"]
      refute "root" in table["write"]
      refute "root" in table["deploy"]
    end
  end

  ## 2. The grid

  describe "read-gated routes (the ten flip cells)" do
    test "a write PAT is admitted by all five read-gated GETs" do
      s = scope()
      {token, _} = pat(s, ["write"])

      for {method, path, body} <- read_routes(s) do
        conn = call(method, path, body, token)
        assert_admitted(conn.status, "a write PAT", method, path)
      end
    end

    test "a deploy PAT is admitted by all five read-gated GETs" do
      s = scope()
      {token, stored} = pat(s, ["deploy"])
      # The mint is exclusive: asking for deploy yields exactly ["deploy"].
      assert stored.abilities == ["deploy"]

      for {method, path, body} <- read_routes(s) do
        conn = call(method, path, body, token)
        assert_admitted(conn.status, "a deploy PAT", method, path)
      end
    end

    test "a read PAT and a root PAT are admitted by all five" do
      s = scope()
      {read_token, _} = pat(s, ["read"])
      {root_token, _} = pat(s, ["root"])

      for {method, path, body} <- read_routes(s) do
        assert_admitted(call(method, path, body, read_token).status, "a read PAT", method, path)
        assert_admitted(call(method, path, body, root_token).status, "a root PAT", method, path)
      end
    end

    test "the read-gated GETs answer real payloads to a write PAT, not just a passing gate" do
      s = scope()
      {token, _} = pat(s, ["write"])

      me = call(:get, "/v1/me", nil, token)
      assert me.status == 200
      assert Jason.decode!(me.resp_body)["user"]["email"] == s.user.email

      sites = call(:get, "/v1/sites", nil, token)
      assert sites.status == 200
      assert [%{"id" => id}] = Jason.decode!(sites.resp_body)["sites"]
      assert id == s.site.id

      poll = call(:get, "/v1/sites/#{s.site.id}/deployments/#{s.deployment.id}", nil, token)
      assert poll.status == 200
      assert Jason.decode!(poll.resp_body)["deployment"]["id"] == s.deployment.id

      # The D219 re-tiering, asserted on the PAYLOAD and not on the gate. An
      # admitted status proves the door opened; only ROWS prove the credential can
      # compute a number. This is the whole point of the widening: the poll above
      # returns one row and can state an outcome, this returns a WINDOW and can
      # state a rate.
      list = call(:get, "/v1/sites/#{s.site.id}/deployments", nil, token)
      assert list.status == 200
      body = Jason.decode!(list.resp_body)
      assert [%{"id" => dep_id, "site_id" => site_id}] = body["deployments"]
      assert dep_id == s.deployment.id
      assert site_id == s.site.id
      assert Map.has_key?(body, "next_cursor")
    end
  end

  ## 2a. The session tier (deploy-reliability W14 S4, narrowed by D219)

  # `GET /v1/sites/:id` is what is LEFT of this tier. Its former twin, the
  # deployments LIST, was re-tiered to {:ability, "read"} by D219's cross-epic
  # ruling (dr-w14-bl-pat-cannot-read-the-owners-number) and now lives in
  # `read_routes/1`; the flip of that one route out of this census IS the proof
  # the ruling was carried out, exactly as the old comment here promised.
  #
  # The remaining pin is still load-bearing, and for the same reason it always
  # was: it proves the session tier is a LIVE tier with a member in it, so
  # "every PAT tier is 401 here" cannot go vacuous by the tier emptying out.
  describe "session-tier reads (no PAT reaches them)" do
    test "EVERY PAT tier is 401 on the session-tier read — a credential class, not an ability" do
      s = scope()

      for abilities <- [["read"], ["write"], ["deploy"], ["root"]] do
        {token, _} = pat(s, abilities)
        who = "a #{Enum.join(abilities, "+")} PAT"

        for {method, path, body} <- session_routes(s) do
          conn = call(method, path, body, token)

          assert conn.status == 401,
                 "#{who} should be 401 (session-only route) at #{label(method, path)}, got #{conn.status}"

          # 401, never 403: `Auth.require_user/2` never saw a session token, so the
          # ability gate is not even consulted. A 403 here would mean the route had
          # been re-tiered onto the ability axis.
          assert Jason.decode!(conn.resp_body)["error"] == "unauthorized"
        end
      end

      # ...while a root PAT DOES reach the one-deployment poll one segment deeper,
      # so the refusal above is about the route's tier and not about the token.
      {root_token, _} = pat(s, ["root"])

      assert call(:get, "/v1/sites/#{s.site.id}/deployments/#{s.deployment.id}", nil, root_token).status ==
               200
    end

    test "a session IS admitted — and by role BLINDNESS, not by an owner grant" do
      s = scope()

      for {method, path, body} <- session_routes(s) do
        conn = session_call(method, path, body, s.user)
        assert_admitted(conn.status, "a session", method, path)
        assert conn.status == 200
      end

      # The role axis is not consulted at all: a plain member of the SAME team
      # reads it. The mutation proof for this lives in router_sites_test.exs.
      member = user_fixture()
      {:ok, _} = Accounts.add_member(s.team, member, "member")

      for {method, path, body} <- session_routes(s) do
        conn = session_call(method, path, body, member)

        assert conn.status == 200,
               "a team MEMBER should read #{label(method, path)}, got #{conn.status}"
      end
    end
  end

  ## 2c. THE D219 WIDENING, DRIVEN FROM THE LOW-PRIVILEGE SIDE

  # Proving the read PAT CAN now list deployments is only half of an authority
  # change; the half that matters is what is STILL refused. A fence that fails
  # open is invisible to every test written from the admitted side, because the
  # admitted side passes either way.
  #
  # Three refusals, each a different axis, each driven against the SAME live
  # route the flip above admits:
  #
  #   * NO CREDENTIAL — 401. The widening moved the route from `require_user` to
  #     `require_user_or_pat` + `require_ability`; both halt an anonymous caller,
  #     but only a driven arm can say which one this route now runs.
  #   * A NON-MEMBER's PAT — 404, naming the site id explicitly. The token is a
  #     real, valid, read-ability PAT; its holder is simply not in the owning
  #     team. It must not be able to read its way in by naming the id.
  #   * A CROSS-TENANT PAT — 404, again by explicit id. Team B's owner holds a
  #     read PAT for team B and asks for team A's site. `with_team_site/3`
  #     resolves through `Registry.get_team_site(current_team, id)`, so a foreign
  #     id is the same 404 as one that never existed: an EXISTENCE leak would be
  #     a 403, which says "that exists and you may not have it".
  #
  # The bound on the widening, stated so the next reader does not have to infer
  # it: `read` is the FLOOR of the ability lattice (`Auth.ability_implies/0` —
  # write ⊇ read, deploy ⊇ read, root ⊇ all), so there is no PAT tier that holds
  # an ability and is refused by a `read` gate. That is why the refusal arms here
  # are on the TENANT and CREDENTIAL axes and not on the ability axis: on a
  # read-gated route the ability axis has no low side to test, and an arm
  # pretending otherwise would be asserting a refusal the lattice cannot produce.
  describe "the re-tiered deployments list (D219) refuses from below" do
    test "an unauthenticated caller is 401 — no credential, no list" do
      s = scope()

      conn = Router.call(conn(:get, "/v1/sites/#{s.site.id}/deployments"), @opts)

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "unauthorized"
    end

    test "a NON-MEMBER's read PAT is 404 on the owner's site id — not 403, not 200" do
      s = scope()

      # A real read PAT, minted for a team that is not the site's. Its holder has
      # never been a member of `s.team`.
      outsider = user_fixture()
      outsider_team = team_fixture()
      {:ok, _} = Accounts.add_member(outsider_team, outsider, "owner")

      {:ok, token, stored} =
        Accounts.create_personal_access_token(outsider, outsider_team, %{
          name: "outsider-read-#{System.unique_integer([:positive])}",
          abilities: ["read"]
        })

      # The token is genuinely read-capable: it is admitted by a read-gated route
      # of its OWN. Without this the 404 below could just mean "broken token".
      assert stored.abilities == ["read"]
      assert call(:get, "/v1/sites", nil, token).status == 200

      conn = call(:get, "/v1/sites/#{s.site.id}/deployments", nil, token)

      assert conn.status == 404,
             "an outsider's read PAT should be 404 on another team's site, got #{conn.status}"

      assert Jason.decode!(conn.resp_body)["error"] == "not_found"

      # And it read NOTHING: no deployments key at all, so the refusal cannot be
      # an empty-list-shaped success that a caller would render as "zero deploys".
      refute Map.has_key?(Jason.decode!(conn.resp_body), "deployments")
    end

    test "CROSS-TENANT: team B's root PAT naming team A's site id gets the same 404 as a nonexistent id" do
      a = scope()
      b = scope()

      # The strongest PAT that exists, on the wrong tenant — so the refusal below
      # cannot be read as an ability shortfall.
      {b_token, _} = pat(b, ["root"])

      # Its own team's list is 200 with its own row: the token works, the route
      # works, and the tenant fence is the ONLY thing that differs between this
      # call and the next one.
      own = call(:get, "/v1/sites/#{b.site.id}/deployments", nil, b_token)
      assert own.status == 200
      assert [%{"id" => id}] = Jason.decode!(own.resp_body)["deployments"]
      assert id == b.deployment.id

      # The SAME token, naming team A's site id explicitly.
      foreign = call(:get, "/v1/sites/#{a.site.id}/deployments", nil, b_token)

      assert foreign.status == 404,
             "team B's root PAT should be 404 on team A's site id, got #{foreign.status}"

      assert Jason.decode!(foreign.resp_body)["error"] == "not_found"

      # Byte-identical to a site id that does not exist anywhere — that identity
      # is the existence-leak protection, and it is what a 403 would break.
      absent = call(:get, "/v1/sites/#{Ecto.UUID.generate()}/deployments", nil, b_token)
      assert absent.status == 404
      assert foreign.resp_body == absent.resp_body
    end

    test "the fence is the TEAM's, not the ROLE's: a plain member's read PAT lists its own team" do
      s = scope()

      member = user_fixture()
      {:ok, _} = Accounts.add_member(s.team, member, "member")

      {:ok, token, _} =
        Accounts.create_personal_access_token(member, s.team, %{
          name: "member-read-#{System.unique_integer([:positive])}",
          abilities: ["read"]
        })

      conn = call(:get, "/v1/sites/#{s.site.id}/deployments", nil, token)

      assert conn.status == 200
      assert [%{"id" => id}] = Jason.decode!(conn.resp_body)["deployments"]
      assert id == s.deployment.id
    end
  end

  describe "write-gated routes" do
    test "THE REJECTED WIDENING: a deploy PAT is refused by every write-gated route" do
      s = scope()
      {token, _} = pat(s, ["deploy"])

      for {method, path, body} <- write_routes(s) do
        conn = call(method, path, body, token)
        assert_refused(conn.status, "a deploy PAT", method, path)
        assert Jason.decode!(conn.resp_body)["error"] == "forbidden"
      end

      # The site it was refused on is still there — nothing leaked through the
      # DELETE row.
      assert Registry.get_site(s.site.id)
    end

    test "a read PAT is refused by every write-gated route" do
      s = scope()
      {token, _} = pat(s, ["read"])

      for {method, path, body} <- write_routes(s) do
        assert_refused(call(method, path, body, token).status, "a read PAT", method, path)
      end
    end

    test "a write PAT is admitted by every write-gated route" do
      s = scope()
      {token, _} = pat(s, ["write"])

      for {method, path, body} <- write_routes(s) do
        conn = call(method, path, body, token)
        assert_admitted(conn.status, "a write PAT", method, path)
      end
    end
  end

  describe "deploy-gated routes (credential-aware)" do
    test "only a deploy PAT reaches go-live; read and write PATs are refused" do
      s = scope()
      {:ok, _sub} = BarkparkCloud.Billing.subscribe(s.team, "supporter")

      {deploy_token, _} = pat(s, ["deploy"])
      {read_token, _} = pat(s, ["read"])
      {write_token, _} = pat(s, ["write"])

      assert call(:post, "/v1/go-live", %{name: "Matrix Box"}, deploy_token).status == 201

      assert_refused(
        call(:post, "/v1/go-live", %{name: "No"}, read_token).status,
        "a read PAT",
        :post,
        "/v1/go-live"
      )

      assert_refused(
        call(:post, "/v1/go-live", %{name: "No"}, write_token).status,
        "a write PAT",
        :post,
        "/v1/go-live"
      )
    end
  end

  describe "no credential" do
    test "an unauthenticated request to a read-gated GET is 401, not 403" do
      conn = Router.call(conn(:get, "/v1/sites"), @opts)
      assert conn.status == 401
    end
  end

  ## 2b. THE REFUSAL NAMES THE AUTHORITY IT REQUIRED (cch w35 s1)

  # A 403 whose whole body is `{"error":"forbidden"}` tells the caller nothing
  # about WHAT would have admitted them, which is why the console had to guess a
  # cause from one global slug map and printed "Only the team owner can manage
  # billing" for an audit-trail read. Every refusal that flows through
  # `Auth.forbidden/2` now carries the authority it actually required, plus the
  # scope that authority lives in. These are the guards that can LOSE: delete an
  # evidence pair from auth.ex and the matching assertion below reds by name.
  #
  # The pairs are asserted by FULL-MAP equality on purpose — an assertion that
  # only keys into ["error"] cannot notice a field going missing.
  describe "a refusal names the authority it required" do
    test "require_ability names the ability and the token scope" do
      s = scope()
      {token, _} = pat(s, ["deploy"])

      conn = call(:patch, "/v1/sites/#{s.site.id}", %{name: "Renamed"}, token)

      assert conn.status == 403

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "forbidden",
               "required" => "write",
               "scope" => "token"
             }
    end

    # cch-w37-s3: the label is "team", not "primary_team" — the gate reads
    # conn.assigns[:current_team], which resolve_team/2 fills from the
    # x-barkpark-team header, so it judges the SELECTED team, not the primary one.
    test "require_current_team_admin names admin on the current team (the audit-trail exhibit)" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "member")

      conn = session_call(:get, "/v1/audit", nil, user)

      assert conn.status == 403

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "forbidden",
               "required" => "admin",
               "scope" => "team"
             }
    end

    test "require_current_team_owner names owner, so an ADMIN is told what they still lack" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "admin")

      conn = session_call(:post, "/v1/billing/checkout", %{}, user)

      assert conn.status == 403

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "forbidden",
               "required" => "owner",
               "scope" => "team"
             }
    end

    # cch-w38-s2: ONE CONDITION, ONE ANSWER. Both primary-team gates used to
    # answer a TEAMLESS caller `422 {error: "no_team"}` — the status that means
    # "your body was unprocessable" handed to a caller whose body was fine and
    # who simply holds no grant. `gate_role/4` already answered the same
    # condition 403. These two pins are the fail-before proof: against
    # origin/main's bytes they red on `assert conn.status == 403` (got 422), and
    # they are the ONLY pins that exist on these two arms — the rest of the
    # suite is green in BOTH directions, which is exactly why the flip needed a
    # test that can lose.
    #
    # `scope` is "team", matching the two required-role refusals
    # above, so each gate emits ONE scope label. The INLINE
    # `json(conn, 422, %{error: "no_team"})` emitters in router.ex were the other
    # half of this contract, and cch-w40-bl finished the job: the nine REACHABLE
    # ones now emit this exact shape through the shared `no_team/1` helper (which
    # delegates to `Auth.forbidden/2`), and the five that sat behind a halting
    # gate were DELETED as unreachable. `bp` survived the status change because
    # the CLI half landed first (cch-w40-s4, PR #11711): it keys its narration on
    # the CAUSE, never the status. Driven proof, per route:
    # test/barkpark_cloud/web/router_no_team_gate_shape_test.exs.
    test "require_current_team_admin answers a TEAMLESS caller 403 no_team, not 422" do
      user = user_fixture()

      conn = session_call(:get, "/v1/audit", nil, user)

      assert conn.status == 403

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "forbidden",
               "reason" => "no_team",
               "scope" => "team"
             }
    end

    test "require_current_team_owner answers a TEAMLESS caller 403 no_team, not 422" do
      user = user_fixture()

      conn = session_call(:post, "/v1/billing/checkout", %{}, user)

      assert conn.status == 403

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "forbidden",
               "reason" => "no_team",
               "scope" => "team"
             }
    end

    test "require_platform_operator names the platform allowlist, not a team role" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "owner")

      conn = session_call(:get, "/v1/operator/autoupdate", nil, user)

      assert conn.status == 403

      # A team OWNER is still refused here, and the body says why: this axis is
      # the platform allowlist, which no team grant can reach.
      #
      # dr-bl-w8-census-403-cannot-say-the-list-is-empty — the gate now splits
      # its 403 into two arms and the UNCONFIGURED one carries an additive
      # `allowlist` marker. Which arm this test takes depends on
      # `:platform_admin_emails`, which is process-global Application config
      # other suites own, and this module is `async: true` — so the arm marker
      # is dropped here and the AUTHORITY evidence (identical on both arms) is
      # still asserted as an exact map, extra keys and all. The two arms
      # themselves are pinned side by side in `router_operator_test.exs`.
      body = Jason.decode!(conn.resp_body)

      assert Map.drop(body, ["allowlist"]) == %{
               "error" => "forbidden",
               "required" => "platform_operator",
               "scope" => "platform"
             }
    end

    test "require_team_role names the min_role the route asked for, on the team scope" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "member")

      conn =
        session_call(
          :post,
          "/v1/teams/#{team.id}/invitations",
          %{"email" => "x@example.com"},
          user
        )

      assert conn.status == 403

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "forbidden",
               "required" => "admin",
               "scope" => "team"
             }
    end

    test "gate_role names the label its opaque check cannot introspect" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "member")

      conn = session_call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/credentials", nil, user)

      assert conn.status == 403

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "forbidden",
               "required" => "admin",
               "scope" => "team"
             }
    end

    test "the no-team arm states a CAUSE and never an authority" do
      # NOT `required: "admin"`. This user holds no team grant at all, so no role
      # would have admitted them; naming one would be a second confidently-wrong
      # sentence, which is the exact failure this slice exists to remove.
      user = user_fixture()

      conn = session_call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/credentials", nil, user)

      assert conn.status == 403

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "forbidden",
               "reason" => "no_team",
               "scope" => "team"
             }

      refute Map.has_key?(Jason.decode!(conn.resp_body), "required")
    end

    test "evidence is ADDITIVE — the `forbidden` slug 21 assertions pin is untouched" do
      s = scope()
      {token, _} = pat(s, ["deploy"])

      conn = call(:patch, "/v1/sites/#{s.site.id}", %{name: "Renamed"}, token)

      assert Jason.decode!(conn.resp_body)["error"] == "forbidden"
    end
  end

  ## 3. The blast-radius bound — scanned out of router.ex on every run

  describe "the read-gate bound is machine-checked against router.ex" do
    test "every route gated on the read ability is a GET" do
      gates = scan_read_gated(File.read!(@router_source))

      assert length(gates) >= 4,
             "expected to find the read-ability gates in router.ex, found #{length(gates)} — has the gate spelling changed?"

      offenders = Enum.reject(gates, &(&1.verb == "get"))

      assert offenders == [], offense_message(offenders)
    end

    test "the four routes the matrix drives are still the read-gated ones" do
      scanned = scan_read_gated(File.read!(@router_source)) |> Enum.map(& &1.path) |> MapSet.new()

      for path <- ["/v1/me", "/v1/barkparks", "/v1/sites", "/v1/sites/:id/deployments/:dep_id"] do
        assert MapSet.member?(scanned, path),
               "#{path} is no longer gated on the read ability — the matrix above is stale"
      end
    end

    test "the scanner FAILS NAMING a mutating route if one ever takes a read gate" do
      # A synthetic router in which POST /v1/sites/:id/rollback has been re-gated
      # on read — the exact mutation this invariant exists to catch. Proving the
      # detector on a fixture keeps the tripwire honest without editing router.ex.
      mutated = """
        get "/v1/sites" do
          conn = conn |> Auth.require_user_or_pat([]) |> Auth.require_ability("read")
        end

        post "/v1/sites/:id/rollback" do
          with_team_site(conn, {:ability, "read"}, fn conn, site ->
            rollback(conn, site)
          end)
        end
      """

      gates = scan_read_gated(mutated)
      offenders = Enum.reject(gates, &(&1.verb == "get"))

      assert [%{verb: "post", path: "/v1/sites/:id/rollback"}] = offenders

      message = offense_message(offenders)
      assert message =~ "read-gated NON-GET route"
      assert message =~ "POST /v1/sites/:id/rollback"
    end

    test "the scanner CATCHES and CORRECTLY NAMES a read-gated ONE-LINER non-GET" do
      # THE PROPERTY, not a pair of route names: when a read gate sits under the
      # paren route spelling, the offender named must be THAT route — never
      # whichever multi-line macro happened to precede it. Two fixtures, because
      # the pre-fix scanner failed in two different ways depending on what came
      # before, and only one of them was even visible:
      #
      #   MISATTRIBUTION — the preceding multi-line macro is a non-GET, so the
      #   stale `current` reds the bound while NAMING THE WRONG ROUTE and sending
      #   the fixer to a route that is correctly gated.
      #
      #   SILENT MISS — the preceding multi-line macro is a GET, so `current`
      #   reads as a GET, the offender list is empty and the gate is INVISIBLE.
      #
      # Measured on the pre-fix `route_re` (`\s+"` instead of `\s*\(?\s*"`):
      # the first fixture named POST /v1/sites/:id/deploy, the second named
      # nothing at all. Both now name the one-liner.
      misattributing = """
        post "/v1/sites/:id/deploy" do
          with_team_site(conn, {:ability, "write"}, fn conn, site -> deploy(conn, site) end)
        end

        post("/v1/sites/:id/rollback") do
          with_team_site(conn, {:ability, "read"}, fn conn, site -> rollback(conn, site) end)
        end
      """

      silently_missed = """
        get "/v1/sites" do
          conn = conn |> Auth.require_user_or_pat([]) |> Auth.require_ability("read")
        end

        post("/v1/sites/:id/rollback") do
          with_team_site(conn, {:ability, "read"}, fn conn, site -> rollback(conn, site) end)
        end
      """

      for {label, source} <- [
            {"misattributing", misattributing},
            {"silently missed", silently_missed}
          ] do
        offenders = scan_read_gated(source) |> Enum.reject(&(&1.verb == "get"))

        # Compared as a plain list, NOT as `assert pattern = offenders`: a
        # pattern match raises MatchError before assert/2 ever runs, which
        # would make the sentence below dead code on the very failure it
        # exists to explain.
        assert Enum.map(offenders, &{&1.verb, &1.path}) == [{"post", "/v1/sites/:id/rollback"}],
               "the #{label} fixture must name the ONE-LINER route that carries the read gate, " <>
                 "got #{inspect(Enum.map(offenders, &{&1.verb, &1.path}))}"

        assert offense_message(offenders) =~ "POST /v1/sites/:id/rollback"
      end
    end

    test "the scanner ignores commented-out gates and the generic with_team_site clause" do
      source = """
        # AUTH: `{:ability, "read"}`, not the session default — a comment, not a gate.
        post "/v1/sites/:id/deploy" do
          with_team_site(conn, {:ability, "write"}, fn conn, site -> deploy(conn, site) end)
        end

        defp with_team_site(conn, auth, fun) do
          case auth do
            {:ability, ab} -> conn |> Auth.require_user_or_pat([]) |> Auth.require_ability(ab)
          end
        end
      """

      assert scan_read_gated(source) == []
    end
  end

  ## 4. The census bound — every route the matrix drives still exists

  describe "the driven-route census is machine-checked against router.ex" do
    test "every route the matrix drives is still declared in router.ex" do
      missing = missing_routes(File.read!(@router_source))

      assert missing == [], missing_message(missing)
    end

    test "@driven_routes and the concrete census stay the same size" do
      s = %{
        site: %{id: "11111111-1111-1111-1111-111111111111"},
        deployment: %{id: "22222222-2222-2222-2222-222222222222"}
      }

      # read (4) + write (6) + session (2) + the one deploy-gated row, /v1/go-live.
      assert length(@driven_routes) ==
               length(read_routes(s)) + length(write_routes(s)) + length(session_routes(s)) + 1
    end

    test "the detector FAILS NAMING a route that has been deleted from router.ex" do
      # A synthetic router carrying every driven route EXCEPT the deployment
      # artifact upload — the exact shape of the #7867 deletion this pin exists
      # to catch. Proving the detector on a fixture keeps it honest without
      # editing router.ex.
      source =
        @driven_routes
        |> Enum.reject(&(&1 == {"post", "/v1/sites/:id/deployments/:dep_id/artifact"}))
        |> Enum.map_join("\n", fn {verb, path} -> "  #{verb} \"#{path}\" do\n  end\n" end)

      assert [{"post", "/v1/sites/:id/deployments/:dep_id/artifact"}] = missing_routes(source)

      message = missing_message(missing_routes(source))
      assert message =~ "POST /v1/sites/:id/deployments/:dep_id/artifact"
      assert message =~ "router.ex no longer declares"
    end

    test "the detector reads the one-liner route spelling too" do
      # `post("/v1/go-live", do: go_live(conn))` — router.ex uses both forms, and
      # a scanner blind to this one would silently pass a deleted go-live.
      assert MapSet.member?(
               declared_routes(~s|  post("/v1/go-live", do: go_live(conn))\n|),
               {"post", "/v1/go-live"}
             )
    end
  end

  # Attribute every literal read-ability gate in `source` to the route macro it
  # sits under. Comment lines are skipped (a doc comment naming a gate is not a
  # gate) and a `def`/`defp` boundary clears the current route, so a helper
  # defined after the last route cannot be misattributed to it.
  defp scan_read_gated(source) do
    # `\s*\(?\s*` mirrors `declared_routes/1` above: router.ex writes routes two
    # ways — `post "/p" do … end` and the paren spelling `post("/p") do … end` /
    # `post("/p", do: …)` — and requiring whitespace after the verb made this
    # scanner blind to the second one. Nine route macros in router.ex use it
    # (`post("/v1/launch")`, `post("/v1/go-live")`, `post("/v1/resurrect")`, the
    # dashboard and health GETs), and while `current` stayed stale from the last
    # multi-line macro a read gate under any of them was either MISATTRIBUTED to
    # the wrong route or missed outright. The sibling comment at the top of
    # `declared_routes/1` learned this lesson first; it now holds here too.
    route_re = ~r/^\s*(get|post|put|patch|delete|match)\s*\(?\s*"([^"]+)"/
    read_re = ~r/Auth\.require_ability\(\s*(?:conn,\s*)?"read"\s*\)|\{:ability,\s*"read"\}/
    def_re = ~r/^\s*defp?\s+[a-z_]/

    {_current, found} =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({nil, []}, fn {line, lineno}, {current, acc} ->
        cond do
          String.starts_with?(String.trim_leading(line), "#") ->
            {current, acc}

          match = Regex.run(route_re, line) ->
            [_, verb, path] = match
            {{verb, path}, acc}

          Regex.match?(def_re, line) ->
            {nil, acc}

          Regex.match?(read_re, line) and current != nil ->
            {verb, path} = current
            {current, [%{verb: verb, path: path, line: lineno} | acc]}

          true ->
            {current, acc}
        end
      end)

    Enum.reverse(found)
  end

  defp offense_message(offenders) do
    listed =
      Enum.map_join(offenders, ", ", fn o ->
        "#{String.upcase(o.verb)} #{o.path} (router.ex:#{o.line})"
      end)

    """
    read-gated NON-GET route(s) found in router.ex: #{listed}

    The read ability is widened INTO by `write` and `deploy` (Auth.ability_implies/0),
    so anything gated on `read` is reachable by every PAT tier. That widening is only
    safe while the read tier is READ-ONLY. Gate the route above on "write" (or
    "deploy"), or the implication table has to be narrowed instead.
    """
  end
end
