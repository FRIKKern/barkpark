defmodule BarkparkCloud.Web.HetznerProxyTest do
  @moduledoc """
  The Hetzner read-only control-plane proxy (charter decision 3) — the
  dashboard's server-side path into a team's Hetzner account. Proves:

    * `GET /v1/hetzner/overview` emits EXACTLY the charter envelope: ok /
      fetched_at / provider{kind,label} / all nine resources keys / matching
      counts, rows carrying at least id/name/status ("n/a" where the kind has
      none)
    * the vault-stored token is decrypted SERVER-SIDE (the upstream sees the
      Bearer) and NEVER appears in any response body
    * no connected hetzner provider → 404 no_provider (and the upstream is
      never called); teamless users get the same 404
    * one upstream kind failing degrades PER KIND (that kind null, count 0,
      an errors map entry) — the envelope never 500s over one bad upstream
    * tampered ciphertext fails closed (500 decrypt_failed, no upstream call)
    * `GET /v1/hetzner/catalog` serializes resource/verb/tier/params ONLY —
      no upstream paths, no upstream host
    * both routes are authed: no token → 401
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.HetznerFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @password "correct-horse-battery"
  @hetzner_token "hetzner-api-token-plaintext-XYZ"

  @overview_keys ~w(servers volumes networks firewalls load_balancers floating_ips primary_ips dns_zones backups)

  ## Fixtures (mirror RouterStudioLinkTest's)

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

  defp connect_hetzner(team, label \\ "prod account") do
    {:ok, provider} = Registry.connect_provider(team, "hetzner", @hetzner_token, label: label)
    provider
  end

  defp call(method, path, token \\ nil) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  # Canned 200s for all nine upstream reads — realistic Hetzner shapes:
  # networks/firewalls carry no status; backups are name-less images whose
  # description is the human handle.
  defp program_happy_upstream do
    HetznerFakeHttpClient.program(%{
      "/v1/servers" => ok_json(~s({"servers":[
          {"id":42,"name":"guerrilla","status":"running"},
          {"id":43,"name":"barkpark-cp","status":"running"}
        ]})),
      "/v1/volumes" => ok_json(~s({"volumes":[{"id":7,"name":"data","status":"available"}]})),
      "/v1/networks" => ok_json(~s({"networks":[{"id":1,"name":"internal"}]})),
      "/v1/firewalls" => ok_json(~s({"firewalls":[{"id":2,"name":"web"}]})),
      "/v1/load_balancers" => ok_json(~s({"load_balancers":[]})),
      "/v1/floating_ips" => ok_json(~s({"floating_ips":[{"id":9,"name":"fip-1"}]})),
      "/v1/primary_ips" => ok_json(~s({"primary_ips":[{"id":11,"name":"pip-1"}]})),
      "/v1/zones" => ok_json(~s({"zones":[{"id":"z1","name":"barkpark.cloud","status":"ok"}]})),
      "/v1/images" =>
        ok_json(
          ~s({"images":[{"id":100,"name":null,"description":"nightly backup","status":"available"}]})
        )
    })
  end

  defp ok_json(body), do: {:ok, %{status: 200, body: body}}

  describe "GET /v1/hetzner/overview" do
    test "happy path → the exact charter envelope: nine kinds, matching counts, id/name/status rows" do
      {user, team} = user_with_team()
      connect_hetzner(team)
      program_happy_upstream()

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      body = json_body(conn)

      # The charter-frozen top level.
      assert body["ok"] == true
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(body["fetched_at"])
      assert body["provider"] == %{"kind" => "hetzner", "label" => "prod account"}
      refute Map.has_key?(body, "errors")

      # All nine resources keys, nothing extra; counts mirror row lengths.
      assert body["resources"] |> Map.keys() |> Enum.sort() == Enum.sort(@overview_keys)
      assert body["counts"] |> Map.keys() |> Enum.sort() == Enum.sort(@overview_keys)

      for key <- @overview_keys do
        assert body["counts"][key] == length(body["resources"][key])
      end

      assert body["counts"]["servers"] == 2
      assert body["counts"]["load_balancers"] == 0

      # Rows carry at least id/name/status; "n/a" where the kind has none.
      assert %{"id" => 42, "name" => "guerrilla", "status" => "running"} in body["resources"][
               "servers"
             ]

      assert [%{"id" => 1, "name" => "internal", "status" => "n/a"}] =
               body["resources"]["networks"]

      # A name-less backup image falls back to its description, never null.
      assert [%{"id" => 100, "name" => "nightly backup", "status" => "available"}] =
               body["resources"]["backups"]

      assert [%{"id" => "z1", "name" => "barkpark.cloud", "status" => "ok"}] =
               body["resources"]["dns_zones"]
    end

    test "the token is decrypted server-side for the upstream and NEVER appears in the response" do
      {user, team} = user_with_team()
      connect_hetzner(team)
      program_happy_upstream()

      conn = call(:get, "/v1/hetzner/overview", session_token(user))
      assert conn.status == 200

      # Nine upstream calls, each authenticated with the DECRYPTED token —
      # proof the vault round-trip happened on the server.
      requests = HetznerFakeHttpClient.requests()
      assert length(requests) == 9

      for req <- requests do
        assert {"Authorization", "Bearer " <> @hetzner_token} =
                 List.keyfind(req.headers, "Authorization", 0)
      end

      # Backups ride the catalog's allowed type=backup query, and every read
      # asks for the 50-row page max (counts must be estate truth).
      assert Enum.any?(requests, &(&1.url =~ "/v1/images?type=backup&"))
      assert Enum.all?(requests, &(&1.url =~ "per_page=50"))

      # The raw token must never reach the browser.
      refute conn.resp_body =~ @hetzner_token
    end

    test "no connected hetzner provider → 404 no_provider, upstream never called" do
      {user, _team} = user_with_team()
      HetznerFakeHttpClient.program(%{})

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 404
      assert json_body(conn) == %{"error" => "no_provider"}
      assert HetznerFakeHttpClient.requests() == []
    end

    test "teamless user → the same 404 no_provider" do
      user = user_fixture()
      HetznerFakeHttpClient.program(%{})

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 404
      assert json_body(conn) == %{"error" => "no_provider"}
    end

    test "one upstream kind failing → envelope still ok, that kind null + counted 0 + named in errors" do
      {user, team} = user_with_team()
      connect_hetzner(team)

      # Volumes 500s; servers is healthy; the other seven ride the fake's
      # empty-200 default.
      HetznerFakeHttpClient.program(%{
        "/v1/servers" =>
          ok_json(~s({"servers":[{"id":42,"name":"guerrilla","status":"running"}]})),
        "/v1/volumes" => {:ok, %{status: 500, body: ~s({"error":{"code":"unavailable"}})}}
      })

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      body = json_body(conn)

      assert body["ok"] == true
      assert body["resources"]["volumes"] == nil
      assert body["counts"]["volumes"] == 0
      assert body["errors"] == %{"volumes" => "http_500"}

      # The healthy kinds are untouched.
      assert body["counts"]["servers"] == 1
      assert is_list(body["resources"]["networks"])
      refute conn.resp_body =~ @hetzner_token
    end

    test "a transport-level failure degrades the same way, with a SAFE reason" do
      {user, team} = user_with_team()
      connect_hetzner(team)

      HetznerFakeHttpClient.program(%{
        "/v1/servers" => {:error, {:http_client, :timeout}}
      })

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      body = json_body(conn)
      assert body["ok"] == true
      assert body["resources"]["servers"] == nil
      assert body["errors"]["servers"] == "unreachable"
      refute conn.resp_body =~ @hetzner_token
    end

    test "a paginated estate is walked to the last page — counts are estate truth, not first-page truth" do
      {user, team} = user_with_team()
      connect_hetzner(team)

      # Hetzner pages at 25 by default (50 max) — the proxy must follow
      # meta.pagination.next_page or a 60-server fleet reads as 50.
      HetznerFakeHttpClient.program(%{
        "/v1/servers?per_page=50&page=1" =>
          ok_json(
            ~s({"servers":[{"id":1,"name":"a","status":"running"},{"id":2,"name":"b","status":"running"}],"meta":{"pagination":{"page":1,"next_page":2}}})
          ),
        "/v1/servers?per_page=50&page=2" =>
          ok_json(
            ~s({"servers":[{"id":3,"name":"c","status":"running"}],"meta":{"pagination":{"page":2,"next_page":null}}})
          )
      })

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      body = json_body(conn)

      assert body["counts"]["servers"] == 3
      assert Enum.map(body["resources"]["servers"], & &1["id"]) == [1, 2, 3]

      server_urls =
        HetznerFakeHttpClient.requests()
        |> Enum.map(& &1.url)
        |> Enum.filter(&(&1 =~ "/v1/servers"))

      assert length(server_urls) == 2
    end

    test "a failure on a LATER page degrades the whole kind — partial rows never lie about counts" do
      {user, team} = user_with_team()
      connect_hetzner(team)

      HetznerFakeHttpClient.program(%{
        "/v1/servers?per_page=50&page=1" =>
          ok_json(
            ~s({"servers":[{"id":1,"name":"a","status":"running"}],"meta":{"pagination":{"page":1,"next_page":2}}})
          ),
        "/v1/servers?per_page=50&page=2" => {:ok, %{status: 502, body: ""}}
      })

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      body = json_body(conn)
      assert body["resources"]["servers"] == nil
      assert body["counts"]["servers"] == 0
      assert body["errors"]["servers"] == "http_502"
    end

    test "a next_page pointing at or behind the current page cannot loop the walk" do
      {user, team} = user_with_team()
      connect_hetzner(team)

      # A hostile/buggy upstream that points back at page 1 forever.
      HetznerFakeHttpClient.program(%{
        "/v1/servers?per_page=50&page=1" =>
          ok_json(
            ~s({"servers":[{"id":1,"name":"a","status":"running"}],"meta":{"pagination":{"page":1,"next_page":1}}})
          )
      })

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      assert json_body(conn)["counts"]["servers"] == 1

      server_urls =
        HetznerFakeHttpClient.requests()
        |> Enum.map(& &1.url)
        |> Enum.filter(&(&1 =~ "/v1/servers"))

      assert length(server_urls) == 1
    end

    test "with several connected hetzner accounts the NEWEST is the one proxied" do
      {user, team} = user_with_team()

      older = connect_hetzner(team, "old account")

      older
      |> Ecto.Changeset.change(inserted_at: DateTime.add(older.inserted_at, -3600, :second))
      |> Repo.update!()

      connect_hetzner(team, "new account")
      program_happy_upstream()

      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 200
      assert json_body(conn)["provider"]["label"] == "new account"
    end

    test "tampered ciphertext fails closed: 500 decrypt_failed, upstream never called" do
      {user, team} = user_with_team()
      provider = connect_hetzner(team)

      provider
      |> Ecto.Changeset.change(encrypted_token: Base.encode64("not-real-ciphertext-material"))
      |> Repo.update!()

      HetznerFakeHttpClient.program(%{})
      conn = call(:get, "/v1/hetzner/overview", session_token(user))

      assert conn.status == 500
      assert json_body(conn) == %{"error" => "decrypt_failed"}
      assert HetznerFakeHttpClient.requests() == []
    end

    test "no auth → 401" do
      conn = call(:get, "/v1/hetzner/overview")
      assert conn.status == 401
    end
  end

  describe "GET /v1/hetzner/catalog" do
    test "serializes resource/verb/tier/params ONLY — no upstream paths or host" do
      {user, _team} = user_with_team()

      conn = call(:get, "/v1/hetzner/catalog", session_token(user))

      assert conn.status == 200
      %{"catalog" => entries} = json_body(conn)
      assert entries != []

      for entry <- entries do
        assert Map.keys(entry) |> Enum.sort() == ["params", "resource", "tier", "verb"]
        assert entry["tier"] in ["read", "mutate", "destroy"]
      end

      # The nine reads are all listed; mutations are declared with their tier
      # so the dashboard can render the confirm grammar before wave 3 routes them.
      reads = Enum.filter(entries, &(&1["tier"] == "read"))
      assert Enum.map(reads, & &1["resource"]) |> Enum.sort() == Enum.sort(@overview_keys)

      assert Enum.any?(entries, &(&1["resource"] == "servers" and &1["verb"] == "reboot"))

      destroys = Enum.filter(entries, &(&1["tier"] == "destroy"))
      assert destroys != []
      assert Enum.all?(destroys, &("confirm" in &1["params"]))

      # Upstream internals never leave the server.
      refute conn.resp_body =~ "api.hetzner.cloud"
      refute conn.resp_body =~ "/v1/servers"
    end

    test "no auth → 401" do
      conn = call(:get, "/v1/hetzner/catalog")
      assert conn.status == 401
    end
  end
end
