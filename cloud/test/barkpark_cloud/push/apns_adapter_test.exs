defmodule BarkparkCloud.Push.APNSAdapterTest do
  @moduledoc """
  The REAL APNs adapter, run end-to-end with only the SOCKET faked
  (`:push_http_client` → `PushFakeHttpClient`). Everything the adapter actually
  decides executes for real: the ES256 provider token, the
  `/3/device/<token>` URL, the header set (`apns-topic`, `apns-push-type`,
  `apns-priority`, `apns-collapse-id`), the `aps` payload shape, and the
  status → `Push.Adapter` verdict mapping.

  Faking `Push.Adapter` here instead would have asserted nothing but the stub.

  `async: false`: these tests set application env (credentials, adapter
  selection) and the provider-token cache is process-global.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Push
  alias BarkparkCloud.Push.Adapters.APNS
  alias BarkparkCloud.Push.DevicePushToken
  alias BarkparkCloud.Push.TokenCache
  alias BarkparkCloud.PushFakeHttpClient

  @device %DevicePushToken{
    id: "11111111-1111-1111-1111-111111111111",
    platform: "apns",
    token: "aaaabbbbccccddddeeeeffff00001111"
  }

  @notification %{
    "title" => "Barkpark needs you",
    "body" => "A chat session is waiting on your answer",
    "deep_link" => "barkpark://sessions/sess-42?workspace_id=ws-1",
    "data" => %{
      "session_id" => "sess-42",
      "title" => "Deploy the thing",
      "workspace_id" => "ws-1",
      "blocked_since" => "2026-07-25T09:00:00Z",
      "ask_role" => "approval"
    }
  }

  defp ec_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
  end

  defp configure(overrides \\ []) do
    base = [
      key_p8: ec_pem(),
      key_id: "KEYID12345",
      team_id: "TEAM123456",
      topic: "cloud.barkpark.mobile",
      env: "sandbox"
    ]

    Application.put_env(:barkpark_cloud, APNS, Keyword.merge(base, overrides))
  end

  defp header(request, name) do
    Enum.find_value(request.headers, fn {k, v} -> if k == name, do: v end)
  end

  # Program a single canned APNs refusal: status + the `reason` string Apple
  # puts in the JSON body.
  defp respond(status, reason) do
    body = if reason, do: Jason.encode!(%{"reason" => reason}), else: ""
    PushFakeHttpClient.program(fn _ -> {:ok, %{status: status, headers: [], body: body}} end)
  end

  setup do
    TokenCache.reset()
    PushFakeHttpClient.reset()

    on_exit(fn ->
      Application.delete_env(:barkpark_cloud, APNS)
      TokenCache.reset()
    end)

    :ok
  end

  describe "credential gate" do
    test "with NO credentials configured it is not selectable and every send cancels" do
      Application.delete_env(:barkpark_cloud, APNS)

      refute APNS.configured?()
      assert APNS.send_push(@device, @notification) == {:error, :not_configured}
      # …and nothing was ever put on the wire.
      assert PushFakeHttpClient.requests() == []
    end

    test "a PARTIAL credential set is still not configured (no half-open state)" do
      configure(topic: nil)
      refute APNS.configured?()
      assert APNS.send_push(@device, @notification) == {:error, :not_configured}
    end

    test "Push.adapter_for/1 selects APNS only once credentials exist" do
      previous = Application.get_env(:barkpark_cloud, :push_adapter)
      Application.put_env(:barkpark_cloud, :push_adapter, :auto)
      on_exit(fn -> Application.put_env(:barkpark_cloud, :push_adapter, previous) end)

      Application.delete_env(:barkpark_cloud, APNS)
      assert Push.adapter_for("apns") == BarkparkCloud.Push.Adapters.NotConfigured
      refute Push.credential_status()["apns"]

      configure()
      assert Push.adapter_for("apns") == APNS
      assert Push.credential_status()["apns"]
    end
  end

  describe "the wire" do
    test "a 200 is {:ok, apns-id} and the request is a well-formed APNs POST" do
      configure()

      PushFakeHttpClient.program(fn _req ->
        {:ok, %{status: 200, headers: [{"apns-id", "8A6C-ID"}], body: ""}}
      end)

      assert {:ok, "8A6C-ID"} = APNS.send_push(@device, @notification)

      assert [request] = PushFakeHttpClient.requests()
      assert request.method == :post
      assert request.url == "https://api.sandbox.push.apple.com/3/device/#{@device.token}"
      # APNs is HTTP/2-only; a transport that negotiated HTTP/1.1 could never
      # deliver, so the pin is part of the contract, not a preference.
      assert request.protocols == [:http2]

      assert header(request, "apns-topic") == "cloud.barkpark.mobile"
      assert header(request, "apns-push-type") == "alert"
      assert header(request, "apns-priority") == "10"
      # The collapse id is the SESSION: a re-block replaces its own banner
      # rather than stacking stale pointers to live state.
      assert header(request, "apns-collapse-id") == "sess-42"
      assert "bearer " <> jwt = header(request, "authorization")
      assert [_h, _c, _s] = String.split(jwt, ".")

      body = Jason.decode!(request.body)

      assert body["aps"]["alert"] == %{
               "title" => "Barkpark needs you",
               "body" => @notification["body"]
             }

      assert body["deep_link"] == @notification["deep_link"]
      assert body["data"] == @notification["data"]
    end

    test "env: production switches host, and nothing else" do
      configure(env: "production")
      PushFakeHttpClient.program(fn _ -> {:ok, %{status: 200, headers: [], body: ""}} end)

      assert {:ok, _} = APNS.send_push(@device, @notification)
      assert [request] = PushFakeHttpClient.requests()
      assert request.url =~ "https://api.push.apple.com/3/device/"
    end

    test "the provider token is CACHED across sends (Apple rejects >1 refresh/20min)" do
      configure()
      PushFakeHttpClient.program(fn _ -> {:ok, %{status: 200, headers: [], body: ""}} end)

      assert {:ok, _} = APNS.send_push(@device, @notification)
      assert {:ok, _} = APNS.send_push(@device, @notification)

      assert [first, second] = PushFakeHttpClient.requests()
      assert header(first, "authorization") == header(second, "authorization")
    end
  end

  describe "verdict mapping" do
    setup do
      configure()
      :ok
    end

    test "410 Unregistered → :unregistered (the worker REVOKES the row)" do
      respond(410, "Unregistered")
      assert APNS.send_push(@device, @notification) == {:error, :unregistered}
    end

    test "400 BadDeviceToken → :invalid_token (terminal)" do
      respond(400, "BadDeviceToken")
      assert APNS.send_push(@device, @notification) == {:error, :invalid_token}
    end

    test "400 DeviceTokenNotForTopic → :invalid_token" do
      respond(400, "DeviceTokenNotForTopic")
      assert APNS.send_push(@device, @notification) == {:error, :invalid_token}
    end

    test "403 ExpiredProviderToken drops the cached JWT so the RETRY signs a fresh one" do
      respond(403, "ExpiredProviderToken")
      assert {:error, :expired_provider_token} = APNS.send_push(@device, @notification)
      assert TokenCache.fetch(:apns) == :miss
    end

    test "403 InvalidProviderToken is RETRYABLE, not terminal — an operator typo must not revoke devices" do
      respond(403, "InvalidProviderToken")

      assert {:error, {:apns, 403, "InvalidProviderToken"}} =
               APNS.send_push(@device, @notification)
    end

    test "429 and 5xx are retryable errors, never a device revocation" do
      respond(429, "TooManyRequests")
      assert {:error, {:apns, 429, "TooManyRequests"}} = APNS.send_push(@device, @notification)

      respond(503, nil)
      assert {:error, {:apns, 503, nil}} = APNS.send_push(@device, @notification)
    end

    test "a transport failure is an error tuple, never a raise or a fake success" do
      PushFakeHttpClient.program(fn _ -> {:error, :timeout} end)
      assert APNS.send_push(@device, @notification) == {:error, {:transport, :timeout}}
    end
  end
end
