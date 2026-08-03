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
  alias BarkparkCloud.Registry.{Barkpark, Site}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @host "203.0.113.10"

  # ── cross-surface fixture (ExUnit-GENERATED, drift-gated) ──
  @fixture_path Path.expand(
                  "../../priv/static/__fixtures__/domain-status.json",
                  __DIR__
                )
  @frozen_checked_at "2026-07-09T10:00:00Z"
  @fixture_instance_id "11111111-2222-3333-4444-555555555555"
  @fixture_team_id "22222222-3333-4444-5555-666666666666"

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

  # A DNS fake from a %{"host" => [ip_tuple, ...]} map: the list on :inet, and
  # `{:error, :nxdomain}` on the family that has no record — WHICH IS WHAT THE
  # REAL TRANSPORT RETURNS. Re-measured at review on this host:
  # `:inet.getaddrs(~c"definitely-not-a-real-host-zzz.example", :inet)` and the
  # same on `:inet6` both return `{:error, :nxdomain}`, and an A-only name
  # returns it on `:inet6`. A fake that answered `{:ok, []}` for a missing
  # record would encode a shape production never produces — the device-oracle
  # trap: a fixture that cannot produce the condition it is meant to police.
  defp dns_map(map) do
    fn charlist, family ->
      case {Map.get(map, to_string(charlist)), family} do
        {nil, _} -> {:error, :nxdomain}
        {list, :inet} -> {:ok, list}
        {_list, :inet6} -> {:error, :nxdomain}
      end
    end
  end

  # An inet6-family DNS fake (AAAA-only estates). Same fidelity rule.
  defp dns_map_inet6(map) do
    fn charlist, family ->
      case {Map.get(map, to_string(charlist)), family} do
        {nil, _} -> {:error, :nxdomain}
        {list, :inet6} -> {:ok, list}
        {_list, :inet} -> {:error, :nxdomain}
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

  # ── cross-surface fixture generators ──

  # A bare, DETERMINISTIC struct (no DB): fixed id/slug/team_id give a stable
  # provisioning_fqdn + instance id, so checked_at is the ONLY nondeterministic
  # field left to freeze for the committed fixture.
  defp fixture_barkpark do
    struct(Barkpark, %{
      id: @fixture_instance_id,
      slug: "blog",
      team_id: @fixture_team_id,
      host: "91.99.1.2",
      custom_host: nil
    })
  end

  # A cert with ABSOLUTE far-past/future validity: always valid regardless of
  # when the suite runs (classify_cert compares against real now/0), AND its
  # expiry evidence is a fixed string (never now-relative) — so the generated
  # fixture stays byte-stable.
  defp frozen_cert do
    %{
      not_before: ~U[2020-01-01 00:00:00Z],
      not_after: ~U[2099-01-01 00:00:00Z],
      issuer: "R3",
      self_signed?: false
    }
  end

  # The four canonical scenarios, each a full REAL-server envelope with a frozen
  # checked_at: every-rung-green, mid-issuance (tls still pending → serving
  # skipped), cert-ok-but-app-down (serving FAILED, the [ok,ok,ok,failed] state
  # the SPA keeps polling), and resolver_faulted — the control plane's own DNS
  # lookup could not answer, so dns_found is `unknown` with NO remediation and
  # the domain rolls up `unknown`. Without that fourth case the shared fixture
  # structurally cannot produce the defect, and the cross-runtime drift gate
  # cannot see the new rung state at all.
  defp fixture_cases do
    bp = fixture_barkpark()
    dns = dns_map(%{Barkpark.provisioning_fqdn(bp) => [{91, 99, 1, 2}]})

    %{
      "all_serving" =>
        DomainStatus.check(bp,
          dns: dns,
          tls: tls_const({:ok, frozen_cert()}),
          http: http_const({:ok, 200})
        ),
      "mid_issuance" =>
        DomainStatus.check(bp,
          dns: dns,
          tls: tls_const({:error, :closed}),
          http: http_const({:ok, 200})
        ),
      "serving_failed" =>
        DomainStatus.check(bp,
          dns: dns,
          tls: tls_const({:ok, frozen_cert()}),
          http: http_const({:ok, 502})
        ),
      "resolver_faulted" =>
        DomainStatus.check(bp,
          dns: fn _charlist, _family -> {:error, :timeout} end,
          tls: tls_const({:ok, frozen_cert()}),
          http: http_const({:ok, 200})
        )
    }
    |> Map.new(fn {name, env} -> {name, %{env | checked_at: @frozen_checked_at}} end)
  end

  defp fixture_json, do: (fixture_cases() |> ordered() |> Jason.encode!(pretty: true)) <> "\n"

  # Sort every map's keys before encoding so the committed bytes are DETERMINISTIC
  # regardless of BEAM atom-table / map iteration order (which can differ across
  # boots) — the cross-runtime drift gate must be byte-stable, never a flake.
  # (Consumers JSON-parse, so key order is irrelevant to them.)
  defp ordered(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), ordered(v)} end)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(other), do: other

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

  # ── an unreachable resolver is `unknown`, never a guess about the operator ──
  #
  # The defect these pin: `resolve_all/2` folded every resolver fault (raise,
  # exit, {:error, :timeout}, no nameservers) into an empty
  # address list, byte-identical to a GENUINE empty answer — so the control plane
  # told the person "No A/AAAA record for <host> has propagated yet." with
  # "give it a moment and re-check" attached, about a lookup it never made.

  # The four fault modes, each a seam that cannot ANSWER. The last two are
  # RETURNED errors; the first two are a raise and an exit through safe_call/1.
  # `:nxdomain` is deliberately NOT here — it is an answer, and its own describe
  # block above pins it as one.
  defp fault_seams do
    [
      {"raise", fn _charlist, _family -> raise "resolver down" end},
      {"exit", fn _charlist, _family -> exit(:killed) end},
      {"timeout", fn _charlist, _family -> {:error, :timeout} end},
      {"no nameservers", fn _charlist, _family -> {:error, :no_nameservers} end}
    ]
  end

  # REVIEW DECISION (wave 28, superseding the letter of D332): `:nxdomain` is an
  # ANSWER, not a fault. Re-measured on the real transport —
  # `:inet.getaddrs(~c"no-such-host.example", :inet)` and the same on `:inet6`
  # BOTH return `{:error, :nxdomain}` — which is precisely what a freshly
  # attached, still-propagating domain looks like. Classified as a fault it
  # would turn the MOST COMMON waiting state into "we could not check" and strip
  # its propagation advice: one lie swapped for another in the rung this slice
  # exists to make honest. This test is the guard on that classification.
  describe "DomainStatus.check/2 — an authoritative NXDOMAIN is a measurement" do
    test "nxdomain on BOTH families reads as propagation-pending, with its advice intact" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)

      dom = platform(DomainStatus.check(bp, dns: fn _c, _f -> {:error, :nxdomain} end))
      dns = stage(dom, "dns_found")

      assert dns.status == "pending"
      assert dns.evidence =~ "has propagated yet"
      refute dns.evidence =~ "Could not check whether"
      assert is_binary(dns.remediation) and dns.remediation =~ "propagate"
      assert dom.overall == "pending"

      # BYTE-IDENTICAL to the empty-list answer: both are the same measurement.
      assert dns == stage(platform(DomainStatus.check(bp, dns: dns_map(%{}))), "dns_found")
    end

    test "a REAL fault alongside nxdomain still reads unknown (nxdomain is not a fault mask)" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)

      dom =
        platform(
          DomainStatus.check(bp,
            dns: fn _c, family ->
              case family do
                :inet -> {:error, :nxdomain}
                :inet6 -> {:error, :timeout}
              end
            end
          )
        )

      assert stage(dom, "dns_found").status == "unknown"
      assert stage(dom, "dns_found").evidence =~ "timed out"
      assert dom.overall == "unknown"
    end
  end

  describe "DomainStatus.check/2 — resolver fault is unknown, not a propagation guess" do
    test "all four fault modes are unknown and NAME the fault; a genuine empty answer stays pending" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)

      # The control: every family answers, and the answer is genuinely empty.
      genuine_empty = platform(DomainStatus.check(bp, dns: dns_map(%{})))

      assert stage(genuine_empty, "dns_found").status == "pending"
      assert stage(genuine_empty, "dns_found").evidence =~ "has propagated yet"
      assert stage(genuine_empty, "dns_found").remediation =~ "propagate"
      assert genuine_empty.overall == "pending"

      for {name, seam} <- fault_seams() do
        dom = platform(DomainStatus.check(bp, dns: seam))
        dns = stage(dom, "dns_found")

        assert dns.status == "unknown", "#{name}: expected unknown, got #{dns.status}"

        # It says WHOSE failure it was, and names the fault itself.
        assert dns.evidence =~ "Could not check whether",
               "#{name}: evidence must not claim anything about the operator's records"

        assert dns.evidence =~ "DNS lookup failed"
        refute dns.evidence =~ "has propagated yet"

        # THE PIN: before the fix every one of these was BYTE-IDENTICAL to the
        # genuine-empty control.
        refute dns == stage(genuine_empty, "dns_found"),
               "#{name}: a resolver fault must not be indistinguishable from an empty answer"

        assert dom.overall == "unknown"
      end
    end

    test "each fault mode names its OWN fault (they are not one collapsed string either)" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)

      evidence =
        for {_name, seam} <- fault_seams() do
          bp
          |> DomainStatus.check(dns: seam)
          |> platform()
          |> stage("dns_found")
          |> Map.get(:evidence)
        end

      assert length(Enum.uniq(evidence)) == length(evidence),
             "the four fault modes collapsed back into one string: #{inspect(evidence)}"

      assert Enum.any?(evidence, &(&1 =~ "timed out"))
      assert Enum.any?(evidence, &(&1 =~ "no nameservers configured"))
      assert Enum.any?(evidence, &(&1 =~ "resolver down"))
      assert Enum.any?(evidence, &(&1 =~ "exit"))
    end

    test "an unknown stage carries NO remediation — the honest copy is the evidence, the fix is the absence of advice" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)

      for {name, seam} <- fault_seams() do
        dns = bp |> DomainStatus.check(dns: seam) |> platform() |> stage("dns_found")

        assert dns.status == "unknown"
        assert is_nil(dns.remediation), "#{name}: an unmeasurable stage must carry no advice"
      end

      # The contrast, in the same file: an actionable pending rung still carries
      # its server-owned copy (this fix removes advice ONLY where we did not look).
      pending = bp |> DomainStatus.check(dns: dns_map(%{})) |> platform() |> stage("dns_found")
      assert is_binary(pending.remediation) and pending.remediation != ""
    end

    test "overall ordering is failed > unknown > pending > ok — unknown never reads as a promise" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)

      result = DomainStatus.check(bp, dns: fn _c, _f -> {:error, :timeout} end)
      dom = platform(result)

      # The reachable shape: one unmeasurable rung, three skipped-pending ones.
      assert Enum.map(dom.stages, & &1.status) == ~w(unknown pending pending pending)

      # MUTATION PIN: drop the explicit `unknown` clause from overall/1 and this
      # reads "pending" — a PROMISE that it will go green on its own, about a
      # rung nobody measured.
      assert dom.overall == "unknown"
      refute dom.overall == "pending"

      # And the envelope never seals over it.
      assert result.ok == false
    end

    test "a failed rung still outranks unknown (the ordering is not just unknown-wins)" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)
      fqdn = Barkpark.provisioning_fqdn(bp)

      # The domain resolves elsewhere (points_here FAILS) while the box host's
      # own lookup faults — a real misconfiguration outranks an unmeasured rung.
      result =
        DomainStatus.check(bp,
          dns: fn charlist, family ->
            case {to_string(charlist), family} do
              {^fqdn, :inet} -> {:ok, [{198, 51, 100, 9}]}
              _ -> {:ok, []}
            end
          end
        )

      dom = platform(result)
      assert stage(dom, "points_here").status == "failed"
      assert dom.overall == "failed"
    end

    test "CONTAINMENT: only an ATTEMPTED stage may be unknown — skipped stages stay pending" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)

      # (1) The faulted domain: the attempted rung is unknown, everything the
      # chain SKIPPED behind it stays pending (never "unknown" by contagion).
      dom = platform(DomainStatus.check(bp, dns: fn _c, _f -> {:error, :timeout} end))

      for name <- ~w(points_here tls serving) do
        s = stage(dom, name)
        assert s.status == "pending", "#{name} was never attempted — it cannot be unknown"
        assert s.evidence =~ "an earlier step couldn't be checked"
        # …and nothing below an unmade check carries advice either: the
        # stage-keyed copy would be the same guess, one rung down.
        assert is_nil(s.remediation),
               "#{name}: a rung skipped behind unknown must carry no advice"
      end

      # (2) A normally-pending domain (a fresh attach, records still
      # propagating) must NOT flip: no rung anywhere reads unknown.
      waiting = platform(DomainStatus.check(bp, dns: dns_map(%{})))

      assert Enum.map(waiting.stages, & &1.status) == ~w(pending pending pending pending)
      refute Enum.any?(waiting.stages, &(&1.status == "unknown"))
      assert waiting.overall == "pending"

      # (3) An all-green domain is untouched by any of this.
      green = platform(DomainStatus.check(bp, green_seams(bp)))
      assert green.overall == "ok"
      refute Enum.any?(green.stages, &(&1.status == "unknown"))
    end

    test "the SECOND lie: a resolver that dies on the BOX host no longer says the instance never reported" do
      {_u, team} = user_with_team()
      # The box's host is a NAME, so expected_addrs/2 resolves it too (:358).
      bp = live_barkpark(team, %{host: "box.example.net"})
      fqdn = Barkpark.provisioning_fqdn(bp)

      # The domain answers; the BOX host's lookup faults.
      result =
        DomainStatus.check(bp,
          dns: fn charlist, family ->
            case {to_string(charlist), family} do
              {^fqdn, :inet} -> {:ok, [{203, 0, 113, 10}]}
              {^fqdn, :inet6} -> {:ok, []}
              _ -> {:error, :timeout}
            end
          end
        )

      dom = platform(result)
      assert stage(dom, "dns_found").status == "ok"

      ph = stage(dom, "points_here")
      assert ph.status == "unknown"
      # The instance DID report an address — never claim otherwise.
      refute ph.evidence =~ "hasn't reported an address yet"
      assert ph.evidence =~ "Could not check where"
      assert ph.evidence =~ "timed out"
      assert is_nil(ph.remediation)

      assert dom.overall == "unknown"
      assert result.ok == false

      # The control, one field apart: the instance genuinely has no host yet.
      no_host = live_barkpark(team, %{host: nil, url: "https://no-host.barkpark.cloud"})
      no_host_fqdn = Barkpark.provisioning_fqdn(no_host)

      unreported =
        no_host
        |> DomainStatus.check(dns: dns_map(%{no_host_fqdn => [{203, 0, 113, 10}]}))
        |> platform()
        |> stage("points_here")

      assert unreported.status == "pending"
      assert unreported.evidence =~ "hasn't reported an address yet"
    end

    test "a fault on ONE family while the other answers is still a MEASUREMENT (ok, not unknown)" do
      {_u, team} = user_with_team()
      bp = live_barkpark(team)
      fqdn = Barkpark.provisioning_fqdn(bp)

      result =
        DomainStatus.check(bp,
          dns: fn charlist, family ->
            case {to_string(charlist), family} do
              {^fqdn, :inet} -> {:ok, [{203, 0, 113, 10}]}
              # The inet6 lookup genuinely FAULTS (a timeout, not an answer) —
              # we still measured what we needed on the other family.
              {_, :inet6} -> {:error, :timeout}
              _ -> {:ok, []}
            end
          end,
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:ok, 200})
        )

      dom = platform(result)
      assert stage(dom, "dns_found").status == "ok"
      assert dom.overall == "ok"
      assert result.ok == true
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

    test "a redirecting root (302) is serving OK — live instances redirect to login",
         %{bp: bp, base: base} do
      # Proven on prod: a HEALTHY instance's root returns 302. The Verify
      # doctrine (< 500 proves the DNS→TLS→routing→app chain) applies; a strict
      # 2xx would red-line every live box.
      result =
        DomainStatus.check(bp,
          dns: base[:dns],
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:ok, 302})
        )

      serving = stage(platform(result), "serving")
      assert serving.status == "ok"
      assert serving.evidence =~ "302"
    end
  end

  # ── points_here: address canonicalization ──

  describe "DomainStatus.check/2 — IPv6 host canonicalization" do
    test "a non-canonical stored IPv6 host still matches the resolver's canonical form" do
      {_u, team} = user_with_team()
      # Stored with leading zeros / uppercase — NOT :inet.ntoa's canonical form.
      bp = live_barkpark(team, %{host: "2001:0DB8:0000:0000:0000:0000:0000:0001"})
      fqdn = Barkpark.provisioning_fqdn(bp)

      result =
        DomainStatus.check(bp,
          dns: dns_map_inet6(%{fqdn => [{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}]}),
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:ok, 200})
        )

      assert stage(platform(result), "points_here").status == "ok"
    end
  end

  # ── the REAL TLS dialer, against a loopback :ssl server (no network) ──

  describe "TlsDialer.probe/2 — real handshake + DER decode over loopback" do
    test "obtains and decodes the served certificate (validity window, issuer CN, not self-signed)" do
      # A generated CA→peer chain (:public_key.pkix_test_data) served by a
      # loopback :ssl listener — this exercises the REAL greenfield primitives
      # (ssl.connect, peercert, the ASN.1 UTCTime/rdnSequence decode) that the
      # seam fakes above deliberately bypass. Loopback only; nothing leaves the
      # box.
      # Explicit RSA keys: the generator's default key type can't satisfy a
      # TLS 1.3 signature-algorithm negotiation (handshake_failure
      # unable_to_supply_acceptable_cert).
      key = {:key, {:rsa, 2048, 65_537}}

      conf =
        :public_key.pkix_test_data(%{
          server_chain: %{root: [key], intermediates: [], peer: [key]},
          client_chain: %{root: [key], intermediates: [], peer: [key]}
        })

      {:ok, listen} = :ssl.listen(0, [active: false, ip: {127, 0, 0, 1}] ++ conf[:server_config])
      {:ok, {_addr, port}} = :ssl.sockname(listen)

      server =
        Task.async(fn ->
          with {:ok, tsock} <- :ssl.transport_accept(listen, 5_000),
               {:ok, sock} <- :ssl.handshake(tsock, 5_000) do
            # Hold the socket until the probe has read the peer cert.
            receive do
              :done -> :ssl.close(sock)
            after
              5_000 -> :ssl.close(sock)
            end
          end
        end)

      result = BarkparkCloud.DomainStatus.TlsDialer.probe("127.0.0.1", port)
      send(server.pid, :done)
      Task.await(server)
      :ssl.close(listen)

      assert {:ok, cert} = result
      assert %DateTime{} = cert.not_before
      assert %DateTime{} = cert.not_after
      # The generated cert is currently valid — the decoded window must agree.
      now = DateTime.utc_now()
      assert DateTime.compare(cert.not_before, now) == :lt
      assert DateTime.compare(now, cert.not_after) == :lt
      # Issuer CN decoded from the rdnSequence (never the "unknown" fallback);
      # peer is CA-signed, so issuer != subject.
      assert is_binary(cert.issuer) and cert.issuer not in ["", "unknown"]
      refute cert.self_signed?
    end

    test "a connection-refused port is {:error, _}, never a raise" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      assert {:error, _} = BarkparkCloud.DomainStatus.TlsDialer.probe("127.0.0.1", port)
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

  # ── the cross-surface fixture (generated by check/2, drift-gated) ──
  #
  # `cloud/priv/static/__fixtures__/domain-status.json` is folded from the REAL
  # DomainStatus.check/2 (fake seams) and is the ONE truth the Go CLI test and
  # the node SPA harness both read — so a label/evidence/shape change reds a gate
  # on all three runtimes instead of three hand-authored copies silently
  # disagreeing (the fmt-display-parity pattern). Regenerate after an intended
  # contract change:
  #
  #     DOMAIN_STATUS_FIXTURE_WRITE=1 mix test test/barkpark_cloud/domain_status_test.exs
  describe "cross-surface fixture — real check/2 output, drift-gated" do
    test "the committed fixture equals the freshly-generated envelopes" do
      generated = fixture_json()

      if System.get_env("DOMAIN_STATUS_FIXTURE_WRITE") == "1" do
        File.write!(@fixture_path, generated)
      end

      assert File.exists?(@fixture_path),
             "missing #{@fixture_path} — generate it with DOMAIN_STATUS_FIXTURE_WRITE=1"

      assert File.read!(@fixture_path) == generated, """
      cloud/priv/static/__fixtures__/domain-status.json has drifted from the real
      DomainStatus.check/2 output. Regenerate it (the Go CLI test + node SPA
      harness read the SAME file, so a drift reds all three runtimes):

          DOMAIN_STATUS_FIXTURE_WRITE=1 mix test test/barkpark_cloud/domain_status_test.exs
      """
    end

    test "the fixture carries the REAL server strings + null remediation on ok rungs" do
      cases = @fixture_path |> File.read!() |> Jason.decode!()

      dom = cases["all_serving"]["domains"] |> hd()

      assert Enum.map(dom["stages"], & &1["label"]) ==
               ["DNS resolves", "Points to this instance", "TLS certificate", "Serving traffic"]

      # ok rungs carry JSON null remediation (never "") — Go decodes null→"" and
      # the SPA coerces non-strings→"", so null is safe on both consumers.
      assert Enum.all?(dom["stages"], &(&1["status"] == "ok" and is_nil(&1["remediation"])))

      # the serving_failed scenario is exactly [ok, ok, ok, failed] — the state
      # the SPA terminal fold keeps polling.
      failed = cases["serving_failed"]["domains"] |> hd()
      assert Enum.map(failed["stages"], & &1["status"]) == ~w(ok ok ok failed)

      # The resolver-fault scenario the SPA + CLI folds read: the ATTEMPTED rung
      # is unknown with NO advice attached, the skipped rungs stay pending, and
      # the envelope does not seal.
      faulted = cases["resolver_faulted"]["domains"] |> hd()
      assert Enum.map(faulted["stages"], & &1["status"]) == ~w(unknown pending pending pending)
      assert faulted["overall"] == "unknown"
      assert cases["resolver_faulted"]["ok"] == false

      dns = hd(faulted["stages"])
      assert is_nil(dns["remediation"])
      # Nothing in an unknown-fronted host advises: not the unmeasured rung, and
      # not the rungs it skipped (the SPA renders one amber note per remediation
      # string, so a single leak would put "give it a moment" under a guess).
      assert Enum.all?(faulted["stages"], &is_nil(&1["remediation"]))
      assert dns["evidence"] =~ "Could not check whether"
      refute dns["evidence"] =~ "has propagated yet"
    end
  end

  # ── Site-aware check/2: estate = the site's domains, mode from the record ──
  #
  # These build in-memory %Site{} structs (no DB) exactly like `fixture_barkpark`,
  # so they exercise the estate + mode branch without needing the
  # `cf-edge-binding-schema` migration. `serving_mode` is attached with `Map.put`
  # — the same value `Map.get(site, :serving_mode)` reads once the column lands —
  # so a row that PREDATES the column (the field genuinely absent) degrades to
  # :direct, the standalone-first fallback.

  @site_domain "shop.example.com"

  defp site_struct(opts) do
    site =
      struct(Site, %{
        id: "33333333-4444-5555-6666-777777777777",
        domains: Keyword.get(opts, :domains, [@site_domain]),
        barkpark: %Barkpark{host: Keyword.get(opts, :box, @host)}
      })

    case Keyword.get(opts, :mode) do
      nil -> site
      mode -> Map.put(site, :serving_mode, mode)
    end
  end

  describe "DomainStatus.check/2 — Site estate, :direct mode" do
    test "a :direct site's domain compares addr == box exactly (all green)" do
      result =
        DomainStatus.check(site_struct(mode: :direct),
          dns: dns_map(%{@site_domain => [{203, 0, 113, 10}]}),
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:ok, 200})
        )

      assert result.ok == true
      assert result.instance == %{id: "33333333-4444-5555-6666-777777777777", host: @host}
      assert [dom] = result.domains
      assert dom.kind == "custom"
      assert dom.host == @site_domain
      assert Enum.map(dom.stages, & &1.stage) == ~w(dns_found points_here tls serving)
      assert dom.overall == "ok"
      assert stage(dom, "points_here").status == "ok"
      assert stage(dom, "points_here").evidence =~ @host
    end

    test "a :direct site resolving ELSEWHERE fails points_here (the box-mismatch red)" do
      result =
        DomainStatus.check(site_struct(mode: :direct),
          dns: dns_map(%{@site_domain => [{198, 51, 100, 9}]}),
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:ok, 200})
        )

      dom = custom(result)
      assert dom.overall == "failed"
      ph = stage(dom, "points_here")
      assert ph.status == "failed"
      assert ph.evidence =~ "198.51.100.9"
      assert is_binary(ph.remediation)
      # downstream of the failed rung is skipped, never probed-and-red
      assert stage(dom, "tls").status == "pending"
      assert stage(dom, "serving").status == "pending"
    end

    test "a nil serving_mode (legacy row) degrades to :direct — fail-closed" do
      # serving_mode is now a real Site column (default "direct"), so the struct
      # always HAS the key. The fail-closed case that still matters is a row whose
      # serving_mode is nil (a pre-CF legacy row read before backfill): it must
      # degrade to :direct, never crash or assume proxied.
      site = %{site_struct(domains: [@site_domain]) | serving_mode: nil}
      assert is_nil(site.serving_mode)

      result =
        DomainStatus.check(site,
          dns: dns_map(%{@site_domain => [{198, 51, 100, 9}]}),
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:ok, 200})
        )

      # Behaves EXACTLY as :direct: a non-box address is a real failure.
      assert stage(custom(result), "points_here").status == "failed"
    end

    test "a site with no domains yet is an empty estate, overall ok" do
      result = DomainStatus.check(site_struct(domains: []), dns: dns_map(%{}))
      assert result.domains == []
      assert result.ok == true
    end
  end

  describe "DomainStatus.check/2 — Site :cf_proxied mode" do
    test "points_here is :proxied (informational, no remediation); tls + serving still run" do
      result =
        DomainStatus.check(site_struct(mode: :cf_proxied),
          # CF anycast edge — NOT the box origin.
          dns: dns_map(%{@site_domain => [{104, 16, 0, 1}]}),
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:ok, 200})
        )

      dom = custom(result)
      ph = stage(dom, "points_here")
      assert ph.status == "proxied"
      assert ph.remediation == nil
      assert ph.evidence =~ "Cloudflare"
      # the proxy rung does not block the chain — TLS/serving probe the CF edge
      assert stage(dom, "tls").status == "ok"
      assert stage(dom, "serving").status == "ok"
      # an informational :proxied rung does not count against overall/ok
      assert dom.overall == "ok"
      assert result.ok == true
    end

    test "mode is read FROM THE RECORD, never inferred from the IP: the SAME resolved" <>
           " address that fails :direct is :proxied under :cf_proxied" do
      resolved = %{@site_domain => [{198, 51, 100, 9}]}
      seams = [tls: tls_const({:ok, valid_cert()}), http: http_const({:ok, 200})]

      direct =
        DomainStatus.check(site_struct(mode: :direct), [dns: dns_map(resolved)] ++ seams)

      proxied =
        DomainStatus.check(site_struct(mode: :cf_proxied), [dns: dns_map(resolved)] ++ seams)

      assert stage(custom(direct), "points_here").status == "failed"
      assert stage(custom(proxied), "points_here").status == "proxied"
    end

    test "even resolving to the BOX IP is :proxied, never :ok — mode wins over the IP" do
      # The strongest "never inferred from the IP" proof: a :cf_proxied domain
      # that happens to resolve straight to the box origin is STILL reported
      # :proxied (informational), not the :direct :ok match — because the mode is
      # read from the record, not computed from the address.
      result =
        DomainStatus.check(site_struct(mode: :cf_proxied),
          dns: dns_map(%{@site_domain => [{203, 0, 113, 10}]}),
          tls: tls_const({:ok, valid_cert()}),
          http: http_const({:ok, 200})
        )

      assert stage(custom(result), "points_here").status == "proxied"
    end

    test "a :cf_proxied domain whose DNS hasn't propagated is still pending (not proxied)" do
      # No resolution yet — dns_found is pending, so points_here is SKIPPED into
      # pending, never prematurely labelled proxied.
      result = DomainStatus.check(site_struct(mode: :cf_proxied), dns: dns_map(%{}))
      dom = custom(result)
      assert stage(dom, "dns_found").status == "pending"
      assert stage(dom, "points_here").status == "pending"
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

  # ── the Site route ──

  describe "GET /v1/sites/:id/domain-status" do
    # Same config-seam fake as the barkparks route: check/1 reads the config
    # seams, so program a per-process RouteFake and point the three seam keys at
    # it.
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

    test "returns the green Site envelope for the owner (custom domain vs the box)" do
      {user, team} = user_with_team()
      site = live_site(team, %{domains: [@site_domain]})

      __MODULE__.RouteFake.program(
        dns: %{@site_domain => [{203, 0, 113, 10}]},
        tls: %{@site_domain => {:ok, valid_cert()}},
        http: %{("https://" <> @site_domain) => {:ok, 200}}
      )

      conn = call(:get, "/v1/sites/#{site.id}/domain-status", session_token(user))
      assert conn.status == 200

      body = json_body(conn)
      assert body["ok"] == true
      assert body["instance"]["id"] == site.id
      assert [dom] = body["domains"]
      assert dom["kind"] == "custom"
      assert dom["host"] == @site_domain
      assert Enum.map(dom["stages"], & &1["stage"]) == ~w(dns_found points_here tls serving)
      assert Enum.all?(dom["stages"], &(&1["status"] == "ok"))
    end

    test "a wrong-team / nonexistent / malformed id is the SAME 404 (no leak, no CastError)" do
      {_owner, team_a} = user_with_team()
      site = live_site(team_a)
      {intruder, _team_b} = user_with_team()

      c1 = call(:get, "/v1/sites/#{site.id}/domain-status", session_token(intruder))
      c2 = call(:get, "/v1/sites/not-a-uuid/domain-status", session_token(intruder))

      assert c1.status == 404
      assert c2.status == 404
    end

    test "no auth → 401" do
      {_u, team} = user_with_team()
      site = live_site(team)
      conn = call(:get, "/v1/sites/#{site.id}/domain-status", nil)
      assert conn.status == 401
    end
  end

  # A live Site on a box at @host, with one or more custom domains.
  defp live_site(team, attrs \\ %{}) do
    bp = live_barkpark(team)
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(
        bp,
        Enum.into(attrs, %{name: "Site #{n}", slug: "site-#{n}", domains: [@site_domain]})
      )

    site
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
