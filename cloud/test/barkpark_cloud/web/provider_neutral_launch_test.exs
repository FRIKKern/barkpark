defmodule BarkparkCloud.Web.ProviderNeutralLaunchTest do
  @moduledoc """
  W2/S6 — provider/region/size/creds threaded launch → claim (charter Decision 9).

  Covers the Elixir half of Azure go-live:

    * POST /v1/launch persists {provider, region, server_type} and surfaces
      `provider` in the barkpark JSON (the SPA fleet chip);
    * provider=azure without a verified azure providers row → 422
      provider_not_connected + remediation (fail at the button, not in the job);
    * the provision-job claim threads kind + region/server_type + the DECRYPTED
      4-field azure credentials, while the HETZNER claim payload stays
      byte-identical to the pre-provider-neutral shape.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

  @azure_creds %{
    "tenant_id" => "11111111-1111-1111-1111-111111111111",
    "client_id" => "22222222-2222-2222-2222-222222222222",
    "client_secret" => "s3cr3t-value",
    "subscription_id" => "33333333-3333-3333-3333-333333333333"
  }

  defp user_with_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp token_for(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp subscribe!(team), do: {:ok, _} = Billing.subscribe(team, "supporter")

  defp connect_azure!(team) do
    {:ok, provider} =
      Registry.connect_provider(team, "azure", Jason.encode!(@azure_creds), label: "prod")

    provider
  end

  defp call(method, path, body, token) do
    conn =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp claim, do: call(:post, "/v1/internal/provision-jobs/claim", %{}, @worker_token)

  describe "POST /v1/launch — provider/region/server_type" do
    test "hetzner launch persists the launch config and surfaces provider in JSON" do
      {user, team} = user_with_team()
      subscribe!(team)

      conn =
        call(
          :post,
          "/v1/launch",
          %{provider: "hetzner", name: "My Prod", region: "hel1", server_type: "cx32"},
          token_for(user)
        )

      assert conn.status == 201
      bp = json_body(conn)["barkpark"]
      # provider is surfaced (the SPA fleet-chip dependency).
      assert bp["provider"] == "hetzner"
      assert bp["region"] == "hel1"
      assert bp["server_type"] == "cx32"

      # …and it really landed on the row.
      assert [%Barkpark{provider: "hetzner", region: "hel1", server_type: "cx32"}] =
               Registry.list_barkparks(team)
    end

    test "a provider-less launch defaults to hetzner (byte-identical to before)" do
      {user, team} = user_with_team()
      subscribe!(team)

      conn = call(:post, "/v1/launch", %{name: "Plain"}, token_for(user))
      assert conn.status == 201
      assert json_body(conn)["barkpark"]["provider"] == "hetzner"

      assert [%Barkpark{provider: "hetzner", region: nil, server_type: nil}] =
               Registry.list_barkparks(team)
    end

    test "an unknown provider → 422 invalid_provider, nothing provisioned" do
      {user, team} = user_with_team()
      subscribe!(team)

      conn = call(:post, "/v1/launch", %{provider: "gcp", name: "Nope"}, token_for(user))
      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "invalid_provider"
      assert "azure" in body["known_providers"]
      assert Registry.list_barkparks(team) == []
    end

    test "provider=azure WITHOUT a connected azure row → 422 provider_not_connected + remediation" do
      {user, team} = user_with_team()
      subscribe!(team)

      conn = call(:post, "/v1/launch", %{provider: "azure", name: "Az Box"}, token_for(user))
      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "provider_not_connected"
      assert body["provider"] == "azure"
      # Names the exact Providers → connect fix (fail at the button).
      assert body["remediation"] =~ "Providers"
      # NOTHING provisioned — no burned box, no job.
      assert Registry.list_barkparks(team) == []
    end

    test "provider=azure WITH a connected azure row → 201, provider persisted azure" do
      {user, team} = user_with_team()
      subscribe!(team)
      connect_azure!(team)

      conn =
        call(
          :post,
          "/v1/launch",
          %{provider: "azure", name: "Az Box", region: "westeurope", server_type: "Standard_B2s"},
          token_for(user)
        )

      assert conn.status == 201
      assert json_body(conn)["barkpark"]["provider"] == "azure"

      assert [%Barkpark{provider: "azure", region: "westeurope", server_type: "Standard_B2s"}] =
               Registry.list_barkparks(team)
    end
  end

  describe "provision-job claim threading" do
    test "HETZNER claim payload is byte-identical (no kind, no credentials)" do
      {user, team} = user_with_team()
      subscribe!(team)
      assert call(:post, "/v1/launch", %{name: "My Prod"}, token_for(user)).status == 201

      conn = claim()
      assert conn.status == 200
      payload = json_body(conn)

      # Region/type fall back to the warm-pool defaults for a default hetzner row.
      assert payload["region"] == Registry.default_region()
      assert payload["server_type"] == Registry.default_server_type()
      # The provider-routing keys are ABSENT for hetzner — an old worker + the
      # existing warm-pool path both read the exact same bytes as before.
      refute Map.has_key?(payload, "kind")
      refute Map.has_key?(payload, "credentials")
    end

    test "a pinned hetzner region/size rides through the claim" do
      {user, team} = user_with_team()
      subscribe!(team)

      assert call(
               :post,
               "/v1/launch",
               %{name: "Pinned", region: "fsn1", server_type: "cpx41"},
               token_for(user)
             ).status == 201

      payload = json_body(claim())
      assert payload["region"] == "fsn1"
      assert payload["server_type"] == "cpx41"
      refute Map.has_key?(payload, "kind")
    end

    test "AZURE claim threads kind + region/size + the DECRYPTED 4-field credentials" do
      {user, team} = user_with_team()
      subscribe!(team)
      connect_azure!(team)

      assert call(
               :post,
               "/v1/launch",
               %{
                 provider: "azure",
                 name: "Az Box",
                 region: "westeurope",
                 server_type: "Standard_B2s"
               },
               token_for(user)
             ).status == 201

      payload = json_body(claim())
      assert payload["kind"] == "azure"
      assert payload["region"] == "westeurope"
      assert payload["server_type"] == "Standard_B2s"
      # The decrypted 4-tuple mirrors env-at-claim — the single sanctioned crossing.
      assert payload["credentials"] == @azure_creds
    end
  end
end
