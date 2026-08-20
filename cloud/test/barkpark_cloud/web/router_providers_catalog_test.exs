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
      # Hetzner quotes in EUR — the neutral shape carries it so a side-by-side
      # with Azure (USD) is honest.
      assert body["currency"] == "EUR"
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
      # Azure Retail prices are quoted in USD.
      assert body["currency"] == "USD"
      assert Enum.all?(body["server_types"], &(Enum.sort(Map.keys(&1)) == @server_type_keys))
    end

    test "both kinds' catalogs share the EXACT same shape" do
      {user, team} = user_with_team()
      {:ok, _} = connect_hetzner(team)
      {:ok, _} = connect_azure(team)
      program_hetzner_catalog()

      hz = json_body(call(:get, "/v1/providers/hetzner/catalog", nil, session_token(user)))
      az = json_body(call(:get, "/v1/providers/azure/catalog", nil, session_token(user)))

      assert Map.keys(hz) |> Enum.sort() == ["currency", "regions", "server_types"]
      assert Map.keys(az) |> Enum.sort() == ["currency", "regions", "server_types"]

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

      assert %{"kind" => "azure", "label" => "az", "identity" => _} = body["provider"]
      assert is_list(body["regions"])
      assert Enum.all?(body["server_types"], &(Enum.sort(Map.keys(&1)) == @server_type_keys))
    end

    # cch wave 13 — the header names WHICH cloud account the connection points
    # at, so a person reads it BEFORE committing a credential rotation.
    test "azure header echoes the STORED subscription id, marked as stored (never 'verified')" do
      {user, team} = user_with_team()
      {:ok, _} = connect_azure(team)

      body = json_body(call(:get, "/v1/providers/azure/overview", nil, session_token(user)))

      assert body["provider"]["identity"] == %{
               "label" => "Subscription",
               "value" => azure_blob()["subscription_id"],
               "source" => "stored",
               "reason" => nil
             }

      # Provenance, not a verdict: nothing here may read as a server-confirmed
      # account. Azure.verify/1 echoes back the id it was handed.
      refute conn_body_contains?(body, "verified")
    end

    test "hetzner header states the absence out loud — an unknown identity is NEVER a blank" do
      {user, team} = user_with_team()
      {:ok, _} = connect_hetzner(team)
      program_hetzner_catalog()

      body = json_body(call(:get, "/v1/providers/hetzner/overview", nil, session_token(user)))

      # The key is always present, the value is explicitly nil, and the reason
      # is the honest one: hetzner_token_ok?/1 matches on status class alone and
      # nothing in the tree fetches a Hetzner account/project identifier.
      assert body["provider"]["identity"] == %{
               "label" => "Project",
               "value" => nil,
               "source" => "unavailable",
               "reason" => "Hetzner doesn't report which project this token belongs to."
             }
    end

    test "a plain MEMBER (no admin, no operator) reads the identity — Auth.require_user only" do
      {_owner, team} = user_with_team()
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      {:ok, _} = connect_azure(team)

      conn = call(:get, "/v1/providers/azure/overview", nil, session_token(member))
      assert conn.status == 200
      assert json_body(conn)["provider"]["identity"]["value"] == azure_blob()["subscription_id"]
    end

    test "the plain catalog route is UNCHANGED — identity rides the overview header only" do
      {user, team} = user_with_team()
      {:ok, _} = connect_azure(team)

      body = json_body(call(:get, "/v1/providers/azure/catalog", nil, session_token(user)))
      assert Enum.sort(Map.keys(body)) == ["currency", "regions", "server_types"]
    end
  end

  # Does any string anywhere in the decoded body carry `needle`? Used to pin the
  # copy NEGATIVE (the identity must never read as a verification).
  defp conn_body_contains?(value, needle) when is_map(value),
    do:
      Enum.any?(value, fn {k, v} ->
        conn_body_contains?(k, needle) or conn_body_contains?(v, needle)
      end)

  defp conn_body_contains?(value, needle) when is_list(value),
    do: Enum.any?(value, &conn_body_contains?(&1, needle))

  defp conn_body_contains?(value, needle) when is_binary(value),
    do: String.contains?(String.downcase(value), needle)

  defp conn_body_contains?(_value, _needle), do: false

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

  describe "POST /v1/providers — cloudflare connect (@connectable_kinds gate, D53)" do
    test "a Fake-active cloudflare token is saved (201), credential never echoed" do
      {user, team} = user_with_team()

      body = %{kind: "cloudflare", token: "cf-live-token", label: "edge"}
      conn = call(:post, "/v1/providers", body, session_token(user))

      assert conn.status == 201
      assert json_body(conn)["provider"]["kind"] == "cloudflare"
      # The plaintext token is encrypted at rest — never round-tripped.
      refute conn.resp_body =~ "cf-live-token"
      assert [%{kind: "cloudflare"}] = Registry.list_providers(team)
    end

    test "a `fail-` sentinel token is rejected at preflight (422 provider_unverified), nothing saved" do
      {user, team} = user_with_team()

      body = %{kind: "cloudflare", token: "fail-bad-token"}
      conn = call(:post, "/v1/providers", body, session_token(user))

      assert conn.status == 422
      assert json_body(conn)["error"] == "provider_unverified"
      assert json_body(conn)["remediation"] == FailureCopy.connect_remediation("cloudflare")
      # The dead credential never lands.
      assert Registry.list_providers(team) == []
    end

    test "a {api_token, account_id, zone_id} JSON blob is accepted, verified via api_token" do
      {user, team} = user_with_team()

      body = %{
        kind: "cloudflare",
        credentials: %{
          "api_token" => "cf-blob-token",
          "account_id" => "acct_1",
          "zone_id" => "zone_1"
        }
      }

      conn = call(:post, "/v1/providers", body, session_token(user))

      assert conn.status == 201
      refute conn.resp_body =~ "cf-blob-token"
      assert [%{kind: "cloudflare"}] = Registry.list_providers(team)
    end

    test "a blob whose api_token is a `fail-` sentinel is rejected at preflight" do
      {user, team} = user_with_team()

      body = %{kind: "cloudflare", credentials: %{"api_token" => "fail-blob-token"}}
      conn = call(:post, "/v1/providers", body, session_token(user))

      assert conn.status == 422
      assert json_body(conn)["error"] == "provider_unverified"
      assert Registry.list_providers(team) == []
    end

    test "connect uses @connectable_kinds SEPARATELY: cloudflare connects, but its catalog is NOT exposed" do
      {user, team} = user_with_team()
      # cloudflare IS connectable…
      {:ok, _} = Registry.connect_provider(team, "cloudflare", "cf-token", label: "edge")

      # …yet GET /v1/providers/cloudflare/catalog stays 404 unknown_kind — proving
      # cloudflare is NOT in @neutral_kinds (the catalog gate) even though it is in
      # @connectable_kinds (the connect gate). No backing-less menu route leaks.
      conn = call(:get, "/v1/providers/cloudflare/catalog", nil, session_token(user))
      assert conn.status == 404
      assert json_body(conn) == %{"error" => "unknown_kind"}
    end
  end

  describe "DELETE /v1/providers/:kind — disconnect (degrade to standalone, D54)" do
    test "disconnects a connected cloudflare provider (200 ok), row dropped, audited kind+label only" do
      {user, team} = user_with_team()
      {:ok, _} = Registry.connect_provider(team, "cloudflare", "cf-secret-token", label: "edge")

      conn = call(:delete, "/v1/providers/cloudflare", nil, session_token(user))

      assert conn.status == 200
      assert json_body(conn) == %{"ok" => true}
      # The connection (and its encrypted credential) is gone → standalone.
      assert Registry.list_providers(team) == []

      # An audit event was recorded carrying ONLY {kind, label} — never the token.
      assert [event] = Accounts.list_audit_events(team, target_type: "provider")
      assert event.action == "provider.disconnected"
      assert event.metadata["kind"] == "cloudflare"
      assert event.metadata["label"] == "edge"
      refute Jason.encode!(event.metadata) =~ "cf-secret-token"
    end

    test "404 not_found when no provider of that kind is connected (no existence leak)" do
      {user, team} = user_with_team()

      conn = call(:delete, "/v1/providers/cloudflare", nil, session_token(user))

      assert conn.status == 404
      assert json_body(conn) == %{"error" => "not_found"}
      # Nothing was audited for a no-op disconnect.
      assert Accounts.list_audit_events(team, target_type: "provider") == []
    end

    test "disconnect is kind-scoped: removing cloudflare leaves a connected hetzner intact" do
      {user, team} = user_with_team()
      {:ok, _} = connect_hetzner(team)
      {:ok, _} = Registry.connect_provider(team, "cloudflare", "cf-token", label: "edge")

      conn = call(:delete, "/v1/providers/cloudflare", nil, session_token(user))
      assert conn.status == 200
      assert [%{kind: "hetzner"}] = Registry.list_providers(team)
    end

    test "no auth → 401" do
      conn = call(:delete, "/v1/providers/cloudflare")
      assert conn.status == 401
    end
  end
end
