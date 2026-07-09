defmodule BarkparkCloud.Web.ResurrectRouteTest do
  @moduledoc """
  azh-w6 (S14c) — the portable-archive RESURRECT plumbing in the control plane:

    * POST /v1/resurrect creates a FRESH barkpark row (Remove deletes rows) with
      provider/region/size nil-honest (D23) + enqueues a `resurrect` job carrying
      the bundle_ref → 202 {ok, id, job_id};
    * the 4xx-at-the-button gates: blank name/bundle_ref, unknown provider, azure
      without a verified providers row (D17 remediation), and a LIVE twin name;
    * the worker's resurrect claim payload = the provision claim PLUS bundle_ref,
      and it is kind-isolated (a provision claim never grabs a resurrect job);
    * REFUTE: the resurrect job is invisible to the provision-jobs claim, and the
      resurrect claim adds ONLY bundle_ref to the provision payload.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"
  @bundle "s3://barkpark-archives/shop-2026-07-09.tar.zst"

  @azure_creds %{
    "tenant_id" => "11111111-1111-1111-1111-111111111111",
    "client_id" => "22222222-2222-2222-2222-222222222222",
    "client_secret" => "s3cr3t-value",
    "subscription_id" => "33333333-3333-3333-3333-333333333333"
  }

  defp user_with_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})
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
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp resurrect_claim,
    do: call(:post, "/v1/internal/resurrect-jobs/claim", %{}, @worker_token)

  defp provision_claim,
    do: call(:post, "/v1/internal/provision-jobs/claim", %{}, @worker_token)

  describe "POST /v1/resurrect — happy path" do
    test "creates a fresh row nil-honest + a pending resurrect job → 202 {ok,id,job_id}" do
      {user, team} = user_with_team()
      subscribe!(team)

      conn =
        call(
          :post,
          "/v1/resurrect",
          %{name: "Shop", provider: "hetzner", bundle_ref: @bundle},
          token_for(user)
        )

      assert conn.status == 202
      body = json_body(conn)
      assert body["ok"] == true
      assert is_binary(body["id"]) and body["id"] != ""
      assert is_binary(body["job_id"]) and body["job_id"] != ""

      # The fresh row landed, provider persisted, region/size nil-honest (D23).
      assert [%Barkpark{id: id, provider: "hetzner", region: nil, server_type: nil}] =
               Registry.list_barkparks(team)

      assert id == body["id"]

      # …and a pending resurrect job carrying the bundle_ref (fetched directly —
      # latest_provision_job/1 is kind:"provision"-filtered by design).
      assert %ProvisionJob{status: "pending", bundle_ref: @bundle} =
               BarkparkCloud.Repo.get_by(ProvisionJob, barkpark_id: id, kind: "resurrect")
    end

    test "region/server_type ride through when pinned" do
      {user, team} = user_with_team()
      subscribe!(team)

      assert call(
               :post,
               "/v1/resurrect",
               %{name: "Pinned", bundle_ref: @bundle, region: "hel1", server_type: "cx32"},
               token_for(user)
             ).status == 202

      assert [%Barkpark{provider: "hetzner", region: "hel1", server_type: "cx32"}] =
               Registry.list_barkparks(team)
    end

    test "azure with a verified providers row → 202" do
      {user, team} = user_with_team()
      subscribe!(team)
      connect_azure!(team)

      conn =
        call(
          :post,
          "/v1/resurrect",
          %{name: "AzShop", provider: "azure", bundle_ref: @bundle},
          token_for(user)
        )

      assert conn.status == 202
      assert [%Barkpark{provider: "azure"}] = Registry.list_barkparks(team)
    end
  end

  describe "POST /v1/resurrect — 4xx gates (nothing created)" do
    test "blank bundle_ref → 422 bundle_ref_required" do
      {user, team} = user_with_team()
      subscribe!(team)

      conn = call(:post, "/v1/resurrect", %{name: "Shop", bundle_ref: "  "}, token_for(user))
      assert conn.status == 422
      assert json_body(conn)["error"] == "bundle_ref_required"
      assert Registry.list_barkparks(team) == []
    end

    test "blank name → 422 name_required" do
      {user, team} = user_with_team()
      subscribe!(team)

      conn = call(:post, "/v1/resurrect", %{name: "", bundle_ref: @bundle}, token_for(user))
      assert conn.status == 422
      assert json_body(conn)["error"] == "name_required"
    end

    test "unknown provider → 422 invalid_provider" do
      {user, team} = user_with_team()
      subscribe!(team)

      conn =
        call(
          :post,
          "/v1/resurrect",
          %{name: "Shop", provider: "gcp", bundle_ref: @bundle},
          token_for(user)
        )

      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid_provider"
    end

    test "azure WITHOUT a verified providers row → 422 provider_not_connected + remediation" do
      {user, team} = user_with_team()
      subscribe!(team)

      conn =
        call(
          :post,
          "/v1/resurrect",
          %{name: "Shop", provider: "azure", bundle_ref: @bundle},
          token_for(user)
        )

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "provider_not_connected"
      assert body["provider"] == "azure"
      assert is_binary(body["remediation"]) and body["remediation"] != ""
      assert Registry.list_barkparks(team) == []
    end

    test "a LIVE twin name → 422 live_twin (resurrect would double it)" do
      {user, team} = user_with_team()
      subscribe!(team)

      # A live box already named "Shop".
      {:ok, _live} = Registry.register_managed_barkpark(team, "Shop", "shop", provider: "hetzner")

      conn =
        call(:post, "/v1/resurrect", %{name: "Shop", bundle_ref: @bundle}, token_for(user))

      assert conn.status == 422
      assert json_body(conn)["error"] == "live_twin"
      # No SECOND row stood up.
      assert length(Registry.list_barkparks(team)) == 1
    end

    test "an unauthenticated request → 401" do
      conn = call(:post, "/v1/resurrect", %{name: "Shop", bundle_ref: @bundle}, "not-a-token")
      assert conn.status == 401
    end

    test "a non-admin member → 403 forbidden" do
      {_owner, team} = user_with_team()
      subscribe!(team)
      n = System.unique_integer([:positive])
      {:ok, member} = Accounts.register_user(%{email: "m-#{n}@example.com", password: @password})
      {:ok, _} = Accounts.add_member(team, member, "member")

      conn =
        call(:post, "/v1/resurrect", %{name: "Shop", bundle_ref: @bundle}, token_for(member))

      # 403 (role) before any body validation.
      assert conn.status == 403
    end
  end

  describe "resurrect claim (worker pull)" do
    test "claim payload = provision claim PLUS bundle_ref; kind-isolated from provision" do
      {user, team} = user_with_team()
      subscribe!(team)

      assert call(
               :post,
               "/v1/resurrect",
               %{name: "Shop", bundle_ref: @bundle, region: "hel1", server_type: "cx32"},
               token_for(user)
             ).status == 202

      # A provision-jobs claim must NOT see the resurrect job (kind isolation).
      assert provision_claim().status == 204

      # The resurrect claim carries the archive + the full provision payload.
      conn = resurrect_claim()
      assert conn.status == 200
      payload = json_body(conn)

      assert payload["bundle_ref"] == @bundle
      # It IS the provision claim shape: name/slug/region/size + the agent token.
      assert payload["name"] == "Shop"
      assert payload["region"] == "hel1"
      assert payload["server_type"] == "cx32"
      assert is_binary(payload["job_id"]) and payload["job_id"] != ""
      assert is_binary(payload["agent_token"]) and payload["agent_token"] != ""
      # Hetzner provider → no kind/credentials routing keys, exactly like provision.
      refute Map.has_key?(payload, "kind")
      refute Map.has_key?(payload, "credentials")
    end

    test "an azure resurrect claim threads kind + decrypted creds + bundle_ref" do
      {user, team} = user_with_team()
      subscribe!(team)
      connect_azure!(team)

      assert call(
               :post,
               "/v1/resurrect",
               %{name: "AzShop", provider: "azure", bundle_ref: @bundle},
               token_for(user)
             ).status == 202

      payload = json_body(resurrect_claim())
      assert payload["kind"] == "azure"
      assert payload["credentials"] == @azure_creds
      assert payload["bundle_ref"] == @bundle
    end

    test "no pending resurrect job → 204" do
      assert resurrect_claim().status == 204
    end
  end
end
