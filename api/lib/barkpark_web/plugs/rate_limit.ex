defmodule BarkparkWeb.Plugs.RateLimit do
  @moduledoc """
  Per-token, method-class, and dataset-aware token-bucket rate limiting.

  Reads (`GET`/`HEAD`) and writes (other verbs) are billed against
  separate buckets. Limits come from
  `config :barkpark, :rate_limits` with per-dataset overrides in
  `datasets: %{"ds" => %{read: N, write: M}}`. A token bucket is keyed on the
  RESOLVED token (`Auth.verify_token/1`), NEVER on the raw Authorization header
  — see `principal_id/1`. Unauthenticated callers, and callers presenting a
  bearer this server cannot resolve to a principal, are bucketed by client IP,
  resolved through `Barkpark.RateLimiter.client_ip/1`
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
      case principal_id(conn) do
        nil ->
          # The trust boundary, NOT the raw peer. Every prod instance runs Caddy
          # on the box dialling localhost:4000, so `conn.remote_ip` is always
          # 127.0.0.1 for anonymous traffic and this bucket was ONE global
          # read/write budget for the entire internet — a single caller starved
          # every other anonymous caller. `client_ip/1` believes the chain only
          # when the peer is a trusted front and takes the rightmost non-proxy
          # hop, so a direct caller still cannot pick its own key.
          "ip:#{RateLimiter.client_ip(conn)}:#{class}:#{scope}"

        token_id ->
          "token:#{token_id}:#{class}:#{scope}"
      end

    case conn.private[:barkpark_rate_limit_scope] do
      test_scope when is_binary(test_scope) -> key <> ":test:" <> test_scope
      _ -> key
    end
  end

  # THE BUCKET KEY MAY ONLY BE DERIVED FROM A VERIFIED PRINCIPAL.
  #
  # This used to be `hash_token(raw)` straight off the Authorization header — a
  # bare :crypto.hash/2 with no verify and no Repo lookup, so the bucket key was
  # a pure function of a string the CALLER writes. Attaching a fresh random
  # bearer to every request minted a fresh full bucket every request, and every
  # throttle downstream of this plug became caller-selectable. It is the exact
  # shape `Barkpark.RateLimiter.client_ip/1` exists to close for the IP half
  # ("a bucket is only a limit if the client cannot choose its own key"), left
  # open on the token half: sanitising or re-hashing an unverified header does
  # not help, because the attacker still chooses among the sanitised values.
  #
  # The blast radius was not just the data API. `pipeline :user_auth` runs this
  # plug as its ONLY meter (router.ex: "RateLimit keys on IP here (anonymous),
  # which is the brute-force defense for login" — which was false the moment a
  # bearer was present), and `POST /v1/auth/request-reset` /
  # `/request-magic-link` each send one email to a caller-named third party per
  # request. `AuthWriteRateLimit` is mounted on `/v1/auth/register` ONLY, so a
  # rotating bearer turned those two routes into an unbounded outbound-mail
  # amplifier and burned the per-account login lockout across every account.
  #
  # So: resolve, or fall back to the IP bucket. `nil` here is not "anonymous",
  # it is "no principal this server has vouched for", which is the same budget
  # an anonymous caller gets — an unresolvable bearer buys the caller nothing.
  #
  # COST, deliberately paid: this adds one indexed `api_tokens.token_hash`
  # lookup per BEARER-carrying request ahead of the meter. On `:api` and its
  # siblings that lookup already happens a few plugs later (`OptionalToken` →
  # `Auth.verify_token/1`), so the marginal cost is one cached index hit; and
  # under the rotating-bearer flood this closes, the attacker used to reach that
  # same lookup unthrottled, so the fix strictly REDUCES the database work a
  # flood can force. It never runs for a request that presents no bearer, which
  # is the whole anonymous surface.
  defp principal_id(conn) do
    case conn.assigns[:api_token] do
      # Free path: a plug ahead of us already resolved this bearer. Nothing in
      # the tree mounts RateLimit after token resolution today, so this is a
      # forward-compatibility branch, not the hot one.
      %Barkpark.Auth.ApiToken{id: id} when is_binary(id) -> id
      _ -> verified_bearer_id(conn)
    end
  end

  defp verified_bearer_id(conn) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         true <- raw != "",
         {:ok, %Barkpark.Auth.ApiToken{id: id}} <- Barkpark.Auth.verify_token(raw) do
      id
    else
      _ -> nil
    end
  rescue
    # The limiter must never be the thing that 500s a request. A database blip
    # (or a test process without sandbox ownership) degrades to the IP bucket —
    # fail-CLOSED in the sense that matters here: the caller gets the SMALLER,
    # unforgeable budget, never a fresh one.
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp retry_after_seconds(per_minute) when is_integer(per_minute) and per_minute > 0 do
    max(1, div(60 + per_minute - 1, per_minute))
  end

  defp retry_after_seconds(_), do: 60
end
