defmodule BarkparkWeb.Plugs.TicketRateLimit do
  @moduledoc """
  Per-key abuse rails for the low-trust TICKET-KEY WRITE surface (Barkpark
  Tickets, charter Decision 9). Mounted in the `:ticket_key` pipeline AFTER
  `RequireTicketKey`, so the resolved key id (`conn.assigns.ticket_key.id`) is
  available as the bucket identity.

  ## Writes only — reads are exempt

  `GET`/`HEAD` pass through untouched. This is deliberate and load-bearing: the
  no-push v1 story is *poll-with-key*, and the key-holder's polling loop
  (`GET /v1/tickets/:id`) must NEVER be throttled — throttling it would break the
  product and the two-minute story test. Only the three write verbs are billed.

  ## Classes and per-key budgets

  Class is derived from the request path shape within `/v1/tickets`:

    * `POST /tickets`                 → `:create`
    * `POST /tickets/:id/messages`    → `:message`
    * `POST /tickets/:id/attachments` → `:attachment`

  Each bills a separate token bucket keyed by `{key_id, class}`, so a burst of
  attachments can't starve a submitter's ability to open a fresh ticket, and one
  key's abuse never touches another key's budget.

  Budgets come from `config :barkpark, :ticket_rate_limits` (per-hour), defaults
  `create: 10`, `message: 60`, `attachment: 30`. In prod they are env-tunable
  without a rebuild — `BARKPARK_TICKET_RATE_CREATE` / `_MESSAGE` / `_ATTACHMENT`
  (runtime.exs), mirroring `BARKPARK_RATE_LIMIT_READ`/`_WRITE`.

  An unrecognized WRITE path inside the surface falls back to `:create` — the
  strictest budget — so a future write route added without a class rule here is
  over-throttled, never unmetered.

  ## Hourly budgets on a per-second token bucket

  `Barkpark.RateLimiter.check/2` is a generic token bucket parameterised by
  `capacity` + `refill_per_sec` (no notion of a fixed window). An hourly budget
  of `N` maps to `capacity: N, refill_per_sec: N / 3600` — burst up to the whole
  hourly allowance, then a steady drip that fully refills the budget over one
  hour. `Retry-After` is the seconds to earn one token back from empty,
  `ceil(3600 / N)`.

  ## 429 shape

  Mirrors `BarkparkWeb.Plugs.RateLimit`:
  `Content.Errors.to_envelope({:error, :rate_limited, %{retry_after: s}})` as the
  JSON body plus a `Retry-After` header.

  Respects charter Decision 1 (a leaked key is spam, never data — this is the
  spam half) and Decision 9.
  """

  import Plug.Conn

  alias Barkpark.{Content.Errors, RateLimiter}

  @read_methods ~w(GET HEAD)
  @window_seconds 3600
  @defaults [create: 10, message: 60, attachment: 30]

  def init(opts), do: opts

  # Reads are exempt — the polling loop must never be throttled.
  def call(%Plug.Conn{method: method} = conn, _opts) when method in @read_methods, do: conn

  def call(conn, _opts) do
    case conn.assigns[:ticket_key] do
      %{id: key_id} when not is_nil(key_id) ->
        class = classify(conn)
        limit = limit_for(class)

        # Scoped like every other metered surface. This key is already
        # test-distinct in practice — `key_id` is a sandboxed DB row minted per
        # test — so the suffix changes nothing today; it is here so the C2
        # coverage test's allow-list is the helper ALONE, and so a future test
        # that pins a fixed `ticket_key` id cannot re-open the shared-bucket
        # class through the one `check/2` site that opted out.
        key = {:ticket, key_id, class}

        case RateLimiter.check(RateLimiter.scoped_key(conn, key), bucket_opts(limit)) do
          :ok -> conn
          :rate_limited -> deny(conn, retry_after_seconds(limit))
        end

      # No resolved key (RequireTicketKey would already have halted) — nothing to
      # bill against, so pass through rather than crash.
      _ ->
        conn
    end
  end

  # Fallback is deliberately :create — the STRICTEST budget — so a future write
  # route on this surface without a class rule is over-throttled, never
  # unmetered.
  defp classify(conn) do
    case List.last(conn.path_info) do
      "messages" -> :message
      "attachments" -> :attachment
      _ -> :create
    end
  end

  defp limit_for(class) do
    cfg = Application.get_env(:barkpark, :ticket_rate_limits, [])

    case Keyword.get(cfg, class) do
      n when is_integer(n) and n > 0 -> n
      _ -> Keyword.fetch!(@defaults, class)
    end
  end

  defp bucket_opts(limit), do: [capacity: limit, refill_per_sec: limit / @window_seconds]

  defp deny(conn, retry_after) do
    env = Errors.to_envelope({:error, :rate_limited, %{retry_after: retry_after}}, conn)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end

  defp retry_after_seconds(limit) when is_integer(limit) and limit > 0 do
    max(1, div(@window_seconds + limit - 1, limit))
  end

  defp retry_after_seconds(_), do: @window_seconds
end
