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

  It also owns the two DB-BACKED proofs this slice adds, because they are the
  same route's window and the same box's event stream:

    * THE WINDOW IS TYPE-FILTERED AT THE FETCH. `points` counts BEATS, so a
      mixed stream (health beside the 15-minute `space` rows) must still render
      exactly `points` points. This assertion cannot live in `metrics_test.exs`:
      that file is PURE — it hands `build/3` a list it constructed itself and
      never touches the DB — so it is STRUCTURALLY incapable of seeing a defect
      that lives in the QUERY, however green it is.
    * POST /v1/agent/space lands one `space` event — and does none of the five
      things `/v1/agent/report` does.

  Tagged `:metrics` so the slice's targeted gate (`mix test test/barkpark_cloud/web
  --only metrics`) runs exactly this module.
  """
  use BarkparkCloud.DataCase, async: true
  @moduletag :metrics

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Events, Registry, Repo}
  alias BarkparkCloud.Notifications.Delivery
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

  # Land a `space` row (the agent's 15-minute disk report) directly, for the
  # mixed-stream window proofs. The ROUTE is exercised separately below.
  defp seed_space(bp, payload, secs_ago) do
    {:ok, ev} = Registry.record_event(bp, "space", payload)
    at = DateTime.add(DateTime.utc_now(), -secs_ago, :second)
    ev |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end

  defp call(method, path, opts \\ []) do
    token = Keyword.get(opts, :token)
    body = Keyword.get(opts, :body)

    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          method
          |> conn(path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

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
      assert m["service_health"] == %{"pass" => 1, "skipped" => 0, "total" => 1, "failing" => []}
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

      assert m["service_health"] == %{"pass" => 0, "skipped" => 0, "total" => 0, "failing" => []}
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

  describe "the window is a count of BEATS, over a mixed-type stream" do
    # THE MUTATION PROOF. Revert router.ex's read to the type-blind
    # Registry.recent_events/2 and these two go red with "29 == 30" and
    # "188 == 200" — the exact shortfall a production box (60s health beside a
    # 15-minute space row, 1 row in 16) renders while the envelope still claims
    # the full window.
    test "the default 30 renders 30 points even when a space row sits in the window" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      for secs <- 1..30, do: seed_health(bp, %{"cpu_percent" => secs}, secs)
      seed_space(bp, %{"root_used_bytes" => 42}, 5)

      conn = call(:get, "/v1/barkparks/#{bp.id}/metrics", token: session_token(user))
      m = metrics(conn)

      assert m["points"] == 30
      assert length(m["series"]["cpu"]) == 30
      # And the space row never becomes a point: no beat carries its shape.
      refute Enum.any?(m["series"]["cpu"], &is_nil(&1["value"]))
    end

    test "?points=200 renders 200 points beside 12 space rows" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      for secs <- 1..200, do: seed_health(bp, %{"cpu_percent" => 7}, secs)
      for secs <- Enum.take_every(5..115, 10), do: seed_space(bp, %{"root_used_bytes" => 1}, secs)

      conn = call(:get, "/v1/barkparks/#{bp.id}/metrics?points=200", token: session_token(user))
      m = metrics(conn)

      assert m["points"] == 200
      assert length(m["series"]["cpu"]) == 200
      # The envelope's `points` and the rendered series agree — the instrument
      # says what it drew.
      assert length(m["series"]["cpu"]) == m["points"]
    end
  end

  # ── The round trip: what the agent measured comes back out of the API ──────
  #
  # Every half of this existed and none of it connected. The agent has measured
  # root/journal/postgres/per-slug space and POSTed it since #9889;
  # `Telemetry.normalize_space/1` has been written and unit-tested since the
  # same PR; and no read route ever called it. The answer to "what is eating the
  # disk" sat in `agent_events` while the question still needed an SSH session.
  #
  # This is the DB-backed proof that it does not any more, and it belongs here
  # rather than in metrics_test.exs for the reason that file's own docstring
  # gives: metrics_test.exs hands `build/3` a list it constructed itself, so it
  # is structurally incapable of seeing a defect that lives in the QUERY.
  describe "the space row comes back OUT — diagnosis without an SSH session" do
    test "what the agent POSTs to /v1/agent/space is served by GET /metrics" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      # The agent's own route, with the agent's own body — not a hand-seeded row.
      post = call(:post, "/v1/agent/space", body: space_body(), token: agent_token(bp))
      assert post.status == 200

      m = metrics(call(:get, "/v1/barkparks/#{bp.id}/metrics", token: session_token(user)))
      space = m["space"]

      assert space, "the space row landed but no read surface serves it"
      # The three consumers that used to need an SSH session, by name and size.
      assert space["sites"]["dir"] == "/opt/barkpark/sites"
      assert space["sites"]["bytes"] == 4_400_000_000
      assert [%{"name" => "guerrilla", "bytes" => 3_000_000_000}] = space["sites"]["top"]
      assert space["db_size"] == 3_500_000_000
      assert [%{"name" => "documents"}] = space["top_relations"]
      assert space["journal_bytes"] == 900_000_000
      # The root travels as a PAIR, never a bare percent.
      assert space["root"]["used_bytes"] == 12_000_000_000
      assert space["root"]["total_bytes"] == 40_000_000_000
      # And it is dated: a 15-minute cadence read as live would be its own lie.
      assert is_binary(space["reported_at"])
    end

    test "the NEWEST space row wins — a stale breakdown never outranks a fresh one" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      seed_space(bp, %{"sites_bytes" => 1_000, "sites_count" => 2}, 3600)
      seed_space(bp, %{"sites_bytes" => 9_999, "sites_count" => 8}, 60)

      m = metrics(call(:get, "/v1/barkparks/#{bp.id}/metrics", token: session_token(user)))
      assert m["space"]["sites"]["bytes"] == 9_999
      assert m["space"]["sites"]["count"] == 8
    end

    test "the sites COUNT survives the whole trip, so the cap can say when it binds" do
      # Ten rows and a total read identically whether the tree holds ten or
      # forty. The count is the only thing that separates them, and it has to
      # survive the agent's cap, the jsonb round trip AND the read route.
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      top = for i <- 1..10, do: %{"slug" => "site-#{i}", "bytes" => 1_000 - i}

      assert call(:post, "/v1/agent/space",
               body: space_body(%{"sites_top" => top, "sites_count" => 37}),
               token: agent_token(bp)
             ).status == 200

      m = metrics(call(:get, "/v1/barkparks/#{bp.id}/metrics", token: session_token(user)))
      assert length(m["space"]["sites"]["top"]) == 10
      assert m["space"]["sites"]["count"] == 37
    end

    test "a box with no space row serves space: null, never a zeroed disk" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      seed_health(bp, %{"cpu_percent" => 5}, 10)

      m = metrics(call(:get, "/v1/barkparks/#{bp.id}/metrics", token: session_token(user)))
      assert m["space"] == nil
    end

    test "the verdict rides the same response, and an unread box is not called calm" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      # A box in guerrilla's recorded state: 93% swap, 2.02 load per core.
      seed_health(
        bp,
        %{
          "swap_used_percent" => 93,
          "mem_used_percent" => 92,
          "disk_used_percent" => 75,
          "load15" => 4.04,
          "cpu_cores" => 2
        },
        10
      )

      m = metrics(call(:get, "/v1/barkparks/#{bp.id}/metrics", token: session_token(user)))
      assert m["pressure"]["state"] == "struggling"
      assert m["pressure"]["measured"] == 4

      # And a box that has never reported a vital is UNKNOWN over the wire too —
      # the shape that let a 500ing box read `ok / healthy`.
      quiet = barkpark_fixture(team)
      q = metrics(call(:get, "/v1/barkparks/#{quiet.id}/metrics", token: session_token(user)))
      assert q["pressure"]["state"] == "unknown"
      refute q["pressure"]["state"] == "calm"
    end
  end

  describe "POST /v1/agent/space" do
    # The SpaceReport body (internal/agent/report.go) — the agent carries its
    # own `type` inline; the route hardcodes "space" and never reads it.
    defp space_body(overrides \\ %{}) do
      Map.merge(
        %{
          "type" => "space",
          "root_used_bytes" => 12_000_000_000,
          "root_total_bytes" => 40_000_000_000,
          "journal_bytes" => 900_000_000,
          "pg_size_bytes" => 3_500_000_000,
          "pg_top_relations" => [%{"name" => "documents", "bytes" => 2_100_000_000}],
          "sites_dir" => "/opt/barkpark/sites",
          "sites_bytes" => 4_400_000_000,
          "sites_top" => [%{"slug" => "guerrilla", "bytes" => 3_000_000_000}]
        },
        overrides
      )
    end

    defp agent_token(bp) do
      {:ok, plaintext, _} = Registry.mint_agent_token(bp, "report")
      plaintext
    end

    test "a valid agent token lands ONE space event verbatim → 200" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn =
        call(:post, "/v1/agent/space", body: space_body(), token: agent_token(bp))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"ok" => true}

      assert [%{type: "space", payload: payload}] =
               Registry.recent_events_of_type(bp, "space", 10)

      assert payload["root_used_bytes"] == 12_000_000_000
      assert payload["root_total_bytes"] == 40_000_000_000
      assert payload["sites_top"] == [%{"slug" => "guerrilla", "bytes" => 3_000_000_000}]
    end

    test "a BUILD-PLANE payload lands whole and the metrics envelope names its 25 GB" do
      # END TO END on the box's real shape (91.98.139.58, 2026-08-22): no
      # /opt/barkpark/sites at all, 14 GB in containerd and 11 GB in the
      # builder. Before consumer roots existed this payload named ~1 GB of a
      # 37 GB filesystem on the one box whose job is to fill a disk.
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      body =
        space_body(%{
          "sites_bytes" => -1,
          "sites_top" => nil,
          "sites_count" => -1,
          "consumer_roots" => [
            %{
              "path" => "/var/lib/containerd",
              "status" => "read",
              "bytes" => 15_032_385_536,
              "count" => 11,
              "top" => [
                %{"name" => "io.containerd.snapshotter.v1.overlayfs", "bytes" => 12_884_901_888}
              ]
            },
            %{
              "path" => "/var/lib/barkpark-builder",
              "status" => "read",
              "bytes" => 11_811_160_064,
              "count" => 2,
              "top" => [%{"name" => "images", "bytes" => 11_811_160_064}]
            },
            %{
              "path" => "/opt/barkpark/sites",
              "status" => "absent",
              "bytes" => -1,
              "count" => -1,
              "top" => nil
            }
          ]
        })

      conn = call(:post, "/v1/agent/space", body: body, token: agent_token(bp))
      assert conn.status == 200

      roots =
        metrics(call(:get, "/v1/barkparks/#{bp.id}/metrics", token: session_token(user)))
        |> get_in(["space", "consumer_roots"])

      assert length(roots) == 3,
             "the ABSENT root must reach the surface — a row that vanishes on the way " <>
               "is indistinguishable from a root that holds nothing"

      by_path = Map.new(roots, &{&1["path"], &1})

      assert by_path["/var/lib/containerd"]["bytes"] +
               by_path["/var/lib/barkpark-builder"]["bytes"] == 26_843_545_600

      assert by_path["/var/lib/containerd"]["top"] == [
               %{"name" => "io.containerd.snapshotter.v1.overlayfs", "bytes" => 12_884_901_888}
             ]

      absent = by_path["/opt/barkpark/sites"]
      assert absent["status"] == "absent"

      refute absent["bytes"] == 0,
             "the root the probe was originally pointed at is NOT on this box; rendering it " <>
               "as 0 bytes is the claim that let a 100%-full builder rank healthy"
    end

    test "the recorded type is HARDCODED — a lying `type` in the body cannot steer it" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn =
        call(:post, "/v1/agent/space",
          body: space_body(%{"type" => "health"}),
          token: agent_token(bp)
        )

      assert conn.status == 200
      # It landed as `space`, and the health stream stayed empty — so this row
      # can never be mistaken for a beat by the metrics window.
      assert [%{type: "space"}] = Registry.recent_events_of_type(bp, "space", 10)
      assert Registry.recent_events_of_type(bp, "health", 10) == []
    end

    test "THE FIVE NEGATIVES: a space post leaves a STALE box reading stale" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      :ok = Events.subscribe(team.id)

      long_ago =
        DateTime.add(DateTime.utc_now(), -86_400, :second) |> DateTime.truncate(:microsecond)

      {:ok, _} =
        Registry.record_agent_report(bp, %{
          health_status: "down",
          agent_status: "offline",
          version: "0.1.0",
          last_seen_at: long_ago
        })

      before = Registry.get_barkpark(bp.id)
      deliveries_before = Repo.aggregate(Delivery, :count)

      conn = call(:post, "/v1/agent/space", body: space_body(), token: agent_token(bp))
      assert conn.status == 200

      after_post = Registry.get_barkpark(bp.id)

      # (1) no record_agent_report: a box whose disk probe succeeds while its
      # BEAT is dead must NOT read as alive.
      assert after_post.health_status == "down"
      assert after_post.agent_status == "offline"
      assert after_post.version == before.version
      assert after_post.last_seen_at == before.last_seen_at

      # (2) no health-flip dispatch — nothing was emailed.
      assert Repo.aggregate(Delivery, :count) == deliveries_before

      # (3) no fleet SSE push — no open dashboard was woken by a disk row.
      refute_receive {:bpcloud_event, _}, 50

      # (4) no health row was written, so the metrics window still reads
      # "absent" — the disk report did not manufacture a beat.
      assert Registry.recent_events_of_type(bp, "health", 10) == []
    end

    test "a bad agent token → 401 and nothing is recorded" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn = call(:post, "/v1/agent/space", body: space_body(), token: "bogus-agent-token")

      assert conn.status == 401
      assert Registry.recent_events_of_type(bp, "space", 10) == []
    end

    test "no token → 401" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn = call(:post, "/v1/agent/space", body: space_body())

      assert conn.status == 401
      assert Registry.recent_events_of_type(bp, "space", 10) == []
    end

    test "a USER session token cannot satisfy the agent route → 401" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn = call(:post, "/v1/agent/space", body: space_body(), token: session_token(user))

      assert conn.status == 401
      assert Registry.recent_events_of_type(bp, "space", 10) == []
    end
  end
end
