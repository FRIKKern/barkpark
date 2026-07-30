defmodule BarkparkCloud.Web.RouterAttachDomainV2Test do
  @moduledoc """
  Attach-domain V2 — arbitrary EXTERNAL customer domains over the HTTP surface.
  Proves:

    * the ownership moat: `POST /v1/barkparks/:id/domain` with a customer FQDN
      only 202s when the domain ALREADY resolves (A/AAAA, injectable resolver
      seam `:attach_domain_dns`) to the instance's box IP; a mismatch is a 422
      `{error: "domain_not_pointed", expected_ip, observed}` with NOTHING
      persisted or enqueued — fail-closed, resolver errors included
    * the claim contract for an external host: `dns_label`/`dns_zone` are null
      (the customer owns DNS; the worker skips the platform upsert), everything
      else identical to the platform contract
    * the platform-zone path is UNCHANGED: a platform host never consults the
      resolver
    * malformed external FQDNs → 422 invalid_domain BEFORE any resolution
    * the TLS ask-gate approves an attached external host

  async: false — the resolver seam is injected via the shared application env
  (the DomainStatusTest precedent).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.ProvisionJob
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"
  @domain "barkpark.jarl.no"
  @box_ip "203.0.113.10"
  @box_ip_tuple {203, 0, 113, 10}
  @other_ip_tuple {198, 51, 100, 7}

  ## Fixtures (mirror RouterAttachDomainTest's)

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team(role \\ "owner") do
    user = user_fixture()
    n = System.unique_integer([:positive])
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
    bp = barkpark_fixture(team)
    {:ok, _} = Registry.upsert_health(bp, %{host: @box_ip})
    Registry.get_barkpark(bp.id)
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp active_attaches(bp) do
    from(j in ProvisionJob,
      where:
        j.barkpark_id == ^bp.id and j.kind == "attach_domain" and
          j.status in ["pending", "claimed"]
    )
    |> Repo.aggregate(:count, :id)
  end

  # Inject the resolver seam (the `(charlist, family)` getaddrs shape shared
  # with the DomainStatus dns seam) and restore it after the test.
  defp with_dns(fun) do
    prev = Application.fetch_env(:barkpark_cloud, :attach_domain_dns)
    Application.put_env(:barkpark_cloud, :attach_domain_dns, fun)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:barkpark_cloud, :attach_domain_dns, v)
        :error -> Application.delete_env(:barkpark_cloud, :attach_domain_dns)
      end
    end)
  end

  # A resolver that answers `addrs` on :inet, nothing on :inet6, and pings the
  # test process (the Router.call runs in-process) so consultation is provable.
  defp pointed_resolver(addrs) do
    test_pid = self()

    fn charlist, family ->
      send(test_pid, {:resolved, to_string(charlist), family})

      case family do
        :inet -> {:ok, addrs}
        :inet6 -> {:error, :nxdomain}
      end
    end
  end

  describe "POST /v1/barkparks/:id/domain — external customer FQDN" do
    test "pointed at the box → 202, custom_host persisted, job enqueued, ask-gate flips 200" do
      with_dns(pointed_resolver([@box_ip_tuple]))
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = session_token(user)

      assert call(:get, "/v1/tls/ask?domain=#{@domain}").status == 404

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, token)

      assert conn.status == 202

      assert json_body(conn) == %{
               "ok" => true,
               "custom_host" => @domain,
               "status" => "attaching"
             }

      assert_received {:resolved, @domain, :inet}

      assert Registry.get_barkpark(bp.id).custom_host == @domain
      assert active_attaches(bp) == 1
      assert call(:get, "/v1/tls/ask?domain=#{@domain}").status == 200
    end

    test "the worker claim carries NULL dns halves for an external host (pinned contract)" do
      with_dns(pointed_resolver([@box_ip_tuple]))
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      assert call(
               :post,
               "/v1/barkparks/#{bp.id}/domain",
               %{domain: @domain},
               session_token(user)
             ).status == 202

      conn = call(:post, "/v1/internal/attach-domain-jobs/claim", %{}, @worker_token)
      assert conn.status == 200

      body = json_body(conn)
      [%ProvisionJob{} = job] = Repo.all(from(j in ProvisionJob, where: j.barkpark_id == ^bp.id))

      # The pinned cross-language contract — same keys as the platform claim,
      # dns_label/dns_zone null (the Go worker skips the platform-DNS upsert).
      assert body == %{
               "job_id" => job.id,
               "claim_token" => job.claim_token,
               "ip" => @box_ip,
               "custom_host" => @domain,
               "dns_label" => nil,
               "dns_zone" => nil,
               "app_port" => 4000
             }
    end

    test "not pointed → 422 domain_not_pointed {expected_ip, observed}, nothing persisted or enqueued" do
      with_dns(pointed_resolver([@other_ip_tuple]))
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, session_token(user))

      assert conn.status == 422

      assert json_body(conn) == %{
               "error" => "domain_not_pointed",
               "expected_ip" => @box_ip,
               "observed" => ["198.51.100.7"]
             }

      assert Registry.get_barkpark(bp.id).custom_host == nil
      assert active_attaches(bp) == 0
      assert call(:get, "/v1/tls/ask?domain=#{@domain}").status == 404
    end

    test "resolver failure → fail-closed 422 domain_not_pointed with empty observed" do
      with_dns(fn _charlist, _family -> {:error, :timeout} end)
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, session_token(user))

      assert conn.status == 422

      assert json_body(conn) == %{
               "error" => "domain_not_pointed",
               "expected_ip" => @box_ip,
               "observed" => []
             }

      assert Registry.get_barkpark(bp.id).custom_host == nil
      assert active_attaches(bp) == 0
    end

    test "a raising resolver is contained → fail-closed 422, never a 500" do
      with_dns(fn _charlist, _family -> raise "resolver blew up" end)
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, session_token(user))

      assert conn.status == 422
      assert json_body(conn)["error"] == "domain_not_pointed"
      assert Registry.get_barkpark(bp.id).custom_host == nil
    end

    test "an instance without a provisioned box (host nil) → 422 domain_not_pointed, resolver never consulted" do
      with_dns(pointed_resolver([@box_ip_tuple]))
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      assert bp.host == nil

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: @domain}, session_token(user))

      assert conn.status == 422

      assert json_body(conn) == %{
               "error" => "domain_not_pointed",
               "expected_ip" => nil,
               "observed" => []
             }

      refute_received {:resolved, _, _}
    end

    test "malformed external FQDN → 422 invalid_domain BEFORE any resolution" do
      with_dns(pointed_resolver([@box_ip_tuple]))
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = session_token(user)

      for bad <- ["intranet", "203.0.113.9", "foo.bar;rm -rf", "$(x).evil.com", "a..no"] do
        conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: bad}, token)
        assert conn.status == 422, "expected 422 for #{inspect(bad)}"
        assert json_body(conn) == %{"error" => "invalid_domain"}
      end

      refute_received {:resolved, _, _}
      assert Registry.get_barkpark(bp.id).custom_host == nil
      assert active_attaches(bp) == 0
    end

    test "normalization: mixed case / trailing dot resolves and stores the canonical host" do
      with_dns(pointed_resolver([@box_ip_tuple]))
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      conn =
        call(
          :post,
          "/v1/barkparks/#{bp.id}/domain",
          %{domain: "Barkpark.Jarl.No."},
          session_token(user)
        )

      assert conn.status == 202
      assert json_body(conn)["custom_host"] == @domain
      # The resolver saw the NORMALIZED host, never the raw input.
      assert_received {:resolved, @domain, :inet}
    end

    test "a platform-zone host never consults the resolver (V1 path unchanged)" do
      with_dns(pointed_resolver([@box_ip_tuple]))
      {user, team} = user_with_team()
      bp = live_barkpark(team)

      conn =
        call(
          :post,
          "/v1/barkparks/#{bp.id}/domain",
          %{domain: "gyldendal.barkpark.cloud"},
          session_token(user)
        )

      assert conn.status == 202
      refute_received {:resolved, _, _}

      # And the platform claim contract still carries the DNS halves.
      claim = json_body(call(:post, "/v1/internal/attach-domain-jobs/claim", %{}, @worker_token))
      assert claim["dns_label"] == "gyldendal"
      assert claim["dns_zone"] == "barkpark.cloud"
    end
  end
end
