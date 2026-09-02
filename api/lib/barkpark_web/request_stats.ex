defmodule BarkparkWeb.RequestStats do
  @moduledoc """
  Rolling per-request throughput + latency aggregator for the Phoenix instance,
  widened (anonymous-metering W1, charter D9/D10/D11) into the program's
  baseline instrument: every sample now carries a **route class** and a
  **three-valued auth state**, and the read shape states per-class anonymous
  read rates WITH volume.

  Phoenix's `Plug.Telemetry` (endpoint.ex:75) emits `[:phoenix, :endpoint, :stop]`
  with a `%{duration: native}` measurement on every request it sees, and hands
  this handler the conn as `meta`. The handler keeps a bounded ~60s rolling
  window of samples in an ETS ring and derives:

    * `req_per_s` — request count over the window divided by the *elapsed* window
      (`min(uptime, window)`), so a box that booted 5s ago reports an honest rate
      instead of dividing by a full 60s it has not lived through yet.
    * `p95_ms`   — the 95th-percentile request duration (nearest-rank) in ms, or
      `nil` when the window is empty. Zero samples is **not** `0ms` — a fabricated
      floor would be a lie. It is the honest `null`, and `BarkparkWeb.RequestStatsTest`
      is what holds it there.
    * `err_5xx_per_s` — 5xx responses over the same window, over the same elapsed
      seconds, or `nil` when the window is empty. **Same law, and it bites harder
      here:** an empty window rendered as `0.0` reads "this box is serving no
      errors", which is the single most reassuring sentence a meter can print and
      is a lie whenever it is printed about a box nobody has measured.
    * `count` — the raw number of samples in the window. Rate without volume is
      the D3-illegal half-sentence; `count` is what makes "12.4 req/s over 87
      requests" sayable.
    * `elapsed_s` — the elapsed seconds the rates were divided by
      (`min(uptime, window)`), so a reader can reconstruct the division.
    * `sampled_at` — UTC wall-clock at read time, stamping WHEN the window was
      observed (the window itself runs on monotonic time).
    * `classes` — per-route-class breakdown, `%{class => %{count, req_per_s,
      authed, anon, auth_unknown}}`; `%{}` on an empty window (no fabricated
      zero-rows for classes nobody observed).

  ## Route classes — enum CLOSED at five (charter D9)

    * `:lv_dead`    — `conn.private[:phoenix_live_view]` present: a LiveView
      dead (HTTP) render.
    * `:browser`    — routed HTML, non-LiveView.
    * `:api`        — routed JSON.
    * `:unrouted`   — `:phoenix_router` present but `Phoenix.Router.route_info/4`
      returns `:error`: the router ran and matched nothing (where crawler storms
      land as 404s).
    * `:pre_router` — `:phoenix_router` absent: halted upstream of the router
      (PublicShareGuard, body parsing, CORS) — or a synthetic emit with no conn.

  `Phoenix.Router.route_info/4` is the ONLY door to a conn's `pipe_through`
  (`:phoenix_route` never exists on the conn); `:public_root` is a scope tag,
  not a pipeline. Cost note: `route_info/4` re-runs the compiled router match
  once per request on the hot write path — a compiled pattern match,
  microseconds, no DB.

  **BLINDNESS — two traffic shapes this meter can NEVER see** (documented
  non-classes, not bugs):

    * `static_served` — `Plug.Static` (endpoint.ex, `plug Plug.Static`) halts
      BEFORE `Plug.Telemetry` (endpoint.ex, `plug Plug.Telemetry`), so a
      served static file emits ZERO
      stop events. Static hits are structurally invisible here (L1-proven on
      the live box: static 200s moved nothing).
    * `lv_connected` — LiveView socket dispatch precedes all user plugs; even a
      400/403 websocket handshake is invisible. A `check_origin` 403 storm
      never appears on this meter.

  ## Auth — three-valued by PIPELINE COVERAGE (charter D11)

  Never assign absence. Per sample:

    * `:authed`       — `conn.assigns[:api_token]` present at stop.
    * `:anon`         — token absent AND the route's `pipe_through` intersects
      `@auth_resolving_pipelines` (the pipelines that run a plug assigning
      `:api_token`: OptionalToken / RequireToken / OptionalSessionToken /
      RequireBearerOrSessionToken). An auth-resolving plug ran and resolved
      nothing — that IS anonymous. An invalid Bearer on such a pipeline counts
      as anon (OptionalToken assigns nothing for it).
    * `:auth_unknown` — token absent AND no `:api_token`-resolving plug ran.
      Bare `:browser` runs none, and LV identity resolves on the socket — so
      `lv_dead`/`browser` honestly report `auth_unknown` for nearly all
      traffic, by design. A signed-in browser session's dead render is
      `auth_unknown`, and no anon counter may move for it. Pipelines that
      resolve OTHER principals (`:scim`, `:ingest`, `:ticket_key`,
      `:api_preview`, user sessions) are deliberately NOT in the allowlist:
      their callers may be authenticated without `:api_token`, so counting
      them anon would assign absence.

  **HONEST BOUND — read this before trusting the field.** The window is 60s and
  the ring lives in THIS slot's BEAM: it dies on every blue/green flip and reads
  an empty window for the first minute after boot. It answers "is this box
  answering 5xx *right now*" and can never produce a cumulative "N since
  Tuesday" — that is a journal- or Postgres-backed instrument and is not this
  one. It is also blind to any 5xx the BEAM never served: a Caddy 502/504 while
  the VM is unresponsive is invisible here, which is exactly the total-outage
  case. A `0.0` from this meter is not proof the box is answering.

  The write path (the telemetry handler) inserts straight into a public ETS
  table so high request rates never serialize through the process mailbox; the
  read path (`stats/1`) is a `GenServer.call` because reads are rare (the on-box
  agent polls the exposed route on its beat, sibling slice
  `cloud-console-w5-agent-reqstats-beat`). A timer prunes expired rows so memory
  stays bounded to roughly one window's worth of samples.

  The read shape — the additive 8-key map `%{req_per_s, p95_ms, err_5xx_per_s,
  window_s, count, elapsed_s, sampled_at, classes}` — is pinned on the wire by
  `BarkparkWeb.RequestStatsControllerTest` and in the pure math by
  `BarkparkWeb.RequestStatsTest`. Those two tests are the contract; a charter
  letter is not, because charters are rewritten per wave and the code does not
  follow.

  D13 note: the route comment at `router.ex:1603-1613` still enumerates the
  pre-class four-key shape. It is stale-benign, is refreshed by slice 8
  (am-w2-s8-router-pipeline-lines), and router.ex must NOT be edited from this
  module's slices.
  """

  use GenServer

  @window_ms 60_000
  @prune_every_ms 10_000
  @default_table :barkpark_request_stats

  # The pipelines that run a plug which assigns `:api_token` on success
  # (OptionalToken / RequireToken / OptionalSessionToken /
  # RequireBearerOrSessionToken). This is the D11 auth-resolving allowlist:
  # a token-absent sample is `:anon` ONLY when its route's pipe_through
  # intersects this set — otherwise no auth plug ran and the honest value is
  # `:auth_unknown`. Same-file pin: `BarkparkWeb.RequestStatsTest` pins this
  # list verbatim so drift is deliberate, never accidental.
  @auth_resolving_pipelines ~w(
    access_principal
    api
    cycle_api
    flat_admin_api
    media_mutate
    require_admin
    require_chat_access
    require_chat_host_admin
    require_token
    scoped_admin
    scoped_api
    scoped_browser
    scoped_media_mutate
    scoped_mutate
    session_token_root
    shared_docs_api
    shared_media_api
    shared_paper_browser
    shared_studio_browser
    soft_token
  )a

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The D11 auth-resolving pipeline allowlist (see the moduledoc). Exposed so the
  pin test can hold the list still.
  """
  def auth_resolving_pipelines, do: @auth_resolving_pipelines

  @doc """
  Current window stats — the additive 8-key map `%{req_per_s: float,
  p95_ms: integer | nil, err_5xx_per_s: float | nil, window_s: integer,
  count: non_neg_integer, elapsed_s: float, sampled_at: String.t(),
  classes: %{atom => map}}`.

  Falls back to an honest empty window (`req_per_s: 0.0`, `p95_ms: nil`,
  `err_5xx_per_s: nil`, `count: 0`, `classes: %{}`) if the aggregator process
  is not running, so the exposed route degrades to the truth rather than
  500-ing. Note which one is `0.0`: no requests observed IS a true rate of zero
  requests, but "no 5xx observed" is unknowable from a window that holds
  nothing.
  """
  def stats(name \\ __MODULE__) do
    GenServer.call(name, :stats)
  catch
    :exit, _ ->
      now = now_ms()
      compute([], now, now, @window_ms) |> put_sampled_at()
  end

  # ── Telemetry handler (write path — runs in the request process) ──────────

  # ── CITED SAFE — this is a METER, not an admission bound (sibling-ETS
  # atomicity wave, 2026-08-19). Read this before re-deriving it.
  #
  # This module was swept as a candidate sibling of the `Barkpark.RateLimiter`
  # defect closed by #12579 (`:ets.lookup` then an unconditional `:ets.insert`,
  # so N concurrent callers read the SAME bucket state and are all admitted —
  # fail-OPEN under contention). It is not that shape, on two grounds that hold
  # independently:
  #
  # (a) KEY SHAPE — there is no read-modify-write to lose. The write below is a
  #     SINGLE `:ets.insert` keyed `{System.monotonic_time(:millisecond),
  #     System.unique_integer([:monotonic])}`, with NO preceding `:ets.lookup`.
  #     `unique_integer([:monotonic])` is VM-unique, so two concurrent inserts
  #     can never collide on a key and overwrite one another, and nothing is
  #     computed from previously-read state. Structurally not #12579's shape,
  #     before any argument about consequences.
  #
  # (b) CONSUMER CENSUS — nothing admits, denies or sheds on any value here.
  #     In-tree, non-test: `application.ex` (child spec, not a reader),
  #     `router.ex` (mounts GET /v1/instance/request-stats behind `[:api,
  #     :require_token]`), and `request_stats_controller.ex` — the ONLY reader,
  #     and it is `json(conn, RequestStats.stats())`: no branch, no status
  #     choice, no halt, no throttle. `metrics_controller.ex` and
  #     `instance_site_deploy_controller.ex` mention the route in prose only.
  #     No Studio LiveView, no HEEx, no component, no plug, no worker, no
  #     in-process JS/Go reader.
  #     Off box, the whole chain, so nobody re-derives it: Go agent
  #     `ReqStatsProbe` (internal/agent/report.go) -> cloud health beat
  #     (`req_per_s`, `p95_ms`, `err_5xx_per_s`, landed as VITALS in
  #     cloud/lib/barkpark_cloud/web/router.ex — p95 explicitly REFUSED as a
  #     fence, charter D131) -> `Usage.telemetry_threshold_meter(..., nil, warn,
  #     over)`, whose quota argument is `nil`, so those meters TINT and draw no
  #     bar. The only enforced meter in that module is `instances`, gated
  #     elsewhere by `Billing.barkpark_limit/1` off team plan, not off this
  #     beat. `grep -rn over_at cloud/lib` outside `usage.ex` returns zero: no
  #     alerting, no autoscaling, no load-shedding reads these numbers. A lost
  #     sample is cosmetic — the `rescue _ -> :ok` below already drops one by
  #     design.
  #
  # THE PRUNE, as a complement rather than an assertion: `handle_info(:prune, _)`
  # deletes rows STRICTLY older than `now_ms() - @window_ms`; `compute/4` keeps
  # rows at or newer than the same cutoff, off the SAME monotonic clock, which
  # never rewinds. A later read's cutoff is therefore always at or beyond the
  # prune's, so prune can only delete rows the next read would already have
  # excluded. The residual hazard is UNDER-deletion (a leak, if the match head's
  # arity ever narrows — see the note at `handle_info(:prune, _)`), never
  # dropping a live sample. And since no bound reads a sample, "drops a sample a
  # bound depends on" has an empty referent.
  #
  # WHAT THIS VERDICT DOES NOT REST ON: the earlier Felix "already-good" stamp.
  # That stamp graded this module on OTP/throughput grounds (an ETS write path
  # that never serializes through the mailbox) — the exact reading a prior wave
  # OVERTURNED for `Barkpark.RateLimiter`, where same-key contention was read as
  # throughput and never as correctness, leaving a standing verified-no-change
  # stamp on a defective function. The two grounds above are key shape and
  # consumer census; neither leans on that stamp.
  #
  # `meta` is the conn Phoenix has always handed this handler. `conn.status` is
  # the 5xx meter (D75); the route class + auth state (D9/D11) ride the same
  # event — no new event, no second table, one `route_info/4` match on the
  # request path. The head stays permissive (a bare `meta`): a synthetic emit
  # without a conn is classified defensively inside, never crashed on.
  @doc false
  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, meta, %{table: table}) do
    duration_ms = System.convert_time_unit(duration, :native, :microsecond) / 1000
    key = {System.monotonic_time(:millisecond), System.unique_integer([:monotonic])}
    {route_class, auth_state} = classify(meta)
    :ets.insert(table, {key, duration_ms, status_of(meta), route_class, auth_state})
    :ok
  rescue
    # A telemetry handler must NEVER take down the request it is measuring — a
    # missing table (process restarting) or any surprise degrades to a no-op.
    _ -> :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  # The response status out of the telemetry metadata. Phoenix passes
  # `%{conn: conn}`; anything else (a synthetic emit, a conn that never got a
  # status) is `nil` — unknown, and unknown is never counted as an error and
  # never counted as a success.
  defp status_of(%{conn: %Plug.Conn{status: status}}) when is_integer(status), do: status
  defp status_of(_), do: nil

  @doc """
  Classify a stop-event `meta` into `{route_class, auth_state}` (charter D9/D11
  — see the moduledoc for both enums). Total: any meta shape without a conn is
  `{:pre_router, :auth_unknown}` — no router ran, no auth plug ran.
  """
  def classify(%{conn: %Plug.Conn{} = conn}) do
    case conn.private do
      %{phoenix_router: router} ->
        case Phoenix.Router.route_info(router, conn.method, conn.request_path, conn.host) do
          :error ->
            {:unrouted, auth_state(conn, [])}

          info when is_map(info) ->
            {routed_class(conn), auth_state(conn, Map.get(info, :pipe_through) || [])}
        end

      _ ->
        {:pre_router, auth_state(conn, [])}
    end
  end

  def classify(_meta), do: {:pre_router, :auth_unknown}

  defp routed_class(conn) do
    cond do
      Map.has_key?(conn.private, :phoenix_live_view) -> :lv_dead
      format_of(conn) == "html" -> :browser
      true -> :api
    end
  end

  # The negotiated format when the `accepts` plug ran; when a routed conn
  # halted before it (rare), fall back to what was actually served.
  defp format_of(conn) do
    case conn.private[:phoenix_format] do
      format when is_binary(format) ->
        format

      _ ->
        case Plug.Conn.get_resp_header(conn, "content-type") do
          [ct | _] -> if ct =~ "html", do: "html", else: "json"
          [] -> "json"
        end
    end
  end

  # D11 — never assign absence: authed needs the token PRESENT; anon needs an
  # auth-resolving pipeline to have RUN and resolved nothing; everything else
  # is the named unknown.
  defp auth_state(conn, pipes) do
    cond do
      not is_nil(conn.assigns[:api_token]) -> :authed
      Enum.any?(pipes, &(&1 in @auth_resolving_pipelines)) -> :anon
      true -> :auth_unknown
    end
  end

  # ── Pure math (unit-tested directly; no process needed) ───────────────────

  @doc """
  Derive the window stats from raw `{time_ms, duration_ms, status, route_class,
  auth_state}` samples.

  `elapsed = min(now - started, window)` — a fresh boot reports over the time it
  has actually lived, never a fabricated full window. Empty window ⇒
  `req_per_s: 0.0` (true — zero requests were observed), `p95_ms: nil` (no
  samples is not 0ms), `err_5xx_per_s: nil` (no samples is not "no errors"),
  `count: 0`, `classes: %{}` (no fabricated per-class zero-rows).

  `status` may be `nil` for a sample whose response status was not knowable; such
  a sample counts toward throughput and latency but is never counted as a 5xx.

  Returns 7 of the 8 payload keys — `sampled_at` is wall-clock at READ time and
  is stamped by the callers, keeping this function pure.
  """
  def compute(samples, now_ms, started_ms, window_ms) do
    cutoff = now_ms - window_ms
    in_window = for {t, d, s, class, auth} <- samples, t >= cutoff, do: {d, s, class, auth}
    count = length(in_window)

    uptime_ms = max(now_ms - started_ms, 0)
    # Clamp to >= 1ms so the very first millisecond of uptime cannot divide by
    # zero; min(uptime, window) keeps a young box honest.
    elapsed_ms = uptime_ms |> min(window_ms) |> max(1)

    req_per_s =
      if count == 0 do
        0.0
      else
        Float.round(count * 1000 / elapsed_ms, 2)
      end

    p95_ms =
      case in_window do
        [] -> nil
        samples -> samples |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> percentile(95) |> round()
      end

    # Rate, not a count, and over the SAME elapsed seconds as req_per_s so the
    # two are directly comparable ("12 req/s of which 0.22 are 5xx"). An empty
    # window is nil, never 0.0 — see the moduledoc; a fabricated clean bill of
    # health is the one lie this meter must never tell.
    err_5xx_per_s =
      case in_window do
        [] ->
          nil

        samples ->
          errors =
            Enum.count(samples, fn {_d, s, _class, _auth} ->
              is_integer(s) and s >= 500 and s < 600
            end)

          Float.round(errors * 1000 / elapsed_ms, 3)
      end

    # Per-class breakdown over the SAME window and elapsed seconds. Only classes
    # actually observed appear — an empty window is `%{}`, and a class with no
    # samples has no row (absence, not a fabricated zero).
    classes =
      in_window
      |> Enum.group_by(fn {_d, _s, class, _auth} -> class end)
      |> Map.new(fn {class, rows} ->
        n = length(rows)
        by_auth = Enum.frequencies_by(rows, fn {_d, _s, _class, auth} -> auth end)

        {class,
         %{
           count: n,
           req_per_s: Float.round(n * 1000 / elapsed_ms, 2),
           authed: Map.get(by_auth, :authed, 0),
           anon: Map.get(by_auth, :anon, 0),
           auth_unknown: Map.get(by_auth, :auth_unknown, 0)
         }}
      end)

    %{
      req_per_s: req_per_s,
      p95_ms: p95_ms,
      err_5xx_per_s: err_5xx_per_s,
      window_s: div(window_ms, 1000),
      count: count,
      elapsed_s: Float.round(elapsed_ms / 1000, 3),
      classes: classes
    }
  end

  @doc """
  Nearest-rank percentile over an already-sorted (ascending) list of numbers.

  `rank = ceil(p/100 * n)`, clamped to `1..n`; returns the value at that rank.
  `[]` ⇒ `nil`.
  """
  def percentile([], _p), do: nil

  def percentile(sorted, p) when is_list(sorted) do
    n = length(sorted)
    rank = (p / 100 * n) |> Float.ceil() |> round() |> max(1) |> min(n)
    Enum.at(sorted, rank - 1)
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)
    :ets.new(table, [:ordered_set, :public, :named_table, {:write_concurrency, true}])

    handler_id = "barkpark-request-stats-" <> inspect(table)

    :telemetry.attach(
      handler_id,
      [:phoenix, :endpoint, :stop],
      &__MODULE__.handle_event/4,
      %{table: table}
    )

    schedule_prune()

    {:ok,
     %{
       table: table,
       handler_id: handler_id,
       started_at: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    samples =
      state.table
      |> :ets.tab2list()
      |> Enum.map(fn {{t, _uniq}, d, s, class, auth} -> {t, d, s, class, auth} end)

    reply =
      samples
      |> compute(now_ms(), state.started_at, @window_ms)
      |> put_sampled_at()

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = now_ms() - @window_ms
    # ordered_set keyed by {time_ms, unique}: drop every row whose time is older
    # than the window. Bounds memory to ~one window (+ one prune interval). The
    # head must carry the row's FULL arity — a narrower pattern against the
    # 5-tuple rows matches nothing and the "prune" silently becomes an unbounded
    # leak. `RequestStatsTest` proves prune-still-deletes at this arity.
    :ets.select_delete(state.table, [
      {{{:"$1", :_}, :_, :_, :_, :_}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_prune()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_every_ms)

  defp put_sampled_at(payload) do
    sampled_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    Map.put(payload, :sampled_at, sampled_at)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
