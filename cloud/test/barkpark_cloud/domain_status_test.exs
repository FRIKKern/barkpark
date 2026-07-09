defmodule BarkparkCloud.DomainStatusTest do
  @moduledoc """
  Per-domain, per-stage domain/TLS truth (charter S13) — the `DomainStatus`
  executor + its `GET /v1/barkparks/:id/domain-status` route. Every outbound
  primitive (DNS resolve, TLS dial, serving GET) is a fake injected per call, so
  every stage combination is driven OFFLINE — no test touches the network.

  Proves:

    * the four ordered stages (dns_found → points_here → tls → serving), each
      with `{stage, label, status, evidence, remediation}`, and the exact S13b
      envelope `{ok, checked_at, instance, domains}`
    * stage semantics: a stage downstream of a non-ok stage is pending (skipped,
      never probed-and-red); a DNS-propagation miss is pending with retry copy,
      NEVER failed; a timing-out / raising probe is a bounded failure, not a hang
    * TLS attribution: no-cert vs self-signed vs expired vs valid distinguished,
      evidence carries issuer + expiry; serving is independent (cert ok + HTTP
      down => tls ok, serving failed)
    * the route: user-authed + team-scoped fail-closed (401 no auth, 404 foreign
      team / garbage id), platform-only when no custom_host, platform + custom
      when attached
    * FailureCopy.domain_stage_remediation/2: platform vs custom cert stories
      differ, and the terminal default clause leaves no non-ok stage reason-less
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, DomainStatus, FailureCopy, Registry, Repo}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @host "203.0.113.10"

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

  defp live_barkpark(team, attrs \\ %{}) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(Enum.into(attrs, %{host: @host, url: "https://x.barkpark.cloud"}))
    |> Repo.update!()
  end

  # ── seam fakes (injected per call via opts) ──

  # A DNS fake from a %{"host" => [ip_tuple, ...]} map: the list on :inet, [] on
  # :inet6 (resolve_all unions both families and de-dupes), {:ok, []} for an
  # unmapped host (an un-propagated record).
  defp dns_map(map) do
    fn charlist, family ->
      case {Map.get(map, to_string(charlist)), family} do
        {nil, _} -> {:ok, []}
        {list, :inet} -> {:ok, list}
        {_list, :inet6} -> {:ok, []}
      end
    end
  end

  defp tls_const(value), do: fn _host, _port -> value end
  defp http_const(value), do: fn _url -> value end

  defp valid_cert(issuer \\ "R3") do
    now = DateTime.utc_now()

    %{
      not_before: DateTime.add(now, -3600, :second),
      not_after: DateTime.add(now, 30 * 24 * 3600, :second),
      issuer: issuer,
      self_signed?: false
    }
  end

  defp expired_cert do
    now = DateTime.utc_now()

    %{
      not_before: DateTime.add(now, -60 * 24 * 3600, :second),
      not_after: DateTime.add(now, -24 * 3600, :second),
      issuer: "R3",
      self_signed?: false
    }
  end

  defp not_yet_valid_cert do
    now = DateTime.utc_now()

    %{
      not_before: DateTime.add(now, 24 * 3600, :second),
      not_after: DateTime.add(now, 30 * 24 * 3600, :second),
      issuer: "R3",
      self_signed?: false
    }
  end

  defp self_signed_cert do
    now = DateTime.utc_now()

    %{
      not_before: DateTime.add(now, -3600, :second),
      not_after: DateTime.add(now, 30 * 24 * 3600, :second),
      issuer: "Caddy Local Authority",
      self_signed?: true
    }
  end

  # The all-green estate for a platform-only box at @host.
  defp green_seams(bp) do
    fqdn = Barkpark.provisioning_fqdn(bp)

    [
      dns: dns_map(%{fqdn => [{203, 0, 113, 10}]}),
      tls: tls_const({:ok, valid_cert()}),
      http: http_const({:ok, 200})
    ]
  end

  defp stage(domain, name), do: Enum.find(domain.stages, &(&1.stage == name))
  defp platform(result), do: Enum.find(result.domains, &(&1.kind == "platform"))
  defp custom(result), do: Enum.find(result.domains, &(&1.kind == "custom"))

  # ── executor: happy path + envelope shape ──

  describe "DomainStatus.check/2 — all green" do
    test "platform-only box: every stage ok, overall ok, exact envelope shape" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)

      result = DomainStatus.check(bp, green_seams(bp))

      assert result.ok == true
      assert {:ok, _, _} = DateTime.from_iso8601(result.checked_at)
      assert result.instance == %{id: bp.id, host: @host}

      assert [dom] = result.domains
      assert dom.kind == "platform"
      assert dom.host == Barkpark.provisioning_fqdn(bp)
      assert dom.overall == "ok"

      assert Enum.map(dom.stages, & &1.stage) == ~w(dns_found points_here tls serving)

      for s <- dom.stages do
        assert s.status == "ok"
        assert is_binary(s.label) and s.label != ""
        assert is_binary(s.evidence) and s.evidence != ""
        # An ok stage carries no remediation.
        assert s.remediation == nil
      end

      # points_here names the matched address; tls carries issuer + expiry.
      assert stage(dom, "points_here").evidence =~ @host
      assert stage(dom, "tls").evidence =~ "R3"
      assert stage(dom, "serving").evidence =~ "200"
    end

    test "attached custom_host adds a second domain (platform + custom)" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team, %{custom_host: "shop.barkpark.cloud"})
      fqdn = Barkpark.provisioning_fqdn(bp)

      seams = [
        dns:
          dns_map(%{fqdn => [{203, 0, 113, 10}], "shop.barkpark.cloud" => [{203, 0, 113, 10}]}),
        tls: tls_const({:ok, valid_cert()}),
        http: http_const({:ok, 200})
      ]

      result = DomainStatus.check(bp, seams)

      assert length(result.domains) == 2
      assert platform(result).host == fqdn
      assert custom(result).host == "shop.barkpark.cloud"
      assert platform(result).overall == "ok"
      assert custom(result).overall == "ok"
      assert result.ok == true
    end

    test "no custom_host → the estate is the platform FQDN only" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team, %{custom_host: nil})

      result = DomainStatus.check(bp, green_seams(bp))
      assert [%{kind: "platform"}] = result.domains
    end
  end

  # ── stage semantics: skip downstream, pending-not-failed on DNS miss ──

  describe "DomainStatus.check/2 — ordered stages + skip" do
    test "DNS miss is PENDING with retry copy, never failed; downstream is skipped-pending" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)

      # Nothing resolves — a fresh, still-propagating attach.
      result = DomainStatus.check(bp, dns: dns_map(%{}))
      dom = platform(result)

      assert dom.overall == "pending"

      dns = stage(dom, "dns_found")
      assert dns.status == "pending"
      refute dns.status == "failed"
      assert dns.remediation =~ "propagate"

      # Every downstream stage is skipped into pending (never probed → never red).
      for name <- ~w(points_here tls serving) do
        s = stage(dom, name)
        assert s.status == "pending"
        assert s.evidence =~ "earlier step"
        assert is_binary(s.remediation)
      end
    end

    test "points_here FAILS when the domain resolves somewhere else; tls/serving skip" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)
      fqdn = Barkpark.provisioning_fqdn(bp)

      # Resolves — but to a different box than @host.
      result =
        DomainStatus.check(bp,
          dns: dns_map(%{fqdn => [{198, 51, 100, 9}]}),
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:ok, 200})
        )

      dom = platform(result)
      assert dom.overall == "failed"
      assert stage(dom, "dns_found").status == "ok"

      ph = stage(dom, "points_here")
      assert ph.status == "failed"
      assert ph.evidence =~ "198.51.100.9"
      assert ph.evidence =~ @host
      assert is_binary(ph.remediation)

      # Downstream of the failed stage: skipped, NOT probed-and-red.
      assert stage(dom, "tls").status == "pending"
      assert stage(dom, "serving").status == "pending"
    end

    test "points_here is PENDING (not failed) when the instance has no host yet" do
      {_u, team} = user_with_team()
      # A still-provisioning box: DNS record exists, but no reported host.
      bp = live_barkpark(team, %{host: nil})
      fqdn = Barkpark.provisioning_fqdn(bp)

      result = DomainStatus.check(bp, dns: dns_map(%{fqdn => [{203, 0, 113, 10}]}))
      dom = platform(result)

      assert stage(dom, "dns_found").status == "ok"
      assert stage(dom, "points_here").status == "pending"
      assert dom.overall == "pending"
    end

    test "a hostname host is resolved and matched (not just IP literals)" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team, %{host: "box.example.net"})
      fqdn = Barkpark.provisioning_fqdn(bp)

      # Both the domain and the host resolve to the same address.
      result =
        DomainStatus.check(bp,
          dns:
            dns_map(%{
              fqdn => [{203, 0, 113, 10}],
              "box.example.net" => [{203, 0, 113, 10}]
            }),
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:ok, 200})
        )

      assert stage(platform(result), "points_here").status == "ok"
    end
  end

  # ── bounded failure: a timing-out / raising probe never wedges the run ──

  describe "DomainStatus.check/2 — total over failure, bounded" do
    test "a timing-out TLS dial is a bounded pending, not a hang" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)
      fqdn = Barkpark.provisioning_fqdn(bp)

      result =
        DomainStatus.check(bp,
          dns: dns_map(%{fqdn => [{203, 0, 113, 10}]}),
          tls: tls_const({:error, :timeout}),
          http: http_const({:ok, 200})
        )

      dom = platform(result)
      # The run completed (we got here) — no wedge.
      assert stage(dom, "points_here").status == "ok"
      assert stage(dom, "tls").status == "pending"
      assert stage(dom, "tls").evidence =~ "timed out"
      # serving is downstream of the non-ok tls → skipped.
      assert stage(dom, "serving").status == "pending"
    end

    test "a raising seam is caught (never escapes) — treated as unreachable" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)
      fqdn = Barkpark.provisioning_fqdn(bp)

      result =
        DomainStatus.check(bp,
          dns: dns_map(%{fqdn => [{203, 0, 113, 10}]}),
          tls: fn _h, _p -> raise "boom" end,
          http: http_const({:ok, 200})
        )

      # No raise reached us; tls degraded to pending.
      assert stage(platform(result), "tls").status == "pending"
    end
  end

  # ── TLS attribution: no-cert / self-signed / expired / valid ──

  describe "DomainStatus.check/2 — TLS stage attribution" do
    setup do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)
      fqdn = Barkpark.provisioning_fqdn(bp)
      base = [dns: dns_map(%{fqdn => [{203, 0, 113, 10}]}), http: http_const({:ok, 200})]
      {:ok, bp: bp, base: base}
    end

    test "no certificate served → tls PENDING (being issued)", %{bp: bp, base: base} do
      result = DomainStatus.check(bp, Keyword.put(base, :tls, tls_const({:error, :closed})))
      tls = stage(platform(result), "tls")
      assert tls.status == "pending"
      assert tls.evidence =~ "No certificate"
    end

    test "temporary self-signed cert → tls PENDING, evidence says self-signed", %{
      bp: bp,
      base: base
    } do
      result =
        DomainStatus.check(bp, Keyword.put(base, :tls, tls_const({:ok, self_signed_cert()})))

      tls = stage(platform(result), "tls")
      assert tls.status == "pending"
      assert tls.evidence =~ "self-signed"
    end

    test "expired cert → tls FAILED, evidence carries the expiry", %{bp: bp, base: base} do
      result = DomainStatus.check(bp, Keyword.put(base, :tls, tls_const({:ok, expired_cert()})))
      tls = stage(platform(result), "tls")
      assert tls.status == "failed"
      assert tls.evidence =~ "expired"
    end

    test "not-yet-valid cert → tls FAILED", %{bp: bp, base: base} do
      result =
        DomainStatus.check(bp, Keyword.put(base, :tls, tls_const({:ok, not_yet_valid_cert()})))

      assert stage(platform(result), "tls").status == "failed"
    end

    test "valid cert + HTTP down → tls OK, serving FAILED (independent stages)", %{
      bp: bp,
      base: base
    } do
      result =
        DomainStatus.check(bp,
          dns: base[:dns],
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:ok, 502})
        )

      dom = platform(result)
      assert stage(dom, "tls").status == "ok"
      serving = stage(dom, "serving")
      assert serving.status == "failed"
      assert serving.evidence =~ "502"
      assert dom.overall == "failed"
    end

    test "serving transport error → serving FAILED", %{bp: bp, base: base} do
      result =
        DomainStatus.check(bp,
          dns: base[:dns],
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:error, :econnrefused})
        )

      serving = stage(platform(result), "serving")
      assert serving.status == "failed"
      assert serving.evidence =~ "connection refused"
    end
  end

  # ── FailureCopy.domain_stage_remediation/2 ──

  describe "FailureCopy.domain_stage_remediation/2" do
    test "platform vs custom cert stories differ" do
      platform = FailureCopy.domain_stage_remediation("platform", "tls")
      custom = FailureCopy.domain_stage_remediation("custom", "tls")

      assert platform != custom
      assert platform =~ "automatically"
      assert custom =~ "custom domain"
    end

    test "every stage (and the terminal default) yields non-empty copy" do
      for kind <- ~w(platform custom),
          stage <- ~w(dns_found points_here tls serving anything_new) do
        copy = FailureCopy.domain_stage_remediation(kind, stage)
        assert is_binary(copy) and copy != ""
      end
    end
  end

  # ── the route ──

  describe "GET /v1/barkparks/:id/domain-status" do
    # The route calls DomainStatus.check/1 (no opts), so it reads the config
    # seams. Program a per-process fake and point the three seam keys at it.
    setup do
      prev = %{
        dns: Application.get_env(:barkpark_cloud, :domain_status_dns),
        tls: Application.get_env(:barkpark_cloud, :domain_status_tls),
        http: Application.get_env(:barkpark_cloud, :domain_status_http)
      }

      Application.put_env(:barkpark_cloud, :domain_status_dns, &__MODULE__.RouteFake.dns/2)
      Application.put_env(:barkpark_cloud, :domain_status_tls, &__MODULE__.RouteFake.tls/2)
      Application.put_env(:barkpark_cloud, :domain_status_http, &__MODULE__.RouteFake.http/1)

      on_exit(fn ->
        Application.put_env(:barkpark_cloud, :domain_status_dns, prev.dns)
        Application.put_env(:barkpark_cloud, :domain_status_tls, prev.tls)
        Application.put_env(:barkpark_cloud, :domain_status_http, prev.http)
      end)

      :ok
    end

    test "returns the full green envelope for the owner" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      fqdn = Barkpark.provisioning_fqdn(bp)

      __MODULE__.RouteFake.program(
        dns: %{fqdn => [{203, 0, 113, 10}]},
        tls: %{fqdn => {:ok, valid_cert()}},
        http: %{("https://" <> fqdn) => {:ok, 200}}
      )

      conn = call(:get, "/v1/barkparks/#{bp.id}/domain-status", session_token(user))
      assert conn.status == 200

      body = json_body(conn)
      assert body["ok"] == true
      assert body["instance"]["id"] == bp.id
      assert [dom] = body["domains"]
      assert dom["kind"] == "platform"
      assert Enum.map(dom["stages"], & &1["stage"]) == ~w(dns_found points_here tls serving)
      assert Enum.all?(dom["stages"], &(&1["status"] == "ok"))
    end

    test "a wrong-team / nonexistent / malformed id is the SAME 404 (no leak, no CastError)" do
      {_owner, team_a} = user_with_team()
      bp = live_barkpark(team_a)
      {intruder, _team_b} = user_with_team()

      c1 = call(:get, "/v1/barkparks/#{bp.id}/domain-status", session_token(intruder))
      c2 = call(:get, "/v1/barkparks/not-a-uuid/domain-status", session_token(intruder))

      assert c1.status == 404
      assert c2.status == 404
    end

    test "no auth → 401" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)
      conn = call(:get, "/v1/barkparks/#{bp.id}/domain-status", nil)
      assert conn.status == 401
    end
  end

  # A per-process programmable fake for the route (check/1 runs in the test
  # process, so the process dict is visible).
  defmodule RouteFake do
    def program(opts) do
      Process.put(:ds_dns, Keyword.get(opts, :dns, %{}))
      Process.put(:ds_tls, Keyword.get(opts, :tls, %{}))
      Process.put(:ds_http, Keyword.get(opts, :http, %{}))
      :ok
    end

    def dns(charlist, family) do
      case {Map.get(Process.get(:ds_dns, %{}), to_string(charlist)), family} do
        {nil, _} -> {:ok, []}
        {list, :inet} -> {:ok, list}
        {_list, :inet6} -> {:ok, []}
      end
    end

    def tls(host, _port),
      do: Map.get(Process.get(:ds_tls, %{}), to_string(host), {:error, :offline})

    def http(url), do: Map.get(Process.get(:ds_http, %{}), url, {:error, :offline})
  end

  # ── helpers ──

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, token) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)
end
