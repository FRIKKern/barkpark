defmodule BarkparkCloud.Web.MetricsRouteTest do
  @moduledoc """
  GET /v1/barkparks/:id/metrics (charter S12 / decisions 30-31): a window of the
  instance's health beats reduced to cpu/mem/disk/load series. Proves over the
  real HTTP path:

    * 200 with the pinned envelope; a live beat's vitals land in the series and
      beat.status is "live"
    * the agent's -1 sentinel becomes a JSON `null` point (nil-not-zero)
    * beat.status is live / stale / absent off Registry.health_stale_after_seconds()
    * points is clamped (default 30, cap 200) via the shared parse_limit idiom
    * a never-phoned-home instance is a normal 200 (absent beat, empty series),
      never a 500
    * auth: 401 unauthenticated; team-scope fail-closed → the SAME 404 for
      wrong-team / nonexistent / malformed ids

  Tagged `:metrics` so the slice's targeted gate (`mix test test/barkpark_cloud/web
  --only metrics`) runs exactly this module.
  """
  use BarkparkCloud.DataCase, async: true
  @moduletag :metrics

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  # Land a health beat, then force its inserted_at to `secs_ago` before now so a
  # live/stale window is deterministic without touching the global threshold.
  defp seed_health(bp, payload, secs_ago \\ 0) do
    {:ok, ev} = Registry.record_event(bp, "health", payload)
    at = DateTime.add(DateTime.utc_now(), -secs_ago, :second)
    ev |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end

  defp call(method, path, opts \\ []) do
    token = Keyword.get(opts, :token)
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp metrics(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /v1/barkparks/:id/metrics — the reduced envelope" do
    test "200 with a live beat; vitals land in the series" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      seed_health(bp, %{
        "cpu_percent" => 40,
        "mem_used_percent" => 55,
        "disk_used_percent" => 60,
        "load1" => 1.25,
        "health_checks" => [%{"name" => "tls", "pass" => true}]
      })

      conn = call(:get, "/v1/barkparks/#{bp.id}/metrics", token: session_token(user))
      assert conn.status == 200
      m = metrics(conn)

      assert m["ok"] == true
      assert m["instance"]["id"] == bp.id
      assert m["beat"]["status"] == "live"
      assert m["points"] == 30
      assert [%{"value" => 40}] = m["series"]["cpu"]
      assert [%{"value" => 55}] = m["series"]["mem"]
      assert [%{"value" => 60}] = m["series"]["disk"]
      assert [%{"value" => 1.25}] = m["series"]["load"]
      assert m["service_health"] == %{"pass" => 1, "total" => 1, "failing" => []}
    end

    test "the -1 unwired sentinel renders as a JSON null, not a zero" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      seed_health(bp, %{"cpu_percent" => 0, "disk_used_percent" => -1})

      conn = call(:get, "/v1/barkparks/#{bp.id}/metrics", token: session_token(user))
      m = metrics(conn)

      # cpu 0 is REAL data; disk -1 is the sentinel → null.
      assert [%{"value" => 0}] = m["series"]["cpu"]
      assert [%{"value" => nil}] = m["series"]["disk"]
    end

    test "a beat older than the stale threshold is stale" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      seed_health(bp, %{"cpu_percent" => 5}, Registry.health_stale_after_seconds() + 120)

      conn = call(:get, "/v1/barkparks/#{bp.id}/metrics", token: session_token(user))
      assert metrics(conn)["beat"]["status"] == "stale"
    end

    test "an instance that never phoned home is a normal 200, absent beat, empty series" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/metrics", token: session_token(user))
      assert conn.status == 200
      m = metrics(conn)

      assert m["beat"]["status"] == "absent"
      assert m["beat"]["last_seen_at"] == nil
      # The series envelope WIDENED with this slice: swap, beam_pss and beam_swap
      # join the original four. Kept as an EXACT equality rather than a subset
      # check — the envelope is a contract three runtimes read, so the next
      # widening SHOULD red here and be reviewed, which is the whole point of
      # asserting the shape instead of asserting "the values are empty".
      assert m["series"] == %{
               "cpu" => [],
               "mem" => [],
               "disk" => [],
               "load" => [],
               "swap" => [],
               "beam_pss" => [],
               "beam_swap" => []
             }

      assert m["service_health"] == %{"pass" => 0, "total" => 0, "failing" => []}
    end

    test "points is clamped: over-cap → 200, default → 30" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      token = session_token(user)

      over = call(:get, "/v1/barkparks/#{bp.id}/metrics?points=500", token: token)
      assert metrics(over)["points"] == 200

      default = call(:get, "/v1/barkparks/#{bp.id}/metrics", token: token)
      assert metrics(default)["points"] == 30
    end
  end

  describe "auth + team-scope fail-closed" do
    test "no auth → 401" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn = call(:get, "/v1/barkparks/#{bp.id}/metrics")
      assert conn.status == 401
    end

    test "wrong-team / nonexistent / malformed ids are the SAME 404" do
      {_owner_b, team_b} = user_with_team()
      bp_b = barkpark_fixture(team_b)

      {user_a, _team_a} = user_with_team()
      token_a = session_token(user_a)

      wrong_team = call(:get, "/v1/barkparks/#{bp_b.id}/metrics", token: token_a)
      nonexistent = call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/metrics", token: token_a)
      malformed = call(:get, "/v1/barkparks/not-a-uuid/metrics", token: token_a)

      assert wrong_team.status == 404
      assert nonexistent.status == 404
      assert malformed.status == 404

      assert Jason.decode!(wrong_team.resp_body) == Jason.decode!(nonexistent.resp_body)
      assert Jason.decode!(nonexistent.resp_body) == Jason.decode!(malformed.resp_body)
    end
  end
end
