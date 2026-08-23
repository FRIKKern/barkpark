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
  # maybe_prune/1 opportunistically drops buckets untouched for @stale_after_ms,
  # and only once the table passes @max_entries, so the steady-state hot path
  # costs one :ets.info/2.
  #
  # @stale_after_ms IS AN INVARIANT, NOT A TUNABLE. Deleting a bucket re-creates
  # it FULL on the owner's next request, so the cutoff must be >= the SLOWEST
  # full-refill-from-empty time of any RateLimiter.check/2 call site in the tree.
  # Below that line a still-DEPLETED bucket is dropped as "stale" and its owner
  # is handed a fresh allowance: a rate-limit RESET, not the behaviour-identical
  # no-op the prune is sold as.
  #
  # Census of every call site, as capacity / refill_per_sec = seconds to refill
  # from empty. RE-DERIVE THIS before moving the constant — a new call site with
  # a slower window silently invalidates it:
  #
  #   pulse READ (pulse_controller)        30 / 10.0            =    3s
  #   Plugs.RateLimit                      N / (N/60)           =   60s
  #   app_token_controller (revoke)        10 / (10/60)         =   60s
  #   pulse WRITE (pulse_controller)       3 / (rate/60)        =  180s worst
  #       (rate = channel rate_per_min; Pulse.sane_rate/1 clamps it to a
  #        positive integer, so rate=1 is the floor and 180s the worst case)
  #   bulldocs_form_controller             20 / (1/60)          = 1200s
  #   Plugs.TicketRateLimit                N / (N/3600)         = 3600s
  #   Plugs.AuthWriteRateLimit             N / (N/3600)         = 3600s
  #
  # HOW THE OLD 300_000 (5 min) WENT WRONG, because the shape repeats: it was
  # written when Plugs.RateLimit was the ONLY caller, and its comment said so —
  # "the plug", singular, a CONSTANT 60s full-refill. TicketRateLimit landed one
  # day later and AuthWriteRateLimit six weeks after that, both hourly, and
  # neither author opened this file. A depleted hourly bucket idle 5 min had
  # legitimately earned only limit/12 tokens, was deleted as stale, and came back
  # FULL — ~12x the hourly budget on the UNAUTHENTICATED POST /v1/auth/register
  # path whose entire job is bounding third-party mailbombing. bulldocs_form is a
  # third shape: at 20 tokens and 1/60 per sec it can never be both stale and
  # empty, but a bucket emptied 310s ago has earned 5 of 20 and the prune re-
  # grants all 20.
  #
  # COMPOUNDING IT: the :rate_limited branch of debit/4 writes NOTHING, so
  # last_ms freezes at the last SUCCESSFUL admit. A client that hammers and keeps
  # getting denied never refreshes its row, and ages toward prune-eligibility
  # WHILE being denied — the reset lands on precisely the abuser the bucket
  # exists to stop.
  #
  # "Prune only fully-refilled buckets" is NOT expressible here: the row
  # {key, tokens, last_ms} carries neither capacity nor refill rate — that
  # arithmetic lives entirely in the caller's opts. The flat cutoff IS the whole
  # mechanism, which is why it has to track the slowest window by hand.
  #
  # PRICE OF THE WIDEN, measured: the table sits over @max_entries for longer, so
  # the select_delete below runs a full scan that deletes nothing (~512us median
  # on a 12k-row table, vs <1us for a keyed lookup). That is per NEW-KEY insert,
  # not per request.
  @max_entries 10_000
  @stale_after_ms 3_600_000

  # Bounded retry budget for the lock-free debit below. Not a caller option:
  # the bound is a property of the commit protocol, not of any call site.
  @max_commit_attempts 128

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

    debit(key, capacity, refill, @max_commit_attempts)
  end

  # The commit is lock-free, not serialized: a GenServer would make every
  # request on every key queue behind one process. `:ets.lookup` followed by
  # `:ets.insert` is two separate atomic operations, so between them another
  # process runs the same sequence, reads the SAME bucket state, decides
  # independently that a token is available, and is admitted too — N concurrent
  # callers all pass on one token and the bound fails OPEN. Both branches below
  # therefore commit conditionally on the state they read and retry on a loss.
  #
  # Exhausting the budget fails CLOSED: bounding admissions is the whole job, so
  # a debit we could not commit must deny rather than admit undebited. 128 is
  # far past what 200-way contention needs (measured: 0 denials in 6000
  # contended calls); a bound of 8 fail-closed-denies ~36% of that traffic.
  defp debit(_key, _capacity, _refill, 0), do: :rate_limited

  defp debit(key, capacity, refill, attempts_left) do
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [] ->
        # Prune on the first attempt only: a retry here means another caller
        # just created this bucket, and re-walking on every retry would turn a
        # contended cold key into repeated table scans.
        if attempts_left == @max_commit_attempts, do: maybe_prune(now_ms)

        # insert_new/2 is the cold-key compare-and-swap: exactly one of N
        # racing callers creates the bucket (the unconditional insert let each
        # of them RESET it to full instead). `false` means somebody else won,
        # so we must not return :ok (an undebited admission) and must not
        # return :rate_limited (denying a legitimate first request) — we fall
        # through to a fresh read, which takes the existing-bucket branch.
        if :ets.insert_new(@table, {key, capacity - 1.0, now_ms}) do
          :ok
        else
          debit(key, capacity, refill, attempts_left - 1)
        end

      [{^key, tokens, last_ms} = current] ->
        elapsed_s = (now_ms - last_ms) / 1000
        refilled = min(capacity * 1.0, tokens + elapsed_s * refill)

        if refilled >= 1.0 do
          # select_replace/2 writes only if the row STILL holds the exact tuple
          # we read, so the read and the debit commit as one step. 0 means
          # somebody debited underneath us: retry from a FRESH read, never from
          # the stale `refilled`.
          case :ets.select_replace(@table, __cas_spec__(current, {key, refilled - 1.0, now_ms})) do
            1 -> :ok
            0 -> debit(key, capacity, refill, attempts_left - 1)
          end
        else
          :rate_limited
        end
    end
  end

  # TWO CONSTRAINTS, BOTH LOAD-BEARING AND BOTH INVISIBLE TO BEHAVIOURAL TESTS:
  #
  # 1. The match HEAD must be the literal tuple just read. A `:"$1"`-key head
  #    plus an equality guard is equally correct and equally atomic, but it is
  #    a FULL TABLE SCAN (measured 0.43us vs 30,252us per call on a 200k-row
  #    table) — it replaces the same row and returns the same 1.
  # 2. The BODY must be `{:const, replacement}`. A bare tuple body is read as a
  #    match-spec EXPRESSION, which raises ArgumentError ("not a valid match
  #    specification") for every tuple key this limiter is called with
  #    ({:auth_write, …}, {:ticket, …}, {:pulse, …}, {:token, …}) while
  #    silently working for the string keys Plugs.RateLimit builds.
  @doc false
  def __cas_spec__(current, replacement), do: [{current, [], [{:const, replacement}]}]

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

  # Drop buckets idle past @stale_after_ms once the table grows past
  # @max_entries. Runs on the new-key path only, and does real work only when
  # over the bound, so a pruned table stays under it until it grows again —
  # naturally throttled. The cutoff, not this scan, is what makes the delete
  # safe: see @stale_after_ms above for the census it has to track.
  defp maybe_prune(now_ms) do
    if :ets.info(@table, :size) > @max_entries do
      cutoff = now_ms - @stale_after_ms
      :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    end

    :ok
  end
end
