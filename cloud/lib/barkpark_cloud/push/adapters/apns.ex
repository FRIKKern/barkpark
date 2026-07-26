defmodule BarkparkCloud.Push.Adapters.APNS do
  @moduledoc """
  The REAL Apple Push Notification service adapter (provider API, token-based
  authentication) behind `BarkparkCloud.Push.Adapter`.

  Wire shape, per Apple's "Sending notification requests to APNs":

      POST https://api.sandbox.push.apple.com/3/device/<device-token>   (HTTP/2 only)
      authorization: bearer <ES256 JWT: {iss: team_id, iat: now}, kid = key_id>
      apns-topic: <bundle id>
      apns-push-type: alert
      apns-priority: 10
      apns-collapse-id: <session id, <= 64 bytes>
      {"aps": {"alert": {"title": .., "body": ..}, "sound": "default"},
       "deep_link": "barkpark://sessions/..", "data": {..D59h 5 fields..}}

  `apns-collapse-id` is set to the blocked session id ON PURPOSE: a session that
  blocks, gets answered, and blocks again should replace its own banner in
  Notification Center rather than stack — the notification is a pointer to live
  state (the bound deep-link ruling in `BarkparkCloud.Push`), and N stale
  pointers to one session are noise.

  ## Verdict mapping (the `Push.Adapter` contract)

  | APNs                                          | verdict                    |
  |-----------------------------------------------|----------------------------|
  | 200                                            | `{:ok, apns_id}`           |
  | 410 `Unregistered`                             | `{:error, :unregistered}` — row REVOKED |
  | 400 `BadDeviceToken` / `DeviceTokenNotForTopic` | `{:error, :invalid_token}` — row REVOKED |
  | 403 `ExpiredProviderToken`                     | `{:error, ...}` + provider-token cache dropped, so the Oban retry mints a fresh JWT |
  | 403 `InvalidProviderToken`, 413, 429, 5xx      | `{:error, ...}` — retried on the worker's backoff |
  | no credentials configured                      | `{:error, :not_configured}` |

  Note what is deliberately NOT terminal: `InvalidProviderToken` (a bad key id /
  team id) is an OPERATOR error, not a dead device — revoking the user's device
  row over it would silently unsubscribe the whole fleet on a typo. It retries,
  fails, and stays visible.

  ## Configuration

      config :barkpark_cloud, BarkparkCloud.Push.Adapters.APNS,
        key_p8: "-----BEGIN PRIVATE KEY-----\\n…",   # APNS_KEY_P8
        key_id: "ABC123DEFG",                        # APNS_KEY_ID
        team_id: "TEAM123456",                       # APNS_TEAM_ID
        topic: "cloud.barkpark.mobile",              # APNS_BUNDLE_ID
        env: "sandbox"                               # APNS_ENV (sandbox | production)

  With ANY of the first four absent the module reports `configured?/0 == false`
  and `Push` never selects it — `NotConfigured` answers instead and every send
  cancels terminally. That is the credential half of severability; the row half
  (`device_push_tokens` absence) is unchanged.
  """

  @behaviour BarkparkCloud.Push.Adapter

  require Logger

  alias BarkparkCloud.Push.DevicePushToken
  alias BarkparkCloud.Push.HTTP
  alias BarkparkCloud.Push.JWT
  alias BarkparkCloud.Push.TokenCache

  @sandbox_host "api.sandbox.push.apple.com"
  @production_host "api.push.apple.com"

  # Apple accepts a provider token for 1h and REJECTS refreshes more frequent
  # than 1 per 20 min. 45 min sits comfortably inside both bounds.
  @token_ttl_s 2_700

  @doc "True when every credential a send needs is present."
  @spec configured?() :: boolean()
  def configured? do
    config = config()

    Enum.all?([:key_p8, :key_id, :team_id, :topic], fn key ->
      value = Keyword.get(config, key)
      is_binary(value) and value != ""
    end)
  end

  @impl true
  def send_push(%DevicePushToken{token: device_token}, notification) do
    if configured?() do
      config = config()

      case provider_token(config) do
        {:ok, jwt} -> post(device_token, notification, jwt, config)
        {:error, reason} -> {:error, {:provider_token, reason}}
      end
    else
      {:error, :not_configured}
    end
  end

  defp post(device_token, notification, jwt, config) do
    url = "https://" <> host(config) <> "/3/device/" <> device_token

    request = %{
      method: :post,
      url: url,
      headers: headers(jwt, notification, config),
      body: Jason.encode!(payload(notification)),
      # APNs speaks HTTP/2 ONLY — pinning it makes a misconfigured transport
      # fail at connect with a legible error instead of a mystery protocol
      # error mid-request.
      protocols: [:http2]
    }

    case HTTP.request(request) do
      {:ok, %{status: 200} = response} ->
        {:ok, header_value(response.headers, "apns-id") || :sent}

      {:ok, %{status: status} = response} ->
        classify(status, reason_of(response.body))

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp headers(jwt, notification, config) do
    base = [
      {"authorization", "bearer " <> jwt},
      {"apns-topic", Keyword.fetch!(config, :topic)},
      {"apns-push-type", "alert"},
      {"apns-priority", "10"},
      {"content-type", "application/json"}
    ]

    case collapse_id(notification) do
      nil -> base
      id -> base ++ [{"apns-collapse-id", id}]
    end
  end

  # APNs caps apns-collapse-id at 64 BYTES and 400s an oversize one. Session ids
  # are uuids (36 bytes) so this never bites today; the clamp is here so a future
  # id shape cannot turn every notification into a 400.
  #
  # ACCEPTED, not fixed: the clamp is a BYTE cut, so a >64-byte id whose 64th byte
  # falls inside a multibyte character would yield an invalid-UTF-8 header value —
  # i.e. a 400 from APNs (or a rejected header) for EVERY send, which is exactly
  # the failure the clamp exists to prevent. Unreachable while session ids are
  # ASCII uuids; a change to the id shape (the only way in) must make this cut
  # grapheme-aware rather than lengthen the id.
  defp collapse_id(notification) do
    case get_in(notification, ["data", "session_id"]) do
      id when is_binary(id) and id != "" -> binary_part(id, 0, min(byte_size(id), 64))
      _ -> nil
    end
  end

  defp payload(notification) do
    %{
      "aps" => %{
        "alert" => %{
          "title" => notification["title"],
          "body" => notification["body"]
        },
        "sound" => "default"
      },
      "deep_link" => notification["deep_link"],
      "data" => notification["data"] || %{}
    }
  end

  # 410 Unregistered and 400 BadDeviceToken are the two "this address is dead"
  # verdicts; everything else is transient or an operator problem.
  defp classify(410, _reason), do: {:error, :unregistered}
  defp classify(400, "BadDeviceToken"), do: {:error, :invalid_token}
  defp classify(400, "DeviceTokenNotForTopic"), do: {:error, :invalid_token}

  defp classify(403, "ExpiredProviderToken") do
    # The cached JWT aged out between mint and send. Drop it so the worker's
    # retry signs a fresh one instead of re-presenting the same dead token for
    # all four attempts.
    TokenCache.drop(:apns)
    {:error, :expired_provider_token}
  end

  defp classify(status, reason), do: {:error, {:apns, status, reason}}

  defp reason_of(body) do
    case Jason.decode(body) do
      {:ok, %{"reason" => reason}} when is_binary(reason) -> reason
      _ -> nil
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  # One ES256 provider token, cached (see TokenCache for why Apple insists).
  #
  # NO SINGLE-FLIGHT, accepted deliberately: on a COLD cache a fan-out can sign
  # up to queue-concurrency JWTs concurrently (each `:miss` mints, the last write
  # wins in `TokenCache.put/3`). Apple answers a burst of DISTINCT provider tokens
  # for one key with 403 `TooManyProviderTokenUpdates`, which `classify/2` maps to
  # the generic retryable arm — the Oban backoff then re-sends, by which time the
  # winner's token is cached and every attempt presents the SAME one, so the send
  # recovers on its own. The cost is a handful of extra signatures and one
  # retry-cycle of delay on the first send after a deploy; a single-flight owner
  # process would be a supervised singleton (with its own failure modes) bought
  # for that. Revisit together with the connection pool, not before.
  defp provider_token(config) do
    case TokenCache.fetch(:apns) do
      {:ok, jwt} ->
        {:ok, jwt}

      :miss ->
        now = System.system_time(:second)
        claims = %{"iss" => Keyword.fetch!(config, :team_id), "iat" => now}

        case JWT.es256(claims, Keyword.fetch!(config, :key_p8), Keyword.fetch!(config, :key_id)) do
          {:ok, jwt} ->
            TokenCache.put(:apns, jwt, now + @token_ttl_s)
            {:ok, jwt}

          {:error, reason} ->
            Logger.error("APNs provider token could not be signed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp host(config) do
    case Keyword.get(config, :env) do
      "production" -> @production_host
      _ -> @sandbox_host
    end
  end

  defp config, do: Application.get_env(:barkpark_cloud, __MODULE__, [])
end
