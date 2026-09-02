defmodule BarkparkWeb.Plugs.AuthWriteRateLimit do
  @moduledoc """
  A TIGHTER, per-IP bucket for the unauthenticated account-creation write
  (`POST /v1/auth/register`), billed SEPARATELY from the general anonymous-write
  budget.

  ## Why a second bucket (this is a granularity fix, not "add throttling")

  Register already rides `:user_auth`, which mounts `Plugs.RateLimit` — so it was
  already metered, but against the ONE shared per-IP anon-write bucket
  (`ip:<ip>:write:global`, 60/min) that every other anonymous write shares. Two
  problems follow from sharing:

    1. **Starvation.** 60 registers in a minute exhausts the shared budget, so a
       register flood 429s every *other* anonymous write from that IP.
    2. **The ceiling is the wrong order of magnitude.** The real abuse here is
       MAIL, not rows: a register for a fresh address sends a confirmation email
       synchronously, and a register for an address that already exists
       re-mails the *existing* account holder (`notify_existing_account`). 60
       requests/minute is therefore a 3600-mail/hour mailbomb aimed at a third
       party, comfortably inside a bucket nominally meant to protect the API.

  So register gets its own bucket, keyed `{:auth_write, class, client_ip}` and
  budgeted PER HOUR. Exhausting it cannot spend the general write budget, and
  exhausting the general write budget cannot spend this one — the two buckets are
  independent by key.

  ## The ceiling

  Default **5 registers per hour per IP** — a human signing up, plus retries and
  typo-corrections, with room to spare; a mail-amplification loop, no. Bounded
  above by the same number: ≤5 confirmation mails/hour/IP.

  Operator-tunable without a rebuild via `BARKPARK_AUTH_RATE_REGISTER`
  (`config :barkpark, :auth_write_rate_limits` in runtime.exs), mirroring
  `BARKPARK_RATE_LIMIT_WRITE` and `BARKPARK_TICKET_RATE_*`.

  This plug is a THROTTLE and only a throttle. Gating registration beyond a
  throttle — invite codes, a domain allowlist, disabling open signup entirely —
  is the instance owner's policy call and deliberately NOT decided here.

  ## Hourly budget on a per-second token bucket

  Same mapping as `Plugs.TicketRateLimit`: `Barkpark.RateLimiter.check/2` is a
  generic token bucket, so an hourly budget of `N` is `capacity: N,
  refill_per_sec: N / 3600` — burst the whole hour's allowance, then drip.
  `Retry-After` is the seconds to earn one token back from empty,
  `ceil(3600 / N)`.

  ## Bucket identity

  `Barkpark.RateLimiter.client_ip/1`, never `conn.remote_ip` — behind the
  co-located Caddy the peer is always loopback, which would collapse the whole
  anonymous internet into one bucket (and a naive first-hop `x-forwarded-for`
  read would let a caller pick its own key).

  ## 429 shape

  Identical to `Plugs.RateLimit` and `Plugs.TicketRateLimit`:
  `Content.Errors.to_envelope({:error, :rate_limited, %{retry_after: s}})` as the
  JSON body plus a `Retry-After` header — so a client that already handles the
  general limiter needs no new code path.
  """

  import Plug.Conn

  alias Barkpark.{Content.Errors, RateLimiter}

  @window_seconds 3600
  @defaults [register: 5]

  def init(opts), do: Keyword.put_new(opts, :class, :register)

  def call(conn, opts) do
    class = Keyword.get(opts, :class, :register)
    limit = limit_for(class)

    key = RateLimiter.scope_key(conn, {:auth_write, class, RateLimiter.client_ip(conn)})

    case RateLimiter.check(key, bucket_opts(limit)) do
      :ok -> conn
      :rate_limited -> deny(conn, retry_after_seconds(limit))
    end
  end

  @doc """
  The per-hour ceiling in force for `class`, after config/env overrides.

  Public so the capabilities/ops surface can state the number it actually
  enforces rather than restating a default that an env var may have moved.
  """
  @spec limit_for(atom()) :: pos_integer()
  def limit_for(class) do
    cfg = Application.get_env(:barkpark, :auth_write_rate_limits, [])

    case Keyword.get(cfg, class) do
      n when is_integer(n) and n > 0 -> n
      # An unknown class falls back to the strictest known budget rather than
      # going unmetered: a future auth write mounted here without a config row
      # is over-throttled, never free.
      _ -> Keyword.get(@defaults, class, Keyword.fetch!(@defaults, :register))
    end
  end

  defp bucket_opts(limit), do: [capacity: limit, refill_per_sec: limit / @window_seconds]

  defp retry_after_seconds(limit) when is_integer(limit) and limit > 0 do
    max(1, div(@window_seconds + limit - 1, limit))
  end

  defp retry_after_seconds(_), do: @window_seconds

  defp deny(conn, retry_after) do
    env = Errors.to_envelope({:error, :rate_limited, %{retry_after: retry_after}}, conn)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
