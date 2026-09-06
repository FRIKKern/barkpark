defmodule BarkparkCloud.VerifyTest do
  @moduledoc """
  On-demand golden-path VERIFY (C8 / D53) — the Elixir executor + its
  `POST /v1/barkparks/:id/verify` route. Proves:

    * the happy path: all three probes green → `ok: true`, `reachable: true`,
      one probe_result each with `{name, ok, reachable, status, latency_ms,
      evidence}`
    * each probe's pass rule: api must be 200; login must be <500 (a 401 is a
      PASS — the auth stack answered — a 500 is a FAIL, the #957 class); studio
      must render <500 following the scoped redirect ≤3 hops (a redirect loop
      fails)
    * total over failure: an UNREACHABLE box is a fully-populated
      `reachable: false` result, NEVER a raise or an error tuple to the caller
    * token custody (D46): the stored admin token rides ONLY the api probe's
      Authorization header, and appears NOWHERE in the result envelope
    * the probe VOCABULARY matches the shared fixture byte-for-byte (the D32
      one-fixture-two-asserters discipline; Go asserts the same file)
    * the route: user-authed team-scoped fail-closed 404, 409 not_live,
      404 no_admin_token, the run recorded as a `verify` instance event, and the
      token absent from the HTTP response body
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo, Verify}
  alias BarkparkCloud.Registry.{AgentEvent, Barkpark, Vault}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"
  @admin_token "instance-admin-token-plaintext-SECRET-123"
  @instance_url "https://prod.barkpark.cloud"

  @fixture_path Path.expand("../../priv/static/__fixtures__/verify_probes.json", __DIR__)

  # ── a header-aware fake transport, wired via the :verify_http_client seam ──
  #
  # Verify.studio walks a redirect chain, so the fake must return HEADERS (the
  # billing client drops them). Programmed per exact request PATH; a `:__all__`
  # key answers every path (the unreachable-everything case). async: false +
  # process-dict state keeps it parallel-free and self-contained.
  defmodule FakeHttp do
    def program(map) do
      Process.put(:verify_fake, map)
      Process.put(:verify_fake_log, [])
      :ok
    end

    def requests, do: Enum.reverse(Process.get(:verify_fake_log, []))

    def request(req) do
      Process.put(:verify_fake_log, [req | Process.get(:verify_fake_log, [])])
      map = Process.get(:verify_fake, %{})
      path = URI.parse(req.url).path

      cond do
        Map.has_key?(map, :__all__) -> Map.fetch!(map, :__all__)
        Map.has_key?(map, path) -> Map.fetch!(map, path)
        true -> {:ok, %{status: 200, body: "", headers: []}}
      end
    end
  end

  setup do
    prev = Application.get_env(:barkpark_cloud, :verify_http_client)
    Application.put_env(:barkpark_cloud, :verify_http_client, FakeHttp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark_cloud, :verify_http_client, prev),
        else: Application.delete_env(:barkpark_cloud, :verify_http_client)
    end)

    :ok
  end

  # ── fixtures ──

  defp user_with_team(role \\ "owner") do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "u#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp live_barkpark(team) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@admin_token)
    )
    |> Repo.update!()
  end

  # The all-green box: capabilities 200, login 401 (auth answered), /studio 302 →
  # /w/default/studio 200 (exercises the scoped redirect).
  defp program_green do
    FakeHttp.program(%{
      "/v1/capabilities" => {:ok, %{status: 200, body: ~s({"ok":true}), headers: []}},
      "/v1/auth/login" => {:ok, %{status: 401, body: ~s({"error":"invalid"}), headers: []}},
      "/studio" => {:ok, %{status: 302, body: "", headers: [{"location", "/w/default/studio"}]}},
      "/w/default/studio" => {:ok, %{status: 200, body: "<title>Studio</title>", headers: []}}
    })
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp find(probes, name), do: Enum.find(probes, &(&1.name == name))

  ## ── the executor ──

  describe "Verify.run/1 — happy path" do
    test "all three probes green → ok result with per-probe evidence" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      program_green()

      assert {:ok, result} = Verify.run(bp)
      assert result.ok
      assert result.reachable
      assert {:ok, _, _} = DateTime.from_iso8601(result.verified_at)

      assert length(result.probes) == 3
      assert Enum.map(result.probes, & &1.name) == ["verify.api", "verify.login", "verify.studio"]

      for p <- result.probes do
        assert p.ok
        assert p.reachable
        assert is_integer(p.latency_ms) and p.latency_ms >= 0
        assert is_binary(p.evidence) and p.evidence != ""
      end

      assert find(result.probes, "verify.api").status == 200
      assert find(result.probes, "verify.login").status == 401
      assert find(result.probes, "verify.studio").status == 200
    end
  end

  describe "Verify.run/1 — per-probe pass rules" do
    test "verify.api FAILS on a non-200 (e.g. 503 boot-not-finished)" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      program_green()

      FakeHttp.program(%{
        "/v1/capabilities" => {:ok, %{status: 503, body: "starting up", headers: []}}
      })

      assert {:ok, result} = Verify.run(bp)
      refute result.ok
      api = find(result.probes, "verify.api")
      refute api.ok
      assert api.status == 503
      assert api.evidence =~ "503"
    end

    test "verify.login PASSES on a 401 (auth answered) but FAILS on a 500 (the #957 class)" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      # 401 → pass
      program_green()
      assert {:ok, ok_res} = Verify.run(bp)
      assert find(ok_res.probes, "verify.login").ok

      # 500 → fail (session/auth stack dead on arrival)
      program_green()

      FakeHttp.program(
        Map.put(
          green_map(),
          "/v1/auth/login",
          {:ok, %{status: 500, body: "session crash", headers: []}}
        )
      )

      assert {:ok, bad_res} = Verify.run(bp)
      refute bad_res.ok
      login = find(bad_res.probes, "verify.login")
      refute login.ok
      assert login.status == 500
      assert login.evidence =~ "session crash"
    end

    test "verify.studio FAILS on a redirect loop past 3 hops" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      # api + login green; /studio and its hop 302 forever → the ≤3-hop budget
      # is blown and verify.studio fails without ever rendering.
      FakeHttp.program(%{
        "/v1/capabilities" => {:ok, %{status: 200, body: "", headers: []}},
        "/v1/auth/login" => {:ok, %{status: 401, body: "", headers: []}},
        "/studio" => {:ok, %{status: 302, body: "", headers: [{"location", "/studio/hop"}]}},
        "/studio/hop" => {:ok, %{status: 302, body: "", headers: [{"location", "/studio/hop"}]}}
      })

      assert {:ok, result} = Verify.run(bp)
      refute result.ok
      studio = find(result.probes, "verify.studio")
      refute studio.ok
      assert studio.reachable
      assert studio.evidence =~ "hops"

      # api + login passed before studio failed.
      assert find(result.probes, "verify.api").ok
      assert find(result.probes, "verify.login").ok
    end

    test "verify.studio FAILS on a 3xx with no Location (Go-gate parity: it never rendered)" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      FakeHttp.program(
        Map.put(green_map(), "/studio", {:ok, %{status: 302, body: "", headers: []}})
      )

      assert {:ok, result} = Verify.run(bp)
      refute result.ok
      studio = find(result.probes, "verify.studio")
      refute studio.ok
      assert studio.reachable
      assert studio.status == 302
      assert studio.evidence =~ "no Location"
    end

    test "verify.studio follows a SAME-origin absolute-URL redirect" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      FakeHttp.program(
        Map.put(
          green_map(),
          "/studio",
          {:ok,
           %{
             status: 302,
             body: "",
             headers: [{"location", @instance_url <> "/w/default/studio"}]
           }}
        )
      )

      assert {:ok, result} = Verify.run(bp)
      studio = find(result.probes, "verify.studio")
      assert studio.ok
      assert studio.status == 200
    end

    test "verify.studio REFUSES an off-origin redirect (SSRF guard) — target never requested" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)

      FakeHttp.program(
        Map.put(
          green_map(),
          "/studio",
          {:ok,
           %{
             status: 302,
             body: "",
             headers: [{"location", "http://169.254.169.254/latest/meta-data"}]
           }}
        )
      )

      assert {:ok, result} = Verify.run(bp)
      refute result.ok
      studio = find(result.probes, "verify.studio")
      refute studio.ok
      assert studio.status == 302
      assert studio.evidence =~ "off the instance origin"

      # The control plane never issued a request to the off-origin target.
      refute Enum.any?(FakeHttp.requests(), fn r ->
               String.contains?(r.url, "169.254.169.254")
             end)
    end
  end

  describe "Verify.run/1 — total over failure" do
    test "an UNREACHABLE box is a reachable:false result on every probe, never a raise" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      FakeHttp.program(%{__all__: {:error, {:http_client, :nxdomain}}})

      assert {:ok, result} = Verify.run(bp)
      refute result.ok
      refute result.reachable

      for p <- result.probes do
        refute p.ok
        refute p.reachable
        assert p.status == nil
        assert p.evidence =~ "unreachable"
      end
    end

    test "a not-yet-live box (no url) → {:error, :not_live}" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      assert Verify.run(bp) == {:error, :not_live}
    end

    test "a live box with no stored admin token → {:error, :no_admin_token}" do
      {_user, team} = user_with_team()

      bp =
        team
        |> barkpark_fixture()
        |> Ecto.Changeset.change(url: @instance_url, host: "203.0.113.10")
        |> Repo.update!()

      assert Verify.run(bp) == {:error, :no_admin_token}
    end
  end

  describe "Verify.run/1 — token custody (D46)" do
    test "the admin token rides ONLY the api probe, and never appears in the result" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      program_green()

      assert {:ok, result} = Verify.run(bp)

      # The whole result (JSON-serialized) never carries the secret.
      refute Jason.encode!(result) =~ @admin_token

      reqs = FakeHttp.requests()
      by_path = Map.new(reqs, fn r -> {URI.parse(r.url).path, r.headers} end)

      # api probe carries the bearer.
      assert {"Authorization", "Bearer " <> @admin_token} =
               List.keyfind(by_path["/v1/capabilities"], "Authorization", 0)

      # login + studio are anonymous — no Authorization header at all.
      refute List.keyfind(by_path["/v1/auth/login"], "Authorization", 0)
      refute List.keyfind(by_path["/studio"], "Authorization", 0)
    end

    test "evidence is truncated to <= 200 bytes even on a chatty error body" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      big = String.duplicate("x", 5_000)

      FakeHttp.program(
        Map.put(green_map(), "/v1/capabilities", {:ok, %{status: 500, body: big, headers: []}})
      )

      assert {:ok, result} = Verify.run(bp)
      api = find(result.probes, "verify.api")
      assert byte_size(api.evidence) <= 200
    end
  end

  describe "the probe vocabulary matches the shared fixture (D32)" do
    test "Verify.probes/0 deep-equals verify_probes.json (names, labels, pass-rules, order)" do
      fixture = @fixture_path |> File.read!() |> Jason.decode!()

      expected =
        Enum.map(fixture["probes"], fn p ->
          %{name: p["name"], label: p["label"], pass_rule: p["pass_rule"]}
        end)

      assert Verify.probes() == expected
    end
  end

  ## ── the route ──

  describe "POST /v1/barkparks/:id/verify" do
    test "runs the suite, returns the envelope, records a `verify` event, broadcasts fleet" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      program_green()

      conn = call(:post, "/v1/barkparks/#{bp.id}/verify", session_token(user))
      assert conn.status == 200

      body = json_body(conn)
      assert body["ok"] == true
      assert body["reachable"] == true
      assert length(body["probes"]) == 3

      # Recorded as a `verify` instance event on the timeline.
      events = Registry.recent_events(bp, 10)
      assert Enum.any?(events, &(&1.type == "verify"))
      assert AgentEvent.types() |> Enum.member?("verify")

      # The admin token never rides the HTTP response.
      refute conn.resp_body =~ @admin_token
    end

    test "persists the headline verdict onto the barkpark row (BP-ONB-09)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      # Before the run the row carries no verify verdict — an honest NULL, not a
      # false. This is the red-without-persist guard: a fire-and-forget verify
      # would leave both nil forever.
      assert is_nil(bp.last_verified_at)
      assert is_nil(bp.verify_reachable)

      program_green()
      conn = call(:post, "/v1/barkparks/#{bp.id}/verify", session_token(user))
      assert conn.status == 200
      assert json_body(conn)["reachable"] == true

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.verify_reachable == true
      assert %DateTime{} = reloaded.last_verified_at
    end

    test "persists reachable:false for an unreachable box, never failing the response" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      FakeHttp.program(%{__all__: {:error, {:http_client, :nxdomain}}})

      conn = call(:post, "/v1/barkparks/#{bp.id}/verify", session_token(user))
      # An unreachable box is a 200 reachable:false envelope, NOT an error.
      assert conn.status == 200
      assert json_body(conn)["reachable"] == false

      reloaded = Repo.get!(Barkpark, bp.id)
      # A real false verdict, distinct from the pre-run NULL.
      assert reloaded.verify_reachable == false
      assert %DateTime{} = reloaded.last_verified_at
    end

    test "a wrong-team / nonexistent / malformed id is the SAME 404" do
      {_owner, team_a} = user_with_team()
      bp = live_barkpark(team_a)

      {intruder, _team_b} = user_with_team()
      program_green()

      # A member of ANOTHER team hitting this instance → 404 (no existence leak).
      c1 = call(:post, "/v1/barkparks/#{bp.id}/verify", session_token(intruder))
      # A garbage id → the SAME 404, no Ecto.CastError.
      c2 = call(:post, "/v1/barkparks/not-a-uuid/verify", session_token(intruder))

      assert c1.status == 404
      assert c2.status == 404
    end

    test "no auth → 401" do
      {_user, team} = user_with_team()
      bp = live_barkpark(team)
      conn = call(:post, "/v1/barkparks/#{bp.id}/verify", nil)
      assert conn.status == 401
    end

    test "a still-provisioning box (no url) → 409 not_live" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      conn = call(:post, "/v1/barkparks/#{bp.id}/verify", session_token(user))
      assert conn.status == 409
      assert json_body(conn)["error"] == "not_live"
    end

    # cch-w58-bl — the RULING (wave 58 lead): verify is a plane-originated,
    # authenticated egress that spends the CUSTODIED admin token, not a relay of
    # a client-authored request, so D673's grant for the proxy's `:read` tier
    # does not cover it. It refuses on a suspended box with the shipped 409
    # `suspended` envelope.
    #
    # ASSERTED ON THE WIRE, BOTH DIRECTIONS. A status-only assertion cannot see a
    # credential that was already spent before the refusal was rendered, so the
    # suspended arm asserts the fake transport recorded ZERO requests and the
    # unsuspended CONTROL asserts it recorded some — the control is what stops
    # the zero-requests assertion from going vacuous (a broken fixture that never
    # reaches the transport at all would pass the refusal arm alone).
    test "a SUSPENDED box → 409 suspended, and ZERO requests reach the wire" do
      {user, team} = user_with_team()

      bp =
        team
        |> live_barkpark()
        |> Ecto.Changeset.change(suspended: true)
        |> Repo.update!()

      program_green()

      conn = call(:post, "/v1/barkparks/#{bp.id}/verify", session_token(user))

      # THE WIRE FIRST — this is the assertion the row is about. A refusal that
      # renders a 409 AFTER `Verify.run/1` has already spent the token would pass
      # the status check below and fail here.
      assert FakeHttp.requests() == []

      assert conn.status == 409
      assert json_body(conn)["error"] == "suspended"

      # And the plane recorded no verdict from a run it never made.
      reloaded = Repo.get!(Barkpark, bp.id)
      assert is_nil(reloaded.verify_reachable)
      assert is_nil(reloaded.last_verified_at)
    end

    test "the NON-suspended control DOES reach the wire (anti-vacuity for the refusal above)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      refute bp.suspended

      program_green()

      conn = call(:post, "/v1/barkparks/#{bp.id}/verify", session_token(user))

      assert conn.status == 200
      # Same fixture, same call shape, suspension flipped off → requests DO get
      # recorded. Without this arm the `== []` above could be green for a reason
      # that has nothing to do with the refusal.
      assert FakeHttp.requests() != []

      assert Enum.any?(FakeHttp.requests(), fn req ->
               URI.parse(req.url).path == "/v1/capabilities"
             end)
    end

    test "a live box with no admin token → 404 no_admin_token" do
      {user, team} = user_with_team()

      bp =
        team
        |> barkpark_fixture()
        |> Ecto.Changeset.change(url: @instance_url, host: "203.0.113.10")
        |> Repo.update!()

      conn = call(:post, "/v1/barkparks/#{bp.id}/verify", session_token(user))
      assert conn.status == 404
      assert json_body(conn)["error"] == "no_admin_token"
    end
  end

  # ── helpers ──

  defp green_map do
    %{
      "/v1/capabilities" => {:ok, %{status: 200, body: ~s({"ok":true}), headers: []}},
      "/v1/auth/login" => {:ok, %{status: 401, body: ~s({"error":"invalid"}), headers: []}},
      "/studio" => {:ok, %{status: 302, body: "", headers: [{"location", "/w/default/studio"}]}},
      "/w/default/studio" => {:ok, %{status: 200, body: "<title>Studio</title>", headers: []}}
    }
  end

  defp call(method, path, token) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)
end
