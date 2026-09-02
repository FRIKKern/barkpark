defmodule BarkparkWeb.Plugs.RateLimit do
  @moduledoc """
  Per-token, method-class, and dataset-aware token-bucket rate limiting.

  Reads (`GET`/`HEAD`) and writes (other verbs) are billed against
  separate buckets. Limits come from
  `config :barkpark, :rate_limits` with per-dataset overrides in
  `datasets: %{"ds" => %{read: N, write: M}}`. A credential bucket is keyed on a
  RESOLVED token id — api_token or SCIM token, see `@principal_resolvers` —
  NEVER on the raw Authorization header. Unauthenticated callers, and callers
  presenting a bearer no resolver can verify, are bucketed by client IP,
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

  # THE BUCKET KEY MAY ONLY BE DERIVED FROM A VERIFIED PRINCIPAL — AND EVERY
  # CREDENTIAL KIND THIS PLUG METERS NEEDS A RESOLVER IN THE LIST BELOW.
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
  # THE HALF THAT IS EASY TO GET WRONG, and did get shipped wrong once: falling
  # back to the IP bucket for everything `Auth.verify_token/1` cannot resolve
  # treats "a credential of a DIFFERENT kind" as "no credential at all". A SCIM
  # bearer is a `Barkpark.Scim.Token`, not an `ApiToken`, so `pipeline :scim`
  # (which meters BEFORE `RequireScimToken` resolves anything) collapsed an
  # entire IdP's provisioning traffic — many requests from one egress address is
  # SCIM's normal operating mode — into the anonymous per-IP budget. 18 SCIM
  # tests went 429. `verify_token/1` is the resolver for ONE credential kind,
  # not the definition of "verified".
  #
  # So the invariant is two-sided, and both sides are load-bearing:
  #
  #   * a VERIFIED identity of ANY kind keys its own bucket;
  #   * the IP bucket is for callers who presented no identity this server can
  #     verify at all — an unresolvable bearer buys them nothing.
  #
  # @principal_resolvers IS THE REGISTRY. A new bearer-shaped credential kind
  # metered by this plug adds a line HERE, and
  # `RateLimitPrincipalCoverageTest` reds until it does: that test reads the
  # router, finds every pipeline mounting this plug, and refuses any credential
  # plug it does not know a resolver for. Order is cheapest-and-commonest
  # first; each is an indexed hash lookup and the first hit wins.
  #
  # Non-Bearer schemes are out of scope by construction and always were:
  # `PreviewToken` reads `Authorization: Preview <jwt>` and `RequireChatHost`
  # reads `Authorization: Host <cred>`, so neither ever matched this clause,
  # before the fix or after it. They key on IP, as they did on main.
  #
  # COST, deliberately paid: up to one indexed `token_hash` lookup per resolver
  # per BEARER-carrying request, ahead of the meter. A LIVE credential stops at
  # its own resolver (one lookup for an api_token, two for a SCIM token); only a
  # bearer that resolves to nothing pays the full list. On `:api` and its
  # siblings the api_token lookup already happens a few plugs later
  # (`OptionalToken` → `Auth.verify_token/1`), so the marginal cost there is one
  # cached index hit — and under the rotating-bearer flood this closes, the
  # attacker used to reach that same lookup unthrottled with no limit ever
  # binding, so the change still REDUCES the database work a flood can force.
  # None of it runs for a request that presents no bearer, which is the whole
  # anonymous surface.
  @principal_resolvers [
    # kind, {module, function} resolving a raw bearer to a stable id or nil.
    # The kind is part of the bucket key, so ids from two credential tables can
    # never collide into one bucket.
    {"api", {Barkpark.Auth, :verify_token_id}},
    {"scim", {Barkpark.Scim, :resolve_token_id}}
  ]

  defp principal_id(conn) do
    case conn.assigns[:api_token] do
      # Free path: a plug ahead of us already resolved this bearer. Nothing in
      # the tree mounts RateLimit after token resolution today, so this is a
      # forward-compatibility branch, not the hot one.
      %Barkpark.Auth.ApiToken{id: id} when is_binary(id) -> "api:" <> id
      _ -> verified_bearer_id(conn)
    end
  end

  defp verified_bearer_id(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] when byte_size(raw) > 0 -> resolve(raw, @principal_resolvers)
      _ -> nil
    end
  end

  defp resolve(_raw, []), do: nil

  defp resolve(raw, [{kind, {mod, fun}} | rest]) do
    case apply(mod, fun, [raw]) do
      id when is_binary(id) -> kind <> ":" <> id
      _ -> resolve(raw, rest)
    end
  rescue
    # The limiter must never be the thing that 500s a request. A database blip
    # (or a test process without sandbox ownership) degrades to the IP bucket —
    # fail-CLOSED in the sense that matters here: the caller gets the SMALLER,
    # unforgeable budget, never a fresh one. Scoped to ONE resolver so a broken
    # one does not mask the rest.
    _ -> resolve(raw, rest)
  catch
    :exit, _ -> resolve(raw, rest)
  end

  defp retry_after_seconds(per_minute) when is_integer(per_minute) and per_minute > 0 do
    max(1, div(60 + per_minute - 1, per_minute))
  end

  defp retry_after_seconds(_), do: 60
end
