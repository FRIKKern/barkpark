defmodule BarkparkCloud.Push.FCMAdapterTest do
  @moduledoc """
  The REAL FCM HTTP v1 adapter, run end-to-end with only the SOCKET faked. Both
  hops execute for real: the RS256 service-account assertion and its OAuth2
  exchange, then the `messages:send` call with the returned bearer.

  The legs worth naming:

    * the access token is CACHED — without it a fan-out of N devices makes 2N
      calls and leans on Google's token quota for nothing;
    * `data` is `map<string,string>` on FCM's side and a non-string value is a
      400 `INVALID_ARGUMENT`, so the adapter stringifies structurally rather
      than relying on the D59h payload happening to be all strings;
    * 404 / `INVALID_ARGUMENT` / `SENDER_ID_MISMATCH` are the three "this
      address is dead" verdicts that revoke the row; a 401 is NOT one of them —
      it drops the cached bearer and retries.

  `async: false`: application env + a process-global token cache.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Push
  alias BarkparkCloud.Push.Adapters.FCM
  alias BarkparkCloud.Push.DevicePushToken
  alias BarkparkCloud.Push.TokenCache
  alias BarkparkCloud.PushFakeHttpClient

  @device %DevicePushToken{
    id: "22222222-2222-2222-2222-222222222222",
    platform: "fcm",
    token: "fcm-device-token-xyz"
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

  defp service_account_json do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    Jason.encode!(%{
      "type" => "service_account",
      "project_id" => "barkpark-mobile",
      "client_email" => "push@barkpark-mobile.iam.gserviceaccount.com",
      "private_key" => pem,
      "token_uri" => "https://oauth2.googleapis.com/token"
    })
  end

  defp configure(json \\ nil) do
    Application.put_env(:barkpark_cloud, FCM,
      service_account_json: json || service_account_json()
    )
  end

  defp oauth_ok(expires_in \\ 3599) do
    {:ok,
     %{
       status: 200,
       headers: [],
       body: Jason.encode!(%{"access_token" => "ya29.FAKE", "expires_in" => expires_in})
     }}
  end

  defp send_ok do
    {:ok,
     %{
       status: 200,
       headers: [],
       body: Jason.encode!(%{"name" => "projects/barkpark-mobile/messages/0:1"})
     }}
  end

  defp send_refusal(status, google_status) do
    body =
      if google_status,
        do: Jason.encode!(%{"error" => %{"status" => google_status, "code" => status}}),
        else: "{}"

    {:ok, %{status: status, headers: [], body: body}}
  end

  setup do
    TokenCache.reset()
    PushFakeHttpClient.reset()

    on_exit(fn ->
      Application.delete_env(:barkpark_cloud, FCM)
      TokenCache.reset()
    end)

    :ok
  end

  describe "credential gate" do
    test "with no service-account key it is not selectable and every send cancels" do
      Application.delete_env(:barkpark_cloud, FCM)

      refute FCM.configured?()
      assert FCM.send_push(@device, @notification) == {:error, :not_configured}
      assert PushFakeHttpClient.requests() == []
    end

    test "a MALFORMED service-account JSON is not-configured, never a crash" do
      Application.put_env(:barkpark_cloud, FCM, service_account_json: "{not json")
      refute FCM.configured?()
      assert FCM.send_push(@device, @notification) == {:error, :not_configured}
    end

    test "a JSON missing project_id/client_email/private_key is not-configured" do
      Application.put_env(:barkpark_cloud, FCM,
        service_account_json: Jason.encode!(%{"project_id" => "p"})
      )

      refute FCM.configured?()
    end

    test "Push.adapter_for/1 selects FCM only once credentials exist" do
      previous = Application.get_env(:barkpark_cloud, :push_adapter)
      Application.put_env(:barkpark_cloud, :push_adapter, :auto)
      on_exit(fn -> Application.put_env(:barkpark_cloud, :push_adapter, previous) end)

      Application.delete_env(:barkpark_cloud, FCM)
      assert Push.adapter_for("fcm") == BarkparkCloud.Push.Adapters.NotConfigured
      refute Push.credential_status()["fcm"]

      configure()
      assert Push.adapter_for("fcm") == FCM
      assert Push.credential_status()["fcm"]
    end
  end

  describe "the two hops" do
    setup do
      configure()
      :ok
    end

    test "exchanges an RS256 assertion for a bearer, then posts messages:send" do
      PushFakeHttpClient.program([oauth_ok(), send_ok()])

      assert {:ok, "projects/barkpark-mobile/messages/0:1"} =
               FCM.send_push(@device, @notification)

      assert [token_request, send_request] = PushFakeHttpClient.requests()

      assert token_request.url == "https://oauth2.googleapis.com/token"
      assert {"content-type", "application/x-www-form-urlencoded"} in token_request.headers
      form = URI.decode_query(token_request.body)
      assert form["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
      assert [_h, _c, _s] = String.split(form["assertion"], ".")

      assert send_request.url ==
               "https://fcm.googleapis.com/v1/projects/barkpark-mobile/messages:send"

      assert {"authorization", "Bearer ya29.FAKE"} in send_request.headers

      message = Jason.decode!(send_request.body)["message"]
      assert message["token"] == @device.token

      assert message["notification"] == %{
               "title" => @notification["title"],
               "body" => @notification["body"]
             }

      assert message["android"]["priority"] == "HIGH"
      assert message["android"]["collapse_key"] == "sess-42"
    end

    test "data carries the D59h fields PLUS the deep link, all as strings" do
      PushFakeHttpClient.program([oauth_ok(), send_ok()])
      assert {:ok, _} = FCM.send_push(@device, @notification)

      [_token_request, send_request] = PushFakeHttpClient.requests()
      data = Jason.decode!(send_request.body)["message"]["data"]

      assert data["deep_link"] == @notification["deep_link"]
      assert data["session_id"] == "sess-42"
      assert data["blocked_since"] == "2026-07-25T09:00:00Z"
      # map<string,string> is FCM's contract; a non-string value is a 400.
      assert Enum.all?(Map.values(data), &is_binary/1)
    end

    test "a non-string data value is stringified rather than 400ing at Google" do
      PushFakeHttpClient.program([oauth_ok(), send_ok()])

      notification = put_in(@notification, ["data", "blocked_since"], 1_700_000_000)
      assert {:ok, _} = FCM.send_push(@device, notification)

      [_token_request, send_request] = PushFakeHttpClient.requests()
      data = Jason.decode!(send_request.body)["message"]["data"]
      assert data["blocked_since"] == "1700000000"
    end

    test "the access token is CACHED — a second send makes ONE call, not two" do
      PushFakeHttpClient.program([oauth_ok(), send_ok(), send_ok()])

      assert {:ok, _} = FCM.send_push(@device, @notification)
      assert {:ok, _} = FCM.send_push(@device, @notification)

      urls = PushFakeHttpClient.requests() |> Enum.map(& &1.url)
      assert Enum.count(urls, &(&1 == "https://oauth2.googleapis.com/token")) == 1
      assert Enum.count(urls, &String.contains?(&1, "messages:send")) == 2
    end

    test "a refused token exchange is an error, and no send is attempted" do
      PushFakeHttpClient.program([
        {:ok, %{status: 400, headers: [], body: ~s({"error":"invalid_grant"})}}
      ])

      assert {:error, {:fcm_token_exchange, 400}} = FCM.send_push(@device, @notification)
      assert [_only_the_token_request] = PushFakeHttpClient.requests()
    end
  end

  describe "verdict mapping" do
    setup do
      configure()
      :ok
    end

    test "404 UNREGISTERED → :unregistered (the worker REVOKES the row)" do
      PushFakeHttpClient.program([oauth_ok(), send_refusal(404, "NOT_FOUND")])
      assert FCM.send_push(@device, @notification) == {:error, :unregistered}
    end

    test "400 INVALID_ARGUMENT → :invalid_token" do
      PushFakeHttpClient.program([oauth_ok(), send_refusal(400, "INVALID_ARGUMENT")])
      assert FCM.send_push(@device, @notification) == {:error, :invalid_token}
    end

    test "403 SENDER_ID_MISMATCH → :invalid_token (the token belongs to another sender)" do
      PushFakeHttpClient.program([oauth_ok(), send_refusal(403, "SENDER_ID_MISMATCH")])
      assert FCM.send_push(@device, @notification) == {:error, :invalid_token}
    end

    test "401 drops the cached bearer so the RETRY re-exchanges, and does NOT revoke" do
      PushFakeHttpClient.program([oauth_ok(), send_refusal(401, "UNAUTHENTICATED")])

      assert {:error, {:fcm, 401, "UNAUTHENTICATED"}} = FCM.send_push(@device, @notification)
      assert TokenCache.fetch(:fcm) == :miss
    end

    test "429 and 503 are retryable errors, never a device revocation" do
      PushFakeHttpClient.program([oauth_ok(), send_refusal(429, "QUOTA_EXCEEDED")])
      assert {:error, {:fcm, 429, "QUOTA_EXCEEDED"}} = FCM.send_push(@device, @notification)

      PushFakeHttpClient.program([send_refusal(503, "UNAVAILABLE")])
      assert {:error, {:fcm, 503, "UNAVAILABLE"}} = FCM.send_push(@device, @notification)
    end

    test "a transport failure on the send hop is an error tuple, never a fake success" do
      PushFakeHttpClient.program([oauth_ok(), {:error, :closed}])
      assert FCM.send_push(@device, @notification) == {:error, {:transport, :closed}}
    end
  end
end
