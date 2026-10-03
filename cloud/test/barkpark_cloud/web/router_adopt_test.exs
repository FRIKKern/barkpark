defmodule BarkparkCloud.Web.RouterAdoptTest do
  @moduledoc """
  `POST /v1/barkparks/adopt` — a team admin attaches an already-running box
  (`Registry.Adoption`).

  Proves, through the real router and the `:studio_link_http_client` fake:

    * success: the row is created, Cloud's OWN minted token is stored (labelled
      `barkpark cloud admin`), the caller's token is stored nowhere and echoed
      nowhere, an unarmed box gets its enable_apply job, an audit row lands
    * refused with no row: wrong token, non-admin tier, a box already attached
      (any team, zero requests made), a box too old for /v1/tokens/elevated or
      /v1/tokens/current, an internal address (SSRF), a url not resolving to
      the host, an http:// url
    * gated: a plain member and a non-root PAT are refused before any request
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Accounts.AuditEvent
  alias BarkparkCloud.Registry.{Adoption, Barkpark, ProvisionJob}
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @caller_token "callers-own-box-admin-token"
  @minted "cloud-minted-admin-token"
  @ip "203.0.113.20"

  defp user_with_team(role \\ "owner") do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, session} = Accounts.create_user_session_token(user)
    {user, team, session}
  end

  defp body(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        "name" => "Standby #{n}",
        "slug" => "standby-#{n}",
        "url" => "https://#{@ip}",
        "host" => @ip,
        "admin_token" => @caller_token
      },
      overrides
    )
  end

  defp post_adopt(params, token) do
    conn(:post, "/v1/barkparks/adopt", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp ok(status, map), do: {:ok, %{status: status, body: Jason.encode!(map)}}

  defp happy_box(self_update \\ %{"apply_enabled" => false}) do
    [
      ok(200, %{"auth_tier" => "admin"}),
      ok(200, %{"token" => %{"id" => "callers-id", "workspace" => "acme"}}),
      ok(201, %{"token" => @minted, "id" => "tok-cloud-1", "workspace" => "acme"}),
      ok(200, %{"auth_tier" => "admin"}),
      ok(
        200,
        Map.merge(
          %{
            "check" => %{
              "state" => "current",
              "running_release" => "0.2.26",
              "latest_release" => "0.2.26"
            }
          },
          self_update
        )
      )
    ]
  end

  defp bearer(req) do
    Enum.find_value(req.headers, fn {k, v} -> if String.downcase(k) == "authorization", do: v end)
  end

  defp rows_for(team_id), do: Repo.all(from(b in Barkpark, where: b.team_id == ^team_id))

  describe "success" do
    test "Cloud stores its own minted credential, never the caller's, and arms self-update" do
      {_user, team, session} = user_with_team()
      StudioLinkFakeHttpClient.program(happy_box())

      conn = post_adopt(body(), session)
      assert conn.status == 201, conn.resp_body
      resp = Jason.decode!(conn.resp_body)

      refute conn.resp_body =~ @caller_token
      refute conn.resp_body =~ @minted
      assert resp["adopted"]["workspace"] == "acme"
      assert resp["adopted"]["credential_id"] == "tok-cloud-1"
      assert resp["adopted"]["credential_label"] == "barkpark cloud admin"
      assert resp["adopted"]["armed"]["self_update"]["status"] == "arming"
      assert resp["adopted"]["armed"]["monitoring_agent"]["status"] == "not_installed"

      [bp] = rows_for(team.id)
      assert bp.url == "https://#{@ip}"
      assert bp.host == @ip
      assert bp.mode == "managed"
      assert {:ok, @minted} = Registry.reveal_admin_token(bp)
      refute inspect(Map.from_struct(bp)) =~ @caller_token

      reqs = StudioLinkFakeHttpClient.requests()

      assert Enum.map(reqs, &{&1.method, URI.parse(&1.url).path}) == [
               {:get, "/v1/capabilities"},
               {:get, "/v1/tokens/current"},
               {:post, "/w/acme/p/default/v1/tokens/elevated"},
               {:get, "/v1/capabilities"},
               {:get, "/v1/admin/self-update"}
             ]

      assert Enum.map(reqs, &bearer/1) ==
               List.duplicate("Bearer " <> @caller_token, 3) ++
                 List.duplicate("Bearer " <> @minted, 2)

      mint = Enum.at(reqs, 2)

      assert %{"label" => "barkpark cloud admin", "permissions" => ["read", "write", "admin"]} =
               Jason.decode!(mint.body)

      assert Repo.exists?(
               from(j in ProvisionJob,
                 where:
                   j.barkpark_id == ^bp.id and j.kind == "enable_apply" and j.status == "pending"
               )
             )

      audit = Repo.one!(from(a in AuditEvent, where: a.target_id == ^bp.id))
      assert audit.action == "barkpark.adopted"
      refute inspect(audit.metadata) =~ @caller_token
      refute inspect(audit.metadata) =~ @minted
    end

    test "an already-armed box gets no enable_apply job" do
      {_user, team, session} = user_with_team()
      StudioLinkFakeHttpClient.program(happy_box(%{"apply_enabled" => true}))

      conn = post_adopt(body(), session)
      assert conn.status == 201, conn.resp_body
      assert Jason.decode!(conn.resp_body)["adopted"]["armed"]["self_update"]["status"] == "armed"
      [bp] = rows_for(team.id)
      refute Repo.exists?(from(j in ProvisionJob, where: j.barkpark_id == ^bp.id))
    end
  end

  describe "proof of control refused — no row" do
    test "a token the box rejects" do
      {_user, team, session} = user_with_team()
      StudioLinkFakeHttpClient.program([ok(401, %{"code" => "unauthorized"})])

      conn = post_adopt(body(), session)
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"] == "not_box_admin"
      assert rows_for(team.id) == []
      assert length(StudioLinkFakeHttpClient.requests()) == 1
    end

    test "a token below admin tier" do
      {_user, team, session} = user_with_team()
      StudioLinkFakeHttpClient.program([ok(200, %{"auth_tier" => "write"})])

      conn = post_adopt(body(), session)
      assert conn.status == 403
      assert %{"error" => "not_box_admin", "auth_tier" => "write"} = Jason.decode!(conn.resp_body)
      assert rows_for(team.id) == []
    end

    test "a box without /v1/tokens/elevated is told to update first" do
      {_user, team, session} = user_with_team()

      StudioLinkFakeHttpClient.program([
        ok(200, %{"auth_tier" => "admin"}),
        ok(200, %{"token" => %{"workspace" => "default"}}),
        ok(404, %{"code" => "not_found"})
      ])

      conn = post_adopt(body(), session)
      assert conn.status == 409
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"] == "box_too_old"
      assert resp["missing"] == "POST /v1/tokens/elevated"
      assert resp["detail"] =~ "Update the box"
      assert rows_for(team.id) == []
    end

    test "a box without /v1/tokens/current is told to update first" do
      {_user, team, session} = user_with_team()

      StudioLinkFakeHttpClient.program([
        ok(200, %{"auth_tier" => "admin"}),
        ok(404, %{"code" => "not_found"})
      ])

      conn = post_adopt(body(), session)
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["missing"] == "GET /v1/tokens/current"
      assert rows_for(team.id) == []
      assert length(StudioLinkFakeHttpClient.requests()) == 2
    end
  end

  describe "already attached / cross-team" do
    test "a host another team holds is refused before any request" do
      {_ua, team_a, _sa} = user_with_team()
      {_ub, team_b, session_b} = user_with_team()

      {:ok, _held} =
        Registry.adopt_barkpark(team_a, %{
          name: "A's box",
          slug: "a-box",
          url: "https://a-box.example.org",
          host: @ip,
          mode: "managed"
        })

      StudioLinkFakeHttpClient.program([])
      conn = post_adopt(body(), session_b)
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"] == "already_attached"
      refute conn.resp_body =~ team_a.id
      assert rows_for(team_b.id) == []
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "a url already attached is refused" do
      {_user, team, session} = user_with_team()

      {:ok, _} =
        Registry.adopt_barkpark(team, %{
          name: "Mine",
          slug: "mine",
          url: "https://#{@ip}",
          host: "198.51.100.9",
          mode: "managed"
        })

      StudioLinkFakeHttpClient.program([])
      conn = post_adopt(body(), session)
      assert conn.status == 409
      assert length(rows_for(team.id)) == 1
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "a plain member is refused" do
      {_user, team, session} = user_with_team("member")
      StudioLinkFakeHttpClient.program([])
      conn = post_adopt(body(), session)
      assert conn.status == 403
      assert rows_for(team.id) == []
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "a PAT without root is refused" do
      {user, team, _session} = user_with_team()

      {:ok, pat, _} =
        Accounts.create_personal_access_token(user, team, %{
          name: "write-key",
          abilities: ["write"]
        })

      StudioLinkFakeHttpClient.program([])
      conn = post_adopt(body(), pat)
      assert conn.status == 403
      assert rows_for(team.id) == []
      assert StudioLinkFakeHttpClient.requests() == []
    end
  end

  describe "SSRF and binding" do
    test "an internal address is refused before any request" do
      {_user, team, session} = user_with_team()
      StudioLinkFakeHttpClient.program([])

      conn = post_adopt(body(%{"url" => "https://10.0.0.5", "host" => "10.0.0.5"}), session)
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] == "unsafe_url"
      assert rows_for(team.id) == []
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "an http:// url is refused" do
      {_user, team, session} = user_with_team()
      StudioLinkFakeHttpClient.program([])
      conn = post_adopt(body(%{"url" => "http://#{@ip}"}), session)
      assert conn.status == 422
      assert rows_for(team.id) == []
      assert StudioLinkFakeHttpClient.requests() == []
    end

    # The hostname leg of the binding is the pure `bind_pinned/2`, fed what
    # `SafeUrl.pin/1` approves (SafeUrl's own tests cover its resolution and its
    # private-address refusal). No DNS is asked here.
    test "a url whose approved address is not the host is refused" do
      pinned = %{
        url: "https://198.51.100.7/",
        host: "box.example.test",
        server_name: "box.example.test"
      }

      assert {:error, {:host_mismatch, ["198.51.100.7"]}} = Adoption.bind_pinned(pinned, @ip)
    end

    test "a hostname url is pinned to the host, with its name as Host and TLS server name" do
      pinned = %{
        url: "https://#{@ip}/",
        host: "box.example.test",
        server_name: "box.example.test"
      }

      assert {:ok,
              %{
                base: "https://#{@ip}",
                host_header: "box.example.test",
                server_name: "box.example.test"
              }} =
               Adoption.bind_pinned(pinned, @ip)
    end

    test "an IP-literal url binds with no Host override" do
      pinned = %{url: "https://#{@ip}", host: nil, server_name: nil}

      assert {:ok, %{base: "https://#{@ip}", host_header: nil, server_name: nil}} =
               Adoption.bind_pinned(pinned, @ip)
    end

    test "a non-default port survives the binding" do
      pinned = %{
        url: "https://#{@ip}:8443/",
        host: "box.example.test:8443",
        server_name: "box.example.test"
      }

      assert {:ok, %{base: "https://#{@ip}:8443"}} = Adoption.bind_pinned(pinned, @ip)
    end
  end
end
