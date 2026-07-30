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
       the eight formerly-refused read cells.
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

  # The four READ-gated routes — all GET (machine-checked below). These are the
  # eight flip cells: {write, deploy} × these four.
  defp read_routes(%{site: site, deployment: dep}) do
    [
      {:get, "/v1/me", nil},
      {:get, "/v1/barkparks", nil},
      {:get, "/v1/sites", nil},
      {:get, "/v1/sites/#{site.id}/deployments/#{dep.id}", nil}
    ]
  end

  # The seven WRITE-gated routes. A `deploy` PAT must be refused by every one of
  # them — that is the rejected `deploy ⊇ write` widening, tripwired.
  defp write_routes(%{site: site, deployment: dep}) do
    [
      {:patch, "/v1/sites/#{site.id}", %{name: "Renamed"}},
      {:post, "/v1/sites/#{site.id}/deploy", %{artifact_url: "file:///tmp/a.tar.gz"}},
      {:post, "/v1/sites/#{site.id}/rollback", %{}},
      {:post, "/v1/sites/#{site.id}/deployments/#{dep.id}/promote", %{}},
      {:post, "/v1/sites/#{site.id}/artifact", %{}},
      {:post, "/v1/sites/#{site.id}/deployments/#{dep.id}/artifact", %{}},
      # DELETE is driven LAST: on the admitted row it destroys the site, and every
      # later row would then answer 404 (admitted, but vacuously so).
      {:delete, "/v1/sites/#{site.id}", nil}
    ]
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

  describe "read-gated routes (the eight flip cells)" do
    test "a write PAT is admitted by all four read-gated GETs" do
      s = scope()
      {token, _} = pat(s, ["write"])

      for {method, path, body} <- read_routes(s) do
        conn = call(method, path, body, token)
        assert_admitted(conn.status, "a write PAT", method, path)
      end
    end

    test "a deploy PAT is admitted by all four read-gated GETs" do
      s = scope()
      {token, stored} = pat(s, ["deploy"])
      # The mint is exclusive: asking for deploy yields exactly ["deploy"].
      assert stored.abilities == ["deploy"]

      for {method, path, body} <- read_routes(s) do
        conn = call(method, path, body, token)
        assert_admitted(conn.status, "a deploy PAT", method, path)
      end
    end

    test "a read PAT and a root PAT are admitted by all four (unchanged)" do
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

  # Attribute every literal read-ability gate in `source` to the route macro it
  # sits under. Comment lines are skipped (a doc comment naming a gate is not a
  # gate) and a `def`/`defp` boundary clears the current route, so a helper
  # defined after the last route cannot be misattributed to it.
  defp scan_read_gated(source) do
    route_re = ~r/^\s*(get|post|put|patch|delete|match)\s+"([^"]+)"/
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
