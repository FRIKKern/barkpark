defmodule BarkparkCloud.Push.TokenCache do
  @moduledoc """
  A tiny expiring cache for the two PROVIDER credentials a send must present:
  the APNs ES256 provider token and the FCM OAuth2 access token.

  Why it exists: without it a fan-out of N devices mints N JWTs (APNs) and makes
  2N HTTP calls (FCM — one OAuth exchange per send). Both providers explicitly
  expect reuse: Apple **rejects** provider tokens refreshed more often than once
  per 20 minutes (`TooManyProviderTokenUpdates`), and Google's token endpoint is
  rate-limited.

  `:persistent_term` rather than an Agent/ETS-owning GenServer: there is nothing
  to supervise, reads are lock-free, and a write happens at most once per hour
  per provider (persistent_term's global-scan write cost is irrelevant at that
  rate). Values are opaque to this module.

  Tests call `reset/0` in setup — the cache is process-global, so a cached token
  from one test would otherwise suppress the OAuth exchange another test asserts.
  """

  @keys [{__MODULE__, :apns}, {__MODULE__, :fcm}]

  @doc """
  Fetch `key`'s value if present and not within `skew_s` of expiry, else
  `:miss`. The skew makes "valid at fetch time" mean "still valid when the
  request lands".
  """
  @spec fetch(:apns | :fcm, non_neg_integer()) :: {:ok, term()} | :miss
  def fetch(key, skew_s \\ 60) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      {value, expires_at} ->
        if System.system_time(:second) + skew_s < expires_at, do: {:ok, value}, else: :miss

      _ ->
        :miss
    end
  end

  @doc "Cache `value` under `key` until the absolute unix second `expires_at`."
  @spec put(:apns | :fcm, term(), integer()) :: :ok
  def put(key, value, expires_at) when is_integer(expires_at) do
    :persistent_term.put({__MODULE__, key}, {value, expires_at})
  end

  @doc """
  Drop ONE provider's cached credential. Used when a provider tells us the
  credential we just presented is stale (APNs `ExpiredProviderToken`, FCM 401)
  so the worker's retry mints a fresh one instead of re-presenting the dead one
  for every attempt.
  """
  @spec drop(:apns | :fcm) :: :ok
  def drop(key) do
    :persistent_term.erase({__MODULE__, key})
    :ok
  end

  @doc "Drop every cached provider credential (test setup; credential rotation)."
  @spec reset() :: :ok
  def reset do
    Enum.each(@keys, &:persistent_term.erase/1)
    :ok
  end
end
