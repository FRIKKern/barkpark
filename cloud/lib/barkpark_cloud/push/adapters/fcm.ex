defmodule BarkparkCloud.Push.Adapters.FCM do
  @moduledoc """
  The REAL Firebase Cloud Messaging adapter (**HTTP v1**, OAuth2 service
  account) behind `BarkparkCloud.Push.Adapter`.

  HTTP v1, not the legacy `fcm/send` server-key API — that one was shut down in
  2024 and there is no reason to write new code against it. Two hops:

      1. mint an RS256 assertion from the service-account key and exchange it
         POST https://oauth2.googleapis.com/token
         grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=<jwt>
         → {"access_token": .., "expires_in": 3599}          (CACHED, see below)

      2. POST https://fcm.googleapis.com/v1/projects/<project>/messages:send
         authorization: Bearer <access_token>
         {"message": {"token": "<device>",
                      "notification": {"title": .., "body": ..},
                      "data": {"deep_link": .., ..D59h 5 fields..},
                      "android": {"priority": "HIGH",
                                  "collapse_key": "<session id>"}}}

  Hop 1 is cached in `Push.TokenCache` for the token's real lifetime; without
  that, a fan-out of N devices would make 2N calls and lean on Google's token
  quota for no reason.

  **`data` values must be strings** — FCM's `data` map is `map<string,string>`
  and a non-string value is a 400 `INVALID_ARGUMENT`. The D59h payload is all
  strings today; `stringify/1` below makes that structural instead of lucky.

  ## Verdict mapping (the `Push.Adapter` contract)

  | FCM                                   | verdict                              |
  |---------------------------------------|--------------------------------------|
  | 200                                    | `{:ok, message_name}`               |
  | 404 `UNREGISTERED`                     | `{:error, :unregistered}` — row REVOKED |
  | 404 anything else (`NOT_FOUND` — e.g. a deleted/renamed Firebase project) | `{:error, ...}` — retried; a project outage must not self-revoke the fleet |
  | 400 `INVALID_ARGUMENT`                 | `{:error, :invalid_token}` — row REVOKED |
  | 403 `SENDER_ID_MISMATCH`               | `{:error, :invalid_token}` — row REVOKED (the token belongs to another Firebase sender; it can never work for us) |
  | 401                                    | `{:error, ...}` + access-token cache dropped so the retry re-exchanges |
  | 429 `QUOTA_EXCEEDED`, 503 `UNAVAILABLE`, 5xx | `{:error, ...}` — retried on the worker's backoff |
  | no credentials configured              | `{:error, :not_configured}`          |

  `INVALID_ARGUMENT` as terminal deserves its caveat: FCM also returns it for a
  MALFORMED REQUEST, not only a malformed token. We accept revoking the row in
  that case — a request shape this adapter builds is either right for every
  device or wrong for every device, so a systematic 400 shows up as the entire
  fleet self-revoking within one fan-out, which is loud. A silent retry storm
  would not be.

  ## Configuration

      config :barkpark_cloud, BarkparkCloud.Push.Adapters.FCM,
        service_account_json: ~s({"type":"service_account","project_id":…})

  (`FCM_SERVICE_ACCOUNT_JSON` — the whole downloaded key file, verbatim.) With
  it absent or unparseable, `configured?/0` is false, `Push` never selects this
  module, and `NotConfigured` cancels every send terminally.
  """

  @behaviour BarkparkCloud.Push.Adapter

  require Logger

  alias BarkparkCloud.Push.DevicePushToken
  alias BarkparkCloud.Push.HTTP
  alias BarkparkCloud.Push.JWT
  alias BarkparkCloud.Push.TokenCache

  @scope "https://www.googleapis.com/auth/firebase.messaging"
  @default_token_uri "https://oauth2.googleapis.com/token"
  @assertion_ttl_s 3_600

  @doc "True when a parseable service-account key with the fields a send needs is present."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, credentials())

  @impl true
  def send_push(%DevicePushToken{token: device_token}, notification) do
    # No `else`: every failure branch here is already `{:error, reason}` in the
    # behaviour's shape — `:not_configured` from `credentials/0` included — so
    # `with` returning it unchanged IS the contract.
    with {:ok, creds} <- credentials(),
         {:ok, access_token} <- access_token(creds) do
      post(device_token, notification, access_token, creds)
    end
  end

  defp post(device_token, notification, access_token, creds) do
    request = %{
      method: :post,
      url: "https://fcm.googleapis.com/v1/projects/#{creds.project_id}/messages:send",
      headers: [
        {"authorization", "Bearer " <> access_token},
        {"content-type", "application/json"}
      ],
      body: Jason.encode!(%{"message" => message(device_token, notification)})
    }

    case HTTP.request(request) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, decoded_name(body) || :sent}

      {:ok, %{status: status, body: body}} ->
        classify(status, error_status(body))

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp message(device_token, notification) do
    data =
      (notification["data"] || %{})
      |> Map.put("deep_link", notification["deep_link"])
      |> stringify()

    base = %{
      "token" => device_token,
      "notification" => %{
        "title" => notification["title"],
        "body" => notification["body"]
      },
      "data" => data
    }

    case data["session_id"] do
      id when is_binary(id) and id != "" ->
        # Same intent as the APNs collapse-id: a re-block of one session
        # replaces its own tray entry rather than stacking pointers to live
        # state. FCM caps collapse_key at 64 bytes like APNs.
        Map.put(base, "android", %{
          "priority" => "HIGH",
          "collapse_key" => binary_part(id, 0, min(byte_size(id), 64))
        })

      _ ->
        Map.put(base, "android", %{"priority" => "HIGH"})
    end
  end

  # FCM's data map is map<string,string>; anything else is a 400.
  defp stringify(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn
      {k, v} when is_binary(v) -> {to_string(k), v}
      {k, v} -> {to_string(k), to_string(v)}
    end)
  end

  # 404 alone is NOT proof of a dead device: FCM answers 404 `UNREGISTERED` for
  # a stale token, but ALSO plain 404 `NOT_FOUND` when the URL path is wrong —
  # e.g. a deleted or renamed Firebase project. Classifying every 404 as
  # `:unregistered` would let a project-level outage silently self-revoke the
  # entire Android fleet, one row per delivery (PR #6122 review finding). Only
  # the explicit `UNREGISTERED` status is terminal; any other 404 falls through
  # to the retryable catch-all and stays loud.
  defp classify(404, "UNREGISTERED"), do: {:error, :unregistered}
  defp classify(400, "INVALID_ARGUMENT"), do: {:error, :invalid_token}
  defp classify(403, "SENDER_ID_MISMATCH"), do: {:error, :invalid_token}

  defp classify(401, status) do
    # The cached access token was revoked or aged out mid-flight; drop it so the
    # retry re-exchanges the assertion instead of replaying a dead bearer.
    TokenCache.drop(:fcm)
    {:error, {:fcm, 401, status}}
  end

  defp classify(status, error), do: {:error, {:fcm, status, error}}

  defp error_status(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"status" => status}}} when is_binary(status) -> status
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
      _ -> nil
    end
  end

  defp decoded_name(body) do
    case Jason.decode(body) do
      {:ok, %{"name" => name}} when is_binary(name) -> name
      _ -> nil
    end
  end

  ## OAuth2 — the service-account assertion exchange (hop 1)

  defp access_token(creds) do
    case TokenCache.fetch(:fcm) do
      {:ok, token} -> {:ok, token}
      :miss -> exchange(creds)
    end
  end

  defp exchange(creds) do
    now = System.system_time(:second)

    claims = %{
      "iss" => creds.client_email,
      "scope" => @scope,
      "aud" => creds.token_uri,
      "iat" => now,
      "exp" => now + @assertion_ttl_s
    }

    with {:ok, assertion} <- JWT.rs256(claims, creds.private_key),
         {:ok, %{status: 200, body: body}} <- token_request(creds, assertion),
         {:ok, %{"access_token" => token} = decoded} <- Jason.decode(body) do
      expires_in = decoded["expires_in"]
      ttl = if is_integer(expires_in), do: expires_in, else: @assertion_ttl_s
      TokenCache.put(:fcm, token, now + ttl)
      {:ok, token}
    else
      {:ok, %{status: status, body: body}} ->
        Logger.error("FCM token exchange refused: #{status} #{String.slice(body, 0, 300)}")
        {:error, {:fcm_token_exchange, status}}

      {:error, reason} ->
        Logger.error("FCM token exchange failed: #{inspect(reason)}")
        {:error, {:fcm_token_exchange, reason}}

      other ->
        {:error, {:fcm_token_exchange, other}}
    end
  end

  defp token_request(creds, assertion) do
    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => assertion
      })

    HTTP.request(%{
      method: :post,
      url: creds.token_uri,
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: body
    })
  end

  ## Credentials

  defp credentials do
    json = Application.get_env(:barkpark_cloud, __MODULE__, [])[:service_account_json]

    with true <- is_binary(json) and json != "",
         {:ok, %{} = decoded} <- Jason.decode(json),
         project_id when is_binary(project_id) <- decoded["project_id"],
         client_email when is_binary(client_email) <- decoded["client_email"],
         private_key when is_binary(private_key) <- decoded["private_key"] do
      {:ok,
       %{
         project_id: project_id,
         client_email: client_email,
         private_key: private_key,
         token_uri: decoded["token_uri"] || @default_token_uri
       }}
    else
      _ -> {:error, :not_configured}
    end
  end
end
