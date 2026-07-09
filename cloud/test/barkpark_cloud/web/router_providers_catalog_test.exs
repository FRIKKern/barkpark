defmodule BarkparkCloud.Web.RouterProvidersCatalogTest do
  @moduledoc """
  The provider-neutral control-plane surface (S3):

    * `GET /v1/providers/:kind/catalog` returns the SAME normalized
      `{regions, server_types:[{slug,cores,ram_gb,disk_gb,monthly_price}]}` shape
      for BOTH hetzner and azure — one menu, any provider
    * `GET /v1/providers/:kind/overview` wraps that menu with the provider header
    * the Hetzner improvement: the normalized catalog now carries monthly_price,
      threaded from hcloud's per-type pricing
    * the existing `/v1/hetzner/*` routes (action catalog + estate overview) are
      untouched — still working, different concern
    * an unknown kind → 404; no connected provider → 404 no_provider
    * verify-before-save: a POST whose credential can't authenticate is NOT
      saved and returns the per-kind remediation copy (over the Fake client)
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, FailureCopy, Registry}
  alias BarkparkCloud.Azure.FakeClient
  alias BarkparkCloud.HetznerFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @server_type_keys ~w(cores disk_gb monthly_price ram_gb slug)

  ## Fixtures

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

  defp azure_blob(overrides \\ %{}) do
    %{
      "tenant_id" => "11111111-1111-1111-1111-111111111111",
      "client_id" => "22222222-2222-2222-2222-222222222222",
      "client_secret" => "good-secret",
      "subscription_id" => "33333333-3333-3333-3333-333333333333"
    }
    |> Map.merge(overrides)
  end

  defp connect_hetzner(team),
    do: Registry.connect_provider(team, "hetzner", "hz-token", label: "hz")

  defp connect_azure(team),
    do: Registry.connect_provider(team, "azure", Jason.encode!(azure_blob()), label: "az")

  defp call(method, path, body \\ nil, token \\ nil) do
    conn = if body, do: conn(method, path, body), else: conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp program_hetzner_catalog do
    HetznerFakeHttpClient.program(%{
      "/v1/server_types" =>
        {:ok,
         %{
           status: 200,
           body: ~s({"server_types":[
               {"name":"cax21","cores":4,"memory":8.0,"disk":80,"deprecated":false,
                "prices":[{"location":"hel1","price_monthly":{"gross":"6.4900000000"}}]},
               {"name":"cax11","cores":2,"memory":4.0,"disk":40,"deprecated":true,
                "prices":[{"location":"hel1","price_monthly":{"gross":"3.79"}}]}
             ]})
         }},
      "/v1/locations" =>
        {:ok,
         %{
           status: 200,
           body: ~s({"locations":[{"name":"hel1","city":"Helsinki","country":"FI"}]})
         }}
    })
  end

  describe "GET /v1/providers/:kind/catalog — normalized, per provider" do
    test "hetzner → {regions, server_types} with monthly_price threaded (deprecated dropped)" do
      {user, team} = user_with_team()
      {:ok, _} = connect_hetzner(team)
      program_hetzner_catalog()

      conn = call(:get, "/v1/providers/hetzner/catalog", nil, session_token(user))
      assert conn.status == 200
      body = json_body(conn)

      assert body["regions"] == [%{"slug" => "hel1", "name" => "Helsinki"}]
      # The deprecated cax11 is dropped; cax21 carries the threaded price.
      assert [st] = body["server_types"]

      assert st == %{
               "slug" => "cax21",
               "cores" => 4,
               "ram_gb" => 8.0,
               "disk_gb" => 80,
               "monthly_price" => 6.49
             }
    end

    test "azure → the identical normalized shape (over the Fake client)" do
      {user, team} = user_with_team()
      {:ok, _} = connect_azure(team)

      conn = call(:get, "/v1/providers/azure/catalog", nil, session_token(user))
      assert conn.status == 200
      body = json_body(conn)

      assert is_list(body["regions"]) and body["regions"] != []
      assert is_list(body["server_types"]) and body["server_types"] != []
      assert Enum.all?(body["server_types"], &(Enum.sort(Map.keys(&1)) == @server_type_keys))
    end

    test "both kinds' catalogs share the EXACT same shape" do
      {user, team} = user_with_team()
      {:ok, _} = connect_hetzner(team)
      {:ok, _} = connect_azure(team)
      program_hetzner_catalog()

      hz = json_body(call(:get, "/v1/providers/hetzner/catalog", nil, session_token(user)))
      az = json_body(call(:get, "/v1/providers/azure/catalog", nil, session_token(user)))

      assert Map.keys(hz) |> Enum.sort() == ["regions", "server_types"]
      assert Map.keys(az) |> Enum.sort() == ["regions", "server_types"]

      for body <- [hz, az], st <- body["server_types"] do
        assert Enum.sort(Map.keys(st)) == @server_type_keys
      end
    end

    test "an unknown kind → 404 unknown_kind" do
      {user, _team} = user_with_team()
      conn = call(:get, "/v1/providers/aws/catalog", nil, session_token(user))
      assert conn.status == 404
      assert json_body(conn) == %{"error" => "unknown_kind"}
    end

    test "no connected provider of that kind → 404 no_provider (connect-first)" do
      {user, _team} = user_with_team()
      conn = call(:get, "/v1/providers/azure/catalog", nil, session_token(user))
      assert conn.status == 404
      assert json_body(conn) == %{"error" => "no_provider"}
    end

    test "no auth → 401" do
      conn = call(:get, "/v1/providers/hetzner/catalog")
      assert conn.status == 401
    end
  end

  describe "GET /v1/providers/:kind/overview — menu + provider header" do
    test "wraps the normalized menu with the provider header" do
      {user, team} = user_with_team()
      {:ok, _} = connect_azure(team)

      conn = call(:get, "/v1/providers/azure/overview", nil, session_token(user))
      assert conn.status == 200
      body = json_body(conn)

      assert body["provider"] == %{"kind" => "azure", "label" => "az"}
      assert is_list(body["regions"])
      assert Enum.all?(body["server_types"], &(Enum.sort(Map.keys(&1)) == @server_type_keys))
    end
  end

  describe "the existing /v1/hetzner/* routes still work (different concern)" do
    test "/v1/hetzner/catalog still serves the action catalog (resource/verb/tier/params)" do
      {user, _team} = user_with_team()

      conn = call(:get, "/v1/hetzner/catalog", nil, session_token(user))
      assert conn.status == 200
      %{"catalog" => entries} = json_body(conn)
      assert entries != []
      # Untouched shape — NOT the normalized {regions, server_types}.
      assert Enum.all?(entries, &(Enum.sort(Map.keys(&1)) == ~w(params resource tier verb)))
    end
  end

  describe "POST /v1/providers — verify-before-save" do
    test "azure creds that don't authenticate are NOT saved; remediation is returned" do
      {user, team} = user_with_team()

      body = %{
        kind: "azure",
        credentials: azure_blob(%{"client_secret" => FakeClient.unauthorized_secret()}),
        label: "bad"
      }

      conn = call(:post, "/v1/providers", body, session_token(user))
      assert conn.status == 422
      assert json_body(conn)["error"] == "provider_unverified"
      assert json_body(conn)["remediation"] == FailureCopy.connect_remediation("azure")

      # Nothing persisted — the dead credential never lands.
      assert Registry.list_providers(team) == []
    end

    test "azure creds that authenticate ARE saved (201), credential never echoed" do
      {user, team} = user_with_team()

      body = %{kind: "azure", credentials: azure_blob(), label: "prod-azure"}
      conn = call(:post, "/v1/providers", body, session_token(user))

      assert conn.status == 201
      assert json_body(conn)["provider"]["kind"] == "azure"
      refute conn.resp_body =~ "good-secret"
      assert [%{kind: "azure"}] = Registry.list_providers(team)
    end

    test "a hetzner token the provider rejects (401) is NOT saved; hetzner remediation returned" do
      {user, team} = user_with_team()
      # The preflight one-row list gets a 401 → can't verify.
      HetznerFakeHttpClient.program(%{"/v1/servers" => {:ok, %{status: 401, body: "{}"}}})

      conn = call(:post, "/v1/providers", %{kind: "hetzner", token: "bad"}, session_token(user))
      assert conn.status == 422
      assert json_body(conn)["error"] == "provider_unverified"
      assert json_body(conn)["remediation"] == FailureCopy.connect_remediation("hetzner")
      assert Registry.list_providers(team) == []
    end

    test "a hetzner token the provider accepts (200) IS saved (201)" do
      {user, team} = user_with_team()
      HetznerFakeHttpClient.program(%{"/v1/servers" => {:ok, %{status: 200, body: "{}"}}})

      conn = call(:post, "/v1/providers", %{kind: "hetzner", token: "good"}, session_token(user))
      assert conn.status == 201
      assert [%{kind: "hetzner"}] = Registry.list_providers(team)
    end

    test "azure with a missing credential field → 422 invalid (bad_credentials before verify)" do
      {user, _team} = user_with_team()
      # credentials not a map → bad_credentials
      conn = call(:post, "/v1/providers", %{kind: "azure", token: "x"}, session_token(user))
      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid"
    end

    test "azure with a NESTED-object credential field → clean 422, never a 500 crash" do
      {user, team} = user_with_team()
      # A malformed body where a field is a JSON object, not a string. This must
      # NOT crash (to_string/1 has no impl for maps) — it is coerced to blank and
      # fails the preflight with a clean remediation.
      body = %{kind: "azure", credentials: azure_blob(%{"tenant_id" => %{"nested" => 1}})}
      conn = call(:post, "/v1/providers", body, session_token(user))
      assert conn.status == 422
      assert Registry.list_providers(team) == []
    end
  end
end
