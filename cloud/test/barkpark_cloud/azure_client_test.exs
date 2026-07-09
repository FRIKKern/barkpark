defmodule BarkparkCloud.AzureClientTest do
  @moduledoc """
  The Azure client seam, both concretes — no network in any test:

    * `FakeClient` (dev/test default): the reject sentinel fails `:unauthorized`,
      a well-formed blob verifies + lists the canned estate, a short blob fails
      `:invalid_credentials`.
    * `RealClient` PURE request builders (HUMAN-LAST — the only assertion the
      real Azure request shapes ever get before a human points them at a tenant):
      the OAuth2 client-credentials token exchange + the tagged ARM resource /
      locations / SKU list URLs, verbs, headers and api-versions. `request/1` is
      never called (no `http_client` configured in test) so nothing reaches
      `management.azure.com`.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Azure.{FakeClient, RealClient}

  defp blob(overrides \\ %{}) do
    %{
      "tenant_id" => "tenant-abc",
      "client_id" => "client-xyz",
      "client_secret" => "s3cr3t",
      "subscription_id" => "sub-123"
    }
    |> Map.merge(overrides)
  end

  describe "FakeClient" do
    test "a well-formed blob verifies and echoes the subscription" do
      assert {:ok, %{subscription_id: "sub-123", resource_count: 1}} =
               FakeClient.verify(blob())
    end

    test "the reject sentinel always fails :unauthorized" do
      creds = blob(%{"client_secret" => FakeClient.unauthorized_secret()})
      assert {:error, :unauthorized} = FakeClient.verify(creds)
    end

    test "a blob missing a field fails :invalid_credentials" do
      assert {:error, :invalid_credentials} =
               FakeClient.verify(Map.delete(blob(), "tenant_id"))

      assert {:error, :invalid_credentials} = FakeClient.verify(%{})
      assert {:error, :invalid_credentials} = FakeClient.verify("not-a-map")
    end

    test "list_catalog gates on verify, then returns the canned estate" do
      assert {:ok, %{locations: locs, vm_sizes: sizes}} = FakeClient.list_catalog(blob())
      assert length(locs) == 2
      assert length(sizes) == 3

      assert {:error, :unauthorized} =
               FakeClient.list_catalog(
                 blob(%{"client_secret" => FakeClient.unauthorized_secret()})
               )
    end
  end

  describe "RealClient pure request builders (no network)" do
    test "token_request builds the client-credentials OAuth2 exchange" do
      req = RealClient.token_request(blob())

      assert req.method == :post
      assert req.url == "https://login.microsoftonline.com/tenant-abc/oauth2/v2.0/token"
      assert {"Content-Type", "application/x-www-form-urlencoded"} in req.headers

      params = URI.decode_query(req.body)
      assert params["grant_type"] == "client_credentials"
      assert params["client_id"] == "client-xyz"
      assert params["client_secret"] == "s3cr3t"
      assert params["scope"] == "https://management.azure.com/.default"
    end

    test "token_request returns nil for a blob missing the exchange fields" do
      assert RealClient.token_request(%{"tenant_id" => "t"}) == nil
      assert RealClient.token_request(%{}) == nil
    end

    test "resource_groups_request is a bearer GET scoped to the subscription (top 1)" do
      req = RealClient.resource_groups_request("sub-123", "tok")

      assert req.method == :get
      assert req.url =~ "https://management.azure.com/subscriptions/sub-123/resourcegroups"
      assert req.url =~ "api-version="
      assert req.url =~ "$top=1"
      assert {"Authorization", "Bearer tok"} in req.headers
      assert {"Accept", "application/json"} in req.headers
    end

    test "locations_request is a bearer GET on the subscription's locations" do
      req = RealClient.locations_request("sub-123", "tok")

      assert req.method == :get
      assert req.url =~ "https://management.azure.com/subscriptions/sub-123/locations"
      assert req.url =~ "api-version="
      assert {"Authorization", "Bearer tok"} in req.headers
    end

    test "vm_sizes_request lists Microsoft.Compute SKUs for the subscription" do
      req = RealClient.vm_sizes_request("sub-123", "tok")

      assert req.method == :get
      assert req.url =~ "/subscriptions/sub-123/providers/Microsoft.Compute/skus"
      assert req.url =~ "api-version="
      assert {"Authorization", "Bearer tok"} in req.headers
    end

    test "with no http_client configured, verify/list_catalog fail closed — never reach Azure" do
      # config/test.exs selects the FakeClient as the seam default and configures
      # no RealClient http_client, so a callback that would hit the wire returns
      # :http_client_not_configured rather than silently calling management.azure.com.
      assert {:error, :http_client_not_configured} = RealClient.verify(blob())
      assert {:error, :http_client_not_configured} = RealClient.list_catalog(blob())
    end

    test "a malformed blob is rejected before any transport attempt" do
      assert {:error, :invalid_credentials} = RealClient.verify(%{})
      assert {:error, :invalid_credentials} = RealClient.list_catalog("nope")
    end
  end
end
