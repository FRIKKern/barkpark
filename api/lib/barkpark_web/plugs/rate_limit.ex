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

  A caller with no Bearer but a valid SESSION COOKIE (`session["api_token"]`
  or `session["user_session"]`) resolves its OWN bucket too, keyed distinctly
  from both the Bearer and IP cases -- see `session_principal_id/1`
  (task-2c31de0cf6597d32). That bucket's WRITE budget defaults to
  `:session_write_per_minute` (180/min) rather than `:write_per_minute`
  (60/min): a server-side proxy fronting many human editors through one
  egress IP and/or one shared credential (Barkpark Studio) otherwise collapses
  every editor into one 60/min bucket the moment two of them type at once.
  Bearer/SCIM/anonymous budgets are untouched by this -- only a resolved
  SESSION principal ever sees the wider default.

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

  # No interpolation, by design — see `browser_refuse/2`. The retry interval
  # travels in the `retry-after` header, which is where a client reads it.
  @html_429 """
  <!DOCTYPE html>
  <html lang="en"><head><meta charset="utf-8">
  <title>Too many requests</title></head>
  <body>
  <h1>Too many requests</h1>
  <p>You are reading faster than this server serves. Please retry after the
  interval given in this response's Retry-After header.</p>
  </body></html>
  """

  def init(opts), do: opts

  # THE MOUNT DECIDES THE CLASS, AND SILENCE MEANS "AS BEFORE".
  #
  # Every `plug(BarkparkWeb.Plugs.RateLimit)` line in router.ex
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
  # Every `plug(BarkparkWeb.Plugs.RateLimit)` line in router.ex
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
    {principal_class, key} = bucket_key(conn, class, dataset)
    per_minute = limit_per_minute(class, dataset, principal_class)
    {class, per_minute, key}
  end

  defp browser_plan(conn) do
    cfg = Application.get_env(:barkpark, :rate_limits, [])

    if browser_enabled?(cfg) do
      per_minute = browser_per_minute(cfg)
      {_principal_class, key} = bucket_key(conn, :browser, conn.path_params["dataset"])
      {:browser, per_minute, key}
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
      browser_refuse(conn, retry_after)
    else
      conn
    end
  end

  # THE 14 API PIPELINES: UNCHANGED, AND THAT MEANS THE BYTES TOO.
  #
  # This clause reaches `json_refuse/2` DIRECTLY, never the negotiating
  # `browser_refuse/2`. The first draft of this slice routed both classes
  # through one negotiating helper, and the comment here said "unchanged, still
  # a hard refusal" — true about WHETHER these pipelines refuse, false about
  # WHAT they return: an API caller sending `Accept: text/html` (every browser,
  # and curl with browser headers) started getting `<!DOCTYPE html>` where a
  # documented JSON envelope had always been. Charter D4 scopes the content
  # negotiation to the NEW `:browser` class — it is a property of that class,
  # not of refusal in general. `rate_limit_browser_shadow_test.exs` pins that
  # `Accept` has NO influence on a `:read`/`:write` refusal.
  defp limited(conn, _class, _key, per_minute),
    do: json_refuse(conn, retry_after_seconds(per_minute))

  # Content-negotiated refusal — REACHABLE ONLY FROM THE `:browser` CLASS, and
  # only once a human has set `:browser_enforce`. A browser asking for HTML gets
  # HTML; anything else on that class falls through to the same JSON envelope
  # the API classes use, so there is exactly one refusal body shape per
  # (class, accept) pair and no third one hiding in here.
  defp browser_refuse(conn, retry_after) do
    if wants_html?(conn) do
      # THE BODY IS A COMPILE-TIME LITERAL, AND THAT IS THE POINT.
      #
      # It used to interpolate `retry_after`, which made the argument to
      # `html/2` a runtime-computed binary — and Sobelow's XSS.HTML flags any
      # non-literal body regardless of provenance, so this module reddened the
      # Sobelow regression gate. An advisory red still TRANSFERS to main on
      # merge and becomes the next lane's inherited red, so "it blocks nothing"
      # was never a reason to ship it.
      #
      # Nothing is lost. Charter D4 asks for a content-negotiated HTML 429
      # "+ Retry-After", and Retry-After IS the header set on the line below —
      # the integer never needed to appear in the body. The page points the
      # reader at that header instead, which is the value a client should
      # actually obey.
      conn
      |> put_resp_header("retry-after", Integer.to_string(retry_after))
      |> put_status(429)
      |> Phoenix.Controller.html(@html_429)
      |> halt()
    else
      json_refuse(conn, retry_after)
    end
  end

  # THE PRE-BROWSER REFUSAL, MOVED AND NOT REWRITTEN. Byte-for-byte what
  # `call/2` did on main for a `:read`/`:write` 429: the `retry-after` header,
  # the `Errors.to_envelope` status, and the `%{error: …}` JSON body. It reads
  # nothing off the request, so no `Accept` value can change its output.
  defp json_refuse(conn, retry_after) do
    env = Errors.to_envelope({:error, :rate_limited, %{retry_after: retry_after}}, conn)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end

  defp wants_html?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
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

  # `principal_class` (`:session` | `:verified` | `:anonymous`, from
  # `bucket_key/3`) only ever widens the WRITE default, and only for a bucket
  # keyed on an editor's OWN resolved session (task-2c31de0cf6597d32: Studio
  # proxies many editors through one server-side credential/egress IP, so
  # without this every editor shared one 60/min bucket). A dataset override,
  # when set, still wins outright — an operator clamping a specific dataset's
  # abuse ceiling means it regardless of who is asking. api_token/scim/
  # anonymous(IP) traffic is UNCHANGED: default_per_minute/3 only branches on
  # `:session`, so every other principal_class keeps the exact byte-identical
  # :write_per_minute default this function always returned.
  defp limit_per_minute(class, dataset, principal_class) do
    cfg = Application.get_env(:barkpark, :rate_limits, [])
    default = default_per_minute(cfg, class, principal_class)

    case dataset_override(cfg, dataset, class) do
      nil -> default
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp default_per_minute(cfg, :read, _principal_class),
    do: Keyword.get(cfg, :read_per_minute, 300)

  defp default_per_minute(cfg, :write, :session) do
    case Keyword.get(cfg, :session_write_per_minute, 180) do
      n when is_integer(n) and n > 0 -> n
      _ -> Keyword.get(cfg, :write_per_minute, 60)
    end
  end

  defp default_per_minute(cfg, :write, _principal_class),
    do: Keyword.get(cfg, :write_per_minute, 60)

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

  # Returns `{principal_class, key}` — the class feeds `limit_per_minute/3`
  # (ONLY `:session` ever widens a budget; see there), the key is what
  # `check/2` debits exactly as before.
  defp bucket_key(conn, class, dataset) do
    scope = dataset || "global"

    {principal_class, key} =
      case principal_id(conn) do
        nil ->
          # The trust boundary, NOT the raw peer. Every prod instance runs Caddy
          # on the box dialling localhost:4000, so `conn.remote_ip` is always
          # 127.0.0.1 for anonymous traffic and this bucket was ONE global
          # read/write budget for the entire internet — a single caller starved
          # every other anonymous caller. `client_ip/1` believes the chain only
          # when the peer is a trusted front and takes the rightmost non-proxy
          # hop, so a direct caller still cannot pick its own key.
          {:anonymous, "ip:#{RateLimiter.client_ip(conn)}:#{class}:#{scope}"}

        {:session, token_id} ->
          {:session, "token:#{token_id}:#{class}:#{scope}"}

        token_id ->
          {:verified, "token:#{token_id}:#{class}:#{scope}"}
      end

    # The per-test scope suffix used to be appended HERE, and this plug was the
    # ONLY metered surface that honoured it. It now lives in
    # `RateLimiter.scoped_key/2`, applied at the `check/2` call site above
    # exactly as the other seven sites apply it — so `bucket_key/3` returns the
    # production key and one helper owns the seam. The suffix is byte-identical
    # to what the clause removed from here produced.
    {principal_class, key}
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

  # Returns a bare id/kind-string for a `:verified` (Bearer-resolved) principal,
  # `{:session, id}` for a session-cookie-resolved one, or nil for anonymous.
  # The `{:session, _}` wrapper is how `bucket_key/3` tells the two apart —
  # a Bearer-presenting caller is `:verified` even if ITS token also happens to
  # ride a cookie elsewhere, because the Bearer branch always wins here first
  # (same precedence `OptionalSessionToken` documents for token resolution).
  defp principal_id(conn) do
    case conn.assigns[:api_token] do
      # Free path: a plug ahead of us already resolved this bearer. Nothing in
      # the tree mounts RateLimit after token resolution today, so this is a
      # forward-compatibility branch, not the hot one.
      %Barkpark.Auth.ApiToken{id: id} when is_binary(id) -> "api:" <> id
      _ -> verified_bearer_id(conn) || session_principal_id(conn)
    end
  end

  defp verified_bearer_id(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] when byte_size(raw) > 0 -> resolve(raw, @principal_resolvers)
      _ -> nil
    end
  end

  # THE SESSION HALF OF THE SAME INVARIANT — task-2c31de0cf6597d32.
  #
  # Every `:scoped_mutate`-shaped pipeline mounts RateLimit BEFORE the plug
  # that would actually resolve a session cookie (OptionalSessionToken /
  # RequireBearerOrSessionToken), for the same cheapest-first reason Bearer
  # resolution happens here instead of downstream. Left unresolved, a
  # session-cookie-only caller fell to the anonymous IP bucket — harmless for
  # one browser, but Barkpark Studio proxies MANY editors through one
  # server-side egress IP (and, before #22180, one shared Bearer token), so
  # every editor shared one write budget either way. Resolving the session
  # here, exactly like the Bearer branch above, gives each editor's own
  # credential its own bucket.
  #
  # Two session shapes, same precedence `OptionalSessionToken.call/2` already
  # uses (token wins when present): `session["api_token"]` (Studio's
  # token-sign-in cookie, `/login`) resolves through the SAME indexed
  # `Auth.verify_token_id/1` the Bearer branch already pays for — no new cost
  # shape. `session["user_session"]` (an account/SSO login, task-27006bc4)
  # resolves through `Accounts.verify_user_session/1`, which also runs again
  # downstream in `OptionalSessionToken` once that plug mounts — doubling one
  # lookup, the same price the Bearer branch already pays when `:api`'s
  # `OptionalToken` re-resolves the same token a few plugs later.
  #
  # `get_session/2` raises when `:fetch_session` has not run yet. Only the
  # `:scoped_mutate`/`:scoped_media_mutate`-shaped pipelines that mount
  # `:fetch_session` ahead of RateLimit can ever carry a session cookie worth
  # reading, so a conn without one simply has nothing to read — rescued, not
  # special-cased, so a pipeline ordering change can never 500 a request here.
  defp session_principal_id(conn) do
    case session_value(conn, "api_token") do
      raw when is_binary(raw) and raw != "" ->
        case Barkpark.Auth.verify_token_id(raw) do
          id when is_binary(id) -> {:session, "api:" <> id}
          _ -> session_user_principal_id(conn)
        end

      _ ->
        session_user_principal_id(conn)
    end
  end

  defp session_user_principal_id(conn) do
    case session_value(conn, "user_session") do
      raw when is_binary(raw) and raw != "" ->
        case Barkpark.Accounts.verify_user_session(raw) do
          {%Barkpark.Accounts.User{id: id}, _session} when is_binary(id) ->
            {:session, "user:" <> id}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp session_value(conn, key) do
    get_session(conn, key)
  rescue
    # No :fetch_session upstream on this pipeline — nothing to read, same as
    # an absent cookie. See the moduledoc comment above session_principal_id/1.
    ArgumentError -> nil
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
