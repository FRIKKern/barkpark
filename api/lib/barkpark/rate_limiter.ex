defmodule Barkpark.RateLimiter do
  @moduledoc """
  Process-global token-bucket limiter over one ETS table, plus the TRUST
  BOUNDARY every IP-keyed bucket resolves its key through (`client_ip/1`).

  A bucket is only a limit if the client cannot choose its own key. Callers
  used to read the FIRST `x-forwarded-for` hop unconditionally, which is sound
  only when the header is guaranteed to come from our own front — it is not:
  Caddy APPENDS to whatever the caller sent, so a request reaching the box
  directly with `x-forwarded-for: 9.9.9.9` produced the bucket key `9.9.9.9`
  and could rotate it per request, i.e. no effective per-IP limit at all. The
  header became load-bearing when the Cloud control plane started relaying the
  caller's address on the revoke DELETE (`Registry.revoke_app_token/3`), so the
  boundary is now drawn here, once, for every IP-keyed bucket.

  `client_ip/1` therefore resolves the RIGHTMOST hop of the chain that is not a
  known proxy, and only consults the chain at all when the immediate peer is
  itself trusted. Trusted = loopback (Caddy runs on the box and dials
  `localhost:4000`) plus any address in `config :barkpark, :trusted_proxies`
  (`BARKPARK_TRUSTED_PROXIES`) — individual addresses only, never CIDR ranges:
  a wide range is the forgery hole again, since an attacker whose own address
  falls inside it gets its appended hop SKIPPED and its forged left-hand hop
  believed.
  """

  @table :barkpark_rate_limiter

  @default_capacity 200
  @default_refill_per_sec 200.0 / 60.0

  # The table holds one {key, tokens, last_ms} bucket per rate-limit key
  # (IP/token) and nothing ever deleted them — so in the long-lived API server it
  # grew without bound (one permanent entry per unique client ever seen).
  # maybe_prune/1 opportunistically drops buckets untouched for @stale_after_ms.
  # The plug's capacity/refill is a CONSTANT 60s full-refill (both scale with
  # per_minute), so any bucket idle ≥5 min is fully refilled — dropping it is
  # behaviour-identical to keeping it (the next request just re-creates a full
  # bucket), with no rate-limit reset/bypass. The prune only runs once the table
  # passes @max_entries, so the steady-state hot path costs one :ets.info/2.
  @max_entries 10_000
  @stale_after_ms 300_000

  def start_link(_opts \\ []) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end

    {:ok, self()}
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec check(term(), keyword()) :: :ok | :rate_limited
  def check(key, opts \\ []) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)
    refill = Keyword.get(opts, :refill_per_sec, @default_refill_per_sec)
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [] ->
        maybe_prune(now_ms)
        :ets.insert(@table, {key, capacity - 1.0, now_ms})
        :ok

      [{^key, tokens, last_ms}] ->
        elapsed_s = (now_ms - last_ms) / 1000
        refilled = min(capacity * 1.0, tokens + elapsed_s * refill)

        if refilled >= 1.0 do
          :ets.insert(@table, {key, refilled - 1.0, now_ms})
          :ok
        else
          :rate_limited
        end
    end
  end

  @doc """
  The client IP an IP-keyed bucket must key on, as a canonical string.

  ONE resolver for every IP-keyed bucket (the pulse write/read buckets and the
  `:app_token_revoke` bucket) — see the moduledoc for why the naive first-hop
  read was not a limit. Resolution:

    1. peer NOT trusted → the peer address, and the header is ignored entirely
       (a direct caller can never move its own bucket);
    2. peer trusted → walk `x-forwarded-for` right-to-left, skip trusted hops,
       and take the first hop that is not one. Caddy appends the address it
       actually saw at the RIGHT end, so a caller-supplied prefix is discarded;
    3. nothing usable in the chain (absent, or a hop that is not an IP at all)
       → fall back to the peer. Fail closed, never onto attacker-chosen text.

  Every hop is parsed to an `:inet` tuple and re-rendered, so alternate
  spellings of one address (`::1` vs `0:0:0:0:0:0:0:1`, `::ffff:127.0.0.1` vs
  `127.0.0.1`, `127.1` vs `127.0.0.1`) collapse to ONE bucket key instead of
  handing a client a fresh budget per spelling.
  """
  # @canonical capability:rate-limit-client-ip aka:client_ip,x-forwarded-for,xff,trusted-proxy,bucket-key,spoof
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(%Plug.Conn{remote_ip: peer} = conn) do
    with true <- trusted_proxy?(peer),
         client when is_binary(client) <-
           conn |> Plug.Conn.get_req_header("x-forwarded-for") |> rightmost_untrusted() do
      client
    else
      _ -> ip_to_string(peer)
    end
  end

  # A chain may arrive as several headers AND as comma-separated hops within
  # each; order is left (originator) to right (nearest proxy).
  defp rightmost_untrusted(header_values) do
    header_values
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.reduce_while(nil, fn hop, _acc ->
      case parse_hop(hop) do
        {:ok, address} ->
          if trusted_proxy?(address),
            do: {:cont, nil},
            else: {:halt, ip_to_string(address)}

        :error ->
          # Unparseable hop: we cannot tell whether it is a proxy of ours, so we
          # stop rather than guess — the caller falls back to the verified peer.
          {:halt, nil}
      end
    end)
  end

  # Bracketed IPv6 (`[2001:db8::1]`) is tolerated; a port suffix is not, because
  # X-Forwarded-For carries bare addresses and anything else is untrustworthy.
  defp parse_hop(hop) do
    hop
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> {:ok, unmap(address)}
      {:error, _} -> :error
    end
  end

  # Trusted fronts: loopback always (Caddy is co-located and dials localhost),
  # plus the operator's explicit list — e.g. the Cloud control plane's egress
  # address, without which its relayed XFF is correctly disbelieved and a whole
  # team collapses back into one bucket.
  defp trusted_proxy?(peer) when is_tuple(peer), do: trusted?(unmap(peer))
  defp trusted_proxy?(_), do: false

  defp trusted?({127, _, _, _}), do: true
  defp trusted?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # `|| []` because an explicit `nil` in config is a plausible operator typo and
  # iterating nil raises — that would 500 every request. Fail closed, not loudly.
  # Configured entries are unmapped too, so an operator who writes an
  # IPv4-mapped form still matches the peer we resolved; a non-tuple entry (a
  # bare string in config) simply never matches instead of crashing.
  defp trusted?(address) do
    configured = Application.get_env(:barkpark, :trusted_proxies) || []
    Enum.any?(configured, fn proxy -> is_tuple(proxy) and unmap(proxy) == address end)
  end

  # IPv4-mapped IPv6 (::ffff:a.b.c.d) → the v4 tuple, so a dual-stack listener's
  # peer is recognised as loopback/trusted and keys the same bucket as v4.
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: {div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)}

  defp unmap(address), do: address

  defp ip_to_string(address) when is_tuple(address) do
    case :inet.ntoa(unmap(address)) do
      {:error, _} -> "unknown"
      chars -> to_string(chars)
    end
  end

  # No usable peer (nil / malformed): one shared bucket, which is STRICTER than
  # handing out a fresh one.
  defp ip_to_string(_), do: "unknown"

  # Drop fully-refilled (stale) buckets once the table grows past @max_entries.
  # Runs on the new-key path only, and does real work only when over the bound,
  # so a pruned table stays under it until it grows again — naturally throttled.
  defp maybe_prune(now_ms) do
    if :ets.info(@table, :size) > @max_entries do
      cutoff = now_ms - @stale_after_ms
      :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    end

    :ok
  end
end
