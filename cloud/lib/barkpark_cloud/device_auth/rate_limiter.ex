defmodule BarkparkCloud.DeviceAuth.RateLimiter do
  @moduledoc """
  A fixed-window rate limiter for the device-authorization endpoints
  (bp-login-ux), the sibling of `Accounts.TwoFactorRateLimiter` — the same
  GenServer-owns-one-public-ETS-table shape, but its OWN table (the key shapes
  differ, so they must not share) and a GENERIC `check/1` keyed by an arbitrary
  string. The per-action limit is chosen by the key's `"<action>:"` prefix
  (charter decision 8):

    * `"poll:"<device_code_hash>` — 20 / 60s. The CLI polls every 5s; 20/min
      leaves generous headroom while capping a runaway loop. The router maps the
      breach to `429 {"error":"slow_down"}` (RFC-8628 back-off signal).
    * `"start:"<peer_ip>`  — 10 / 60s. Caps device-request creation per IP.
    * `"approve:"<user_id>` — 10 / 60s. Caps approve/deny/inspect attempts per
      authenticated user, so an authed attacker can't brute the ~39-bit user_code
      within its 600s TTL.
    * `"app_token:"<peer_ip>` — 10 / 60s. Caps app-token exchange mints per IP
      (`POST /v1/barkparks/:id/app-token`) — each hit costs the instance a
      server-side admin-authed mint call, so a runaway client must be braked
      here, before the proxy fans out.
    * `"app_token_revoke:"<peer_ip>` — 10 / 60s. The mint bucket's revoke twin
      (`DELETE /v1/barkparks/:id/app-token`, mob-w2-app-token-revoke) — same
      physics (every hit is a server-side admin-authed instance call), its own
      bucket so a logout loop can't starve mints and vice versa.

  The key is `{key_string, window}` where `window = div(now_ms, @window_ms)`, so
  elapsed windows are lazily swept on the next `check/1` for that key and the
  table can't grow unbounded. `check/1` is the only mutation; `reset/0` clears
  the table for deterministic tests.
  """
  use GenServer

  @table __MODULE__
  @window_ms 60_000
  @default_limit 10
  @limits %{
    "poll" => 20,
    "start" => 10,
    "approve" => 10,
    "app_token" => 10,
    "app_token_revoke" => 10
  }

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Record one hit against `key` and enforce its window limit. Returns `:ok` while
  at or under the limit for the key's action prefix, `{:error, :rate_limited}`
  once exceeded. The window is #{div(@window_ms, 1000)}s.
  """
  @spec check(binary(), integer()) :: :ok | {:error, :rate_limited}
  def check(key, now_ms \\ System.system_time(:millisecond))

  def check(key, now_ms) when is_binary(key) and is_integer(now_ms) do
    limit = limit_for(key)
    window = div(now_ms, @window_ms)

    # Drop this key's rows from any earlier window so the table stays bounded.
    :ets.select_delete(@table, [
      {{{key, :"$1"}, :_}, [{:"/=", :"$1", window}], [true]}
    ])

    count = :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0})

    if count > limit, do: {:error, :rate_limited}, else: :ok
  end

  @doc "Clear all counters (test helper — keeps async: false rate-limit tests deterministic)."
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp limit_for(key) do
    action = key |> String.split(":", parts: 2) |> hd()
    Map.get(@limits, action, @default_limit)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end
end
