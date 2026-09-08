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

  ## The `:browser` class — SHADOW ONLY (charter D2/D4 Gate A)

  A mount may pass `class: :browser` to meter a browser pipeline. That path is
  LOG-ONLY: a caller past the budget is served its 200, one line is logged, and
  a `would_429` measurement is emitted on `[:barkpark, :rate_limit, :shadow]`
  with `class: :browser` metadata — a DIMENSION on the existing route class,
  never a sixth class (charter D9). It refuses nobody unless a human sets
  `BARKPARK_RATE_LIMIT_BROWSER_ENFORCE=true` against observed shadow data.
  `BARKPARK_RATE_LIMIT_BROWSER_ENABLED=false` is the kill switch and skips the
  bucket entirely. NOTHING mounts this class yet — the router edit is charter
  D7 / slice 8 — so on this commit the class is reachable only from tests.
  """

  import Plug.Conn

  require Logger

  alias Barkpark.{Content.Errors, RateLimiter}

  @read_methods ~w(GET HEAD)

  @shadow_event [:barkpark, :rate_limit, :shadow]

  def init(opts), do: opts

  # THE MOUNT DECIDES THE CLASS, AND SILENCE MEANS "AS BEFORE".
  #
  # Every one of the 14 `plug(BarkparkWeb.Plugs.RateLimit)` lines in router.ex
  # passes NO options, so `opts` is `[]` here and this falls to the method
  # clause below — byte-identical keys, budgets and refusals to what those
  # pipelines got before `:browser` existed. A browser pipeline opts IN with
  # `plug(BarkparkWeb.Plugs.RateLimit, class: :browser)`; that router edit is
  # charter D7/slice 8 work and is deliberately NOT part of this change.
  def call(conn, opts) do
    # ONE `RateLimiter.check/2` CALL SITE, DELIBERATELY.
    # `rate_limiter_scoped_key_coverage_test.exs` walks the AST of every module
    # that meters and pins the census of check/2 call sites (8 across the tree,
    # exactly ONE of them here). A second `check` call for the browser class
    # reds that census — so the browser class differs from the method classes in
    # what it PLANS (budget, key) and what it does when the bucket is empty, and
    # not in how it debits.
    case plan(conn, opts) do
      # The kill switch, and it short-circuits BEFORE any key is built: no
      # bucket is created and check/2 is never reached.
      :skip ->
        conn

      {class, per_minute, key} ->
        case RateLimiter.check(RateLimiter.scoped_key(conn, key), bucket_opts(per_minute)) do
          :ok -> conn
          :rate_limited -> limited(conn, class, key, per_minute)
        end
    end
  end

  # THE MOUNT DECIDES THE CLASS, AND SILENCE MEANS "AS BEFORE".
  #
  # Every one of the 14 `plug(BarkparkWeb.Plugs.RateLimit)` lines in router.ex
  # passes NO options, so `opts` is `[]` here and this falls to the method
  # clause — byte-identical keys, budgets and refusals to what those pipelines
  # got before `:browser` existed. A browser pipeline opts IN with
  # `plug(BarkparkWeb.Plugs.RateLimit, class: :browser)`; that router edit is
  # charter D7 / slice 8 work and is deliberately NOT part of this change.
  defp plan(conn, opts) do
    case class_opt(opts) do
      :browser -> browser_plan(conn)
      _ -> method_plan(conn)
    end
  end

  defp class_opt(opts) when is_list(opts), do: Keyword.get(opts, :class)
  defp class_opt(%{} = opts), do: Map.get(opts, :class)
  defp class_opt(_), do: nil

  defp method_plan(conn) do
    class = method_class(conn.method)
    dataset = conn.path_params["dataset"]
    per_minute = limit_per_minute(class, dataset)
    {class, per_minute, bucket_key(conn, class, dataset)}
  end

  defp browser_plan(conn) do
    cfg = Application.get_env(:barkpark, :rate_limits, [])

    if browser_enabled?(cfg) do
      per_minute = browser_per_minute(cfg)
      {:browser, per_minute, bucket_key(conn, :browser, conn.path_params["dataset"])}
    else
      :skip
    end
  end

  # THE SHADOW PATH — CHARTER D2, AND IT MAY NEVER REFUSE ANYBODY.
  #
  # An empty bucket on the browser class does NOT halt the conn. It logs one
  # line, emits a `would_429` measurement, and returns the conn untouched so the
  # request is served exactly as if no limiter ran. Promotion to enforcing is a
  # separate, explicit human decision against observed shadow data
  # (`:browser_enforce`, default false) — never a side effect of this slice
  # merging. A false-positive 429 on a real reader is the epic's one-way door,
  # and this clause is the door being held shut.
  #
  # `would_429` is a DIMENSION, never a sixth route class (charter D9): the
  # telemetry metadata carries `class: :browser` and the measurement is the
  # counter. Carrying it into RequestStats' per-class objects edits
  # `request_stats.ex`, which is outside this slice's fence; this event is the
  # seam that slice consumes.
  defp limited(conn, :browser, key, per_minute) do
    retry_after = retry_after_seconds(per_minute)

    Logger.warning(
      "rate_limit shadow would_429 class=browser key=#{key} " <>
        "per_minute=#{per_minute} retry_after=#{retry_after} " <>
        "method=#{conn.method} path=#{conn.request_path}"
    )

    :telemetry.execute(
      @shadow_event,
      %{would_429: 1},
      %{class: :browser, key: key, per_minute: per_minute, retry_after: retry_after}
    )

    if browser_enforce?(Application.get_env(:barkpark, :rate_limits, [])) do
      refuse(conn, retry_after)
    else
      conn
    end
  end

  # The 14 API pipelines: unchanged, still a hard refusal.
  defp limited(conn, _class, _key, per_minute), do: refuse(conn, retry_after_seconds(per_minute))

  # Content-negotiated refusal. A browser asking for HTML gets HTML; everything
  # else keeps the JSON envelope the 14 API pipelines have always returned, so
  # this is additive to their behaviour and not a rewrite of it. Both carry
  # `retry-after`. UNREACHABLE on a browser pipeline while `:browser_enforce`
  # is false, which is its default.
  defp refuse(conn, retry_after) do
    conn = put_resp_header(conn, "retry-after", Integer.to_string(retry_after))

    if wants_html?(conn) do
      # Phoenix.Controller.html/2, not send_resp/3: same bytes, and it keeps
      # this module out of Sobelow's XSS.SendResp scan, which flags any
      # non-literal body argument regardless of provenance (the only thing
      # interpolated here is an integer this module computed).
      conn
      |> put_status(429)
      |> Phoenix.Controller.html(html_429(retry_after))
      |> halt()
    else
      env = Errors.to_envelope({:error, :rate_limited, %{retry_after: retry_after}}, conn)

      conn
      |> put_status(env.status)
      |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
      |> halt()
    end
  end

  defp wants_html?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  defp html_429(retry_after) do
    """
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8">
    <title>Too many requests</title></head>
    <body>
    <h1>Too many requests</h1>
    <p>You are reading faster than this server serves. Please retry in
    #{retry_after} second(s).</p>
    </body></html>
    """
  end

  defp method_class(method) when method in @read_methods, do: :read
  defp method_class(_), do: :write

  # Kill switch + budget, same `config :barkpark, :rate_limits` keyword list the
  # read/write budgets already live in, so runtime.exs tunes all three through
  # one BARKPARK_RATE_LIMIT_* block. Shadow is ON by default because a shadow
  # that is off observes nothing; ENFORCE is off by default because D2 says so.
  defp browser_enabled?(cfg), do: Keyword.get(cfg, :browser_enabled, true) != false

  defp browser_enforce?(cfg), do: Keyword.get(cfg, :browser_enforce, false) == true

  defp browser_per_minute(cfg) do
    case Keyword.get(cfg, :browser_per_minute, 600) do
      n when is_integer(n) and n > 0 -> n
      _ -> 600
    end
  end

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

    # The per-test scope suffix used to be appended HERE, and this plug was the
    # ONLY metered surface that honoured it. It now lives in
    # `RateLimiter.scoped_key/2`, applied at the `check/2` call site above
    # exactly as the other seven sites apply it — so `bucket_key/3` returns the
    # production key and one helper owns the seam. The suffix is byte-identical
    # to what the clause removed from here produced.
    key
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
