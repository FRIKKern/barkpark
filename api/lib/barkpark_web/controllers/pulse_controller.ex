defmodule BarkparkWeb.PulseController do
  @moduledoc """
  The Pulse public surface (Shared Storm; design paper `shared-storm`) —
  anonymous, CORS-open, rate-limited. Mounted by the pulse plugin's route
  specs on the `:public_api` bucket at `/v1/plugins/pulse/:channel/…`.

  Auth posture: NONE, by design — the whole point is that any visitor of a
  static page can fire an event. Safety is caps, not identity:

    * unknown channel → 404 (nothing is open unless explicitly configured)
    * strict schema validation + byte ceiling (`Barkpark.Pulse.validate_payload/2`)
    * per-IP token bucket (sustained `rate_per_min`, burst 3)
    * per-channel UTC-day ceiling (`daily_cap`)

  A leaked/scripted client can therefore inflate a vanity counter and noise
  an ephemeral 24h feed — never touch documents, media, or tokens.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Pulse
  alias Barkpark.RateLimiter

  @burst 3

  # POST /v1/plugins/pulse/:channel/events
  def create(conn, %{"channel" => channel} = params) do
    with {:ok, cfg} <- channel_or_404(conn, channel),
         :ok <- check_ip_bucket(conn, channel, cfg),
         :ok <- check_daily_cap(channel, cfg),
         {:ok, clean} <- Pulse.validate_payload(cfg, Map.drop(params, ["channel"])),
         {:ok, %{id: id, total: total}} <- Pulse.record_event(channel, clean) do
      # realtime: every subscriber on the channel's topic gets the strike
      # pushed the moment it lands — polling is only the fallback transport
      BarkparkWeb.Endpoint.broadcast("pulse:" <> channel, "strike", %{
        id: id,
        payload: clean,
        total: total
      })

      json(conn, %{ok: true, id: id, total: total})
    else
      {:halted, conn} -> conn
      {:rate_limited, retry_after} -> rate_limited(conn, retry_after)
      {:error, reason} when is_binary(reason) -> bad_request(conn, reason)
      {:error, _} -> bad_request(conn, "could not record event")
    end
  end

  # GET /v1/plugins/pulse/:channel/recent?since=<cursor>&limit=<n>
  def recent(conn, %{"channel" => channel} = params) do
    case channel_or_404(conn, channel) do
      {:ok, _cfg} ->
        since = parse_int(params["since"], 0)
        limit = parse_int(params["limit"], 100)
        json(conn, Pulse.recent(channel, since, limit))

      {:halted, conn} ->
        conn
    end
  end

  # GET /v1/plugins/pulse/:channel/stats
  def stats(conn, %{"channel" => channel}) do
    case channel_or_404(conn, channel) do
      {:ok, _cfg} -> json(conn, Pulse.stats(channel))
      {:halted, conn} -> conn
    end
  end

  # OPTIONS preflights never reach here — PublicCors halts them with a 204.
  # Declared so the router has an action for the {:options, …} specs.
  def preflight(conn, _params), do: send_resp(conn, 204, "")

  # ── Gates ─────────────────────────────────────────────────────────────

  defp channel_or_404(conn, channel) do
    case Pulse.channel(channel) do
      {:ok, cfg} ->
        {:ok, cfg}

      :error ->
        {:halted,
         conn
         |> put_status(:not_found)
         |> json(%{error: %{code: "not_found", message: "unknown pulse channel"}})}
    end
  end

  defp check_ip_bucket(conn, channel, cfg) do
    rate = cfg["rate_per_min"]

    case RateLimiter.check({:pulse, client_ip(conn), channel},
           capacity: @burst,
           refill_per_sec: rate / 60
         ) do
      :ok -> :ok
      :rate_limited -> {:rate_limited, max(1, ceil(60 / rate))}
    end
  end

  defp check_daily_cap(channel, cfg) do
    if Pulse.count_today(channel) < cfg["daily_cap"],
      do: :ok,
      else: {:rate_limited, 3600}
  end

  # RemoteIp-style header awareness is deliberately minimal: trust the first
  # x-forwarded-for hop when present (Caddy fronts prod), else the peer.
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] -> forwarded |> String.split(",") |> hd() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  # ── Responses ─────────────────────────────────────────────────────────

  defp rate_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:too_many_requests)
    |> json(%{error: %{code: "rate_limited", message: "slow down", retry_after: retry_after}})
  end

  defp bad_request(conn, reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "invalid_event", message: reason}})
  end

  defp parse_int(nil, default), do: default

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_int(v, _default) when is_integer(v) and v >= 0, do: v
  defp parse_int(_, default), do: default
end
