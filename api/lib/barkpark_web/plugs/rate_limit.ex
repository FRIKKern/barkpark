defmodule BarkparkWeb.Plugs.RateLimit do
  @moduledoc """
  Per-token, method-class, and dataset-aware token-bucket rate limiting.

  Reads (`GET`/`HEAD`) and writes (other verbs) are billed against
  separate buckets. Limits come from
  `config :barkpark, :rate_limits` with per-dataset overrides in
  `datasets: %{"ds" => %{read: N, write: M}}`. Unauthenticated callers
  are bucketed by client IP, resolved through `Barkpark.RateLimiter.client_ip/1`
  — never `conn.remote_ip`, which behind the co-located Caddy is ALWAYS
  loopback and collapsed the whole anonymous internet into one shared bucket.
  """

  import Plug.Conn

  alias Barkpark.{Content.Errors, RateLimiter}

  @read_methods ~w(GET HEAD)

  def init(opts), do: opts

  def call(conn, _opts) do
    class = method_class(conn.method)
    dataset = conn.path_params["dataset"]
    per_minute = limit_per_minute(class, dataset)
    bucket_opts = bucket_opts(per_minute)
    key = bucket_key(conn, class, dataset)

    case RateLimiter.check(key, bucket_opts) do
      :ok ->
        conn

      :rate_limited ->
        retry_after = retry_after_seconds(per_minute)
        env = Errors.to_envelope({:error, :rate_limited, %{retry_after: retry_after}}, conn)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(env.status)
        |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
        |> halt()
    end
  end

  defp method_class(method) when method in @read_methods, do: :read
  defp method_class(_), do: :write

  defp limit_per_minute(class, dataset) do
    cfg = Application.get_env(:barkpark, :rate_limits, [])
    default = default_per_minute(cfg, class)

    case dataset_override(cfg, dataset, class) do
      nil -> default
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp default_per_minute(cfg, :read), do: Keyword.get(cfg, :read_per_minute, 300)
  defp default_per_minute(cfg, :write), do: Keyword.get(cfg, :write_per_minute, 60)

  defp dataset_override(_cfg, nil, _class), do: nil

  defp dataset_override(cfg, dataset, class) do
    ds_map = Keyword.get(cfg, :datasets, %{}) || %{}

    case Map.get(ds_map, dataset) do
      %{} = overrides -> Map.get(overrides, class)
      _ -> nil
    end
  end

  defp bucket_opts(per_minute) do
    [capacity: per_minute, refill_per_sec: per_minute / 60.0]
  end

  defp bucket_key(conn, class, dataset) do
    scope = dataset || "global"

    key =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> raw] ->
          token_id = Barkpark.Auth.ApiToken.hash_token(raw)
          "token:#{token_id}:#{class}:#{scope}"

        _ ->
          # The trust boundary, NOT the raw peer. Every prod instance runs Caddy
          # on the box dialling localhost:4000, so `conn.remote_ip` is always
          # 127.0.0.1 for anonymous traffic and this bucket was ONE global
          # read/write budget for the entire internet — a single caller starved
          # every other anonymous caller. `client_ip/1` believes the chain only
          # when the peer is a trusted front and takes the rightmost non-proxy
          # hop, so a direct caller still cannot pick its own key.
          "ip:#{RateLimiter.client_ip(conn)}:#{class}:#{scope}"
      end

    RateLimiter.scope_key(conn, key)
  end

  defp retry_after_seconds(per_minute) when is_integer(per_minute) and per_minute > 0 do
    max(1, div(60 + per_minute - 1, per_minute))
  end

  defp retry_after_seconds(_), do: 60
end
