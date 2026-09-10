defmodule BarkparkWeb.RequestStatsTest do
  use ExUnit.Case, async: false

  alias BarkparkWeb.RequestStats

  # A window sample: {time_ms, duration_ms, status, route_class, auth_state}.
  defp sample(t, d, s, class \\ :api, auth \\ :anon), do: {t, d, s, class, auth}

  defp routed_conn(method, path) do
    Plug.Test.conn(method, path)
    |> Plug.Conn.put_private(:phoenix_router, BarkparkWeb.Router)
  end

  describe "compute/4 — window math" do
    test "empty window: req_per_s 0.0, p95_ms nil, err_5xx_per_s nil, count 0, classes {} (never fake zeros)" do
      now = 100_000

      assert %{
               req_per_s: +0.0,
               p95_ms: nil,
               err_5xx_per_s: nil,
               window_s: 60,
               count: 0,
               elapsed_s: 60.0,
               classes: classes
             } = RequestStats.compute([], now, now - 60_000, 60_000)

      assert classes == %{}
    end

    test "count / elapsed over a full window" do
      now = 1_000_000
      started = now - 120_000
      # 120 samples spread across the last 60s -> 120 / 60 = 2.0 req/s.
      samples = for i <- 0..119, do: sample(now - i * 500, 5.0, 200)

      assert %{req_per_s: 2.0, p95_ms: 5, count: 120, elapsed_s: 60.0} =
               RequestStats.compute(samples, now, started, 60_000)
    end

    test "fresh boot divides by elapsed uptime, not the full window" do
      now = 5_000
      started = now - 5_000
      # 10 requests, box only alive 5s -> 10 / 5 = 2.0, not 10 / 60.
      samples = for i <- 0..9, do: sample(now - i * 100, 3.0, 200)

      assert %{req_per_s: 2.0, elapsed_s: 5.0} =
               RequestStats.compute(samples, now, started, 60_000)
    end

    test "samples older than the window are excluded from rate, p95, count and classes" do
      now = 1_000_000
      started = now - 300_000
      in_window = for i <- 0..59, do: sample(now - i * 1000, 10.0, 200, :api, :authed)
      # 1000 stale samples with a huge duration must not leak into any meter.
      stale = for i <- 0..999, do: sample(now - 90_000 - i, 9999.0, 500, :unrouted, :auth_unknown)

      %{req_per_s: rps, p95_ms: p95, err_5xx_per_s: err5xx, count: count, classes: classes} =
        RequestStats.compute(in_window ++ stale, now, started, 60_000)

      # 60 in-window samples over a full 60s window -> 1.0 req/s.
      assert rps == 1.0
      # p95 reflects only the in-window 10ms samples, not the 9999ms stale ones.
      assert p95 == 10
      # The 1000 stale samples are ALL 500s. None of them may leak into the error
      # rate: an outage that ended two minutes ago is not happening now.
      assert err5xx == +0.0
      assert count == 60
      # The stale :unrouted storm left the window entirely — no class row for it.
      assert Map.keys(classes) == [:api]
    end

    test "p95_ms rounds the nearest-rank percentile to an integer" do
      now = 1_000_000
      started = now - 120_000
      # Durations 1..100 ms; nearest-rank p95 of 100 sorted values is the 95th.
      samples = for d <- 1..100, do: sample(now - 1000, d / 1.0, 200)
      assert %{p95_ms: 95} = RequestStats.compute(samples, now, started, 60_000)
    end
  end

  describe "compute/4 — classes (D9 per-class rate WITH volume, D11 three-valued auth)" do
    test "per-class count, rate, and auth tallies over the same elapsed seconds" do
      now = 1_000_000
      started = now - 300_000

      samples =
        List.duplicate(sample(now - 1000, 5.0, 200, :api, :authed), 90) ++
          List.duplicate(sample(now - 1000, 5.0, 200, :api, :anon), 27) ++
          List.duplicate(sample(now - 1000, 5.0, 200, :lv_dead, :auth_unknown), 6) ++
          [sample(now - 1000, 5.0, 404, :unrouted, :auth_unknown)]

      %{count: count, classes: classes} = RequestStats.compute(samples, now, started, 60_000)

      assert count == 124

      assert classes[:api] == %{
               count: 117,
               req_per_s: 1.95,
               authed: 90,
               anon: 27,
               auth_unknown: 0
             }

      assert classes[:lv_dead] == %{
               count: 6,
               req_per_s: 0.1,
               authed: 0,
               anon: 0,
               auth_unknown: 6
             }

      assert classes[:unrouted] == %{
               count: 1,
               req_per_s: 0.02,
               authed: 0,
               anon: 0,
               auth_unknown: 1
             }

      # No fabricated zero-rows: classes nobody observed are ABSENT, not 0.
      refute Map.has_key?(classes, :browser)
      refute Map.has_key?(classes, :pre_router)
    end
  end

  describe "classify/1 — five-class enum (D9) + three-valued auth (D11)" do
    test "a meta without a conn is {:pre_router, :auth_unknown} — classified, never crashed" do
      assert RequestStats.classify(%{}) == {:pre_router, :auth_unknown}
      assert RequestStats.classify(%{conn: :not_a_conn}) == {:pre_router, :auth_unknown}
    end

    test "no :phoenix_router private -> :pre_router (halted upstream of the router)" do
      conn = Plug.Test.conn("GET", "/v1/capabilities")
      assert RequestStats.classify(%{conn: conn}) == {:pre_router, :auth_unknown}
    end

    test "router present + route_info :error -> :unrouted, auth_unknown (no pipeline ran)" do
      conn = routed_conn("GET", "/definitely/not/a/route")
      assert RequestStats.classify(%{conn: conn}) == {:unrouted, :auth_unknown}
    end

    test "routed json + api_token assigned -> {:api, :authed}" do
      conn =
        routed_conn("GET", "/v1/capabilities")
        |> Plug.Conn.put_private(:phoenix_format, "json")
        |> Plug.Conn.assign(:api_token, %{id: "t"})

      assert RequestStats.classify(%{conn: conn}) == {:api, :authed}
    end

    test "routed json, token ABSENT, auth-resolving pipeline ran -> {:api, :anon}" do
      conn =
        routed_conn("GET", "/v1/capabilities")
        |> Plug.Conn.put_private(:phoenix_format, "json")

      assert RequestStats.classify(%{conn: conn}) == {:api, :anon}
    end

    test "LV dead render (phoenix_live_view private) -> :lv_dead; bare :browser pipeline -> auth_unknown, NEVER anon" do
      conn =
        routed_conn("GET", "/papers/some-slug")
        |> Plug.Conn.put_private(:phoenix_format, "html")
        |> Plug.Conn.put_private(:phoenix_live_view, {SomeLive, [], %{}})

      assert RequestStats.classify(%{conn: conn}) == {:lv_dead, :auth_unknown}
    end

    test "routed html without LV -> :browser" do
      # /finder is a plain browser-pipeline LiveView route; without the LV
      # private (halted before the LV plug) it reads as routed html.
      conn =
        routed_conn("GET", "/finder")
        |> Plug.Conn.put_private(:phoenix_format, "html")

      assert RequestStats.classify(%{conn: conn}) == {:browser, :auth_unknown}
    end

    test "the D11 auth-resolving pipeline allowlist is pinned (drift must be deliberate)" do
      assert RequestStats.auth_resolving_pipelines() == ~w(
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
    end
  end

  describe "compute/4 — err_5xx_per_s (D48 honest meter, D75 widening)" do
    test "an EMPTY window is nil, never 0.0 — 'no samples' is not 'no errors'" do
      now = 100_000
      assert %{err_5xx_per_s: nil} = RequestStats.compute([], now, now - 60_000, 60_000)
    end

    test "a mixed 2xx/5xx window reports the 5xx rate over the same elapsed seconds" do
      now = 1_000_000
      started = now - 300_000
      # 60s window, 600 requests (10 req/s) of which 12 are 500s -> 0.2 5xx/s.
      ok = for i <- 0..587, do: sample(now - rem(i, 60) * 1000, 5.0, 200)
      errs = for i <- 0..11, do: sample(now - i * 5000, 50.0, 500)

      assert %{req_per_s: 10.0, err_5xx_per_s: 0.2} =
               RequestStats.compute(ok ++ errs, now, started, 60_000)
    end

    test "a measured window with zero 5xx is a real 0.0, distinct from the empty nil" do
      now = 1_000_000
      started = now - 300_000
      samples = for i <- 0..59, do: sample(now - i * 1000, 5.0, 200)

      assert %{err_5xx_per_s: +0.0} = RequestStats.compute(samples, now, started, 60_000)
    end

    test "only 500..599 counts: 4xx, 3xx and an unknown nil status are not errors here" do
      now = 1_000_000
      started = now - 300_000

      samples = [
        sample(now - 1000, 5.0, 200),
        sample(now - 1000, 5.0, 301),
        sample(now - 1000, 5.0, 404),
        sample(now - 1000, 5.0, 422),
        sample(now - 1000, 5.0, nil),
        sample(now - 1000, 5.0, 499),
        sample(now - 1000, 5.0, 600),
        sample(now - 1000, 5.0, 503)
      ]

      # Exactly one of the eight is a 5xx, over a full 60s elapsed window.
      assert %{err_5xx_per_s: 0.017} = RequestStats.compute(samples, now, started, 60_000)
    end

    test "a fresh boot divides 5xx by lived uptime, not a window it has not lived" do
      now = 5_000
      started = now - 5_000
      # 5 requests in 5s, all 500 -> 1.0 5xx/s, not 5/60.
      samples = for i <- 0..4, do: sample(now - i * 100, 5.0, 500)

      assert %{err_5xx_per_s: 1.0} = RequestStats.compute(samples, now, started, 60_000)
    end
  end

  describe "percentile/2 — nearest rank" do
    test "empty list is nil" do
      assert RequestStats.percentile([], 95) == nil
    end

    test "single sample is its own p95" do
      assert RequestStats.percentile([42.0], 95) == 42.0
    end

    test "p95 of 1..100 is the 95th value" do
      assert RequestStats.percentile(Enum.map(1..100, &(&1 * 1.0)), 95) == 95.0
    end

    test "p95 of a short list clamps to the top rank" do
      # ceil(0.95 * 10) = 10 -> the max element.
      assert RequestStats.percentile([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0], 95) ==
               10.0
    end
  end

  describe "end-to-end: telemetry event -> ETS -> stats/1" do
    setup do
      table = :"req_stats_test_#{System.unique_integer([:positive])}"
      name = :"req_stats_proc_#{System.unique_integer([:positive])}"
      pid = start_supervised!({RequestStats, name: name, table: table})
      %{name: name, table: table, pid: pid}
    end

    test "a fresh aggregator reports the honest empty window", %{name: name} do
      assert %{
               req_per_s: +0.0,
               p95_ms: nil,
               err_5xx_per_s: nil,
               window_s: 60,
               count: 0,
               classes: classes,
               sampled_at: sampled_at
             } = RequestStats.stats(name)

      assert classes == %{}
      assert {:ok, _dt, 0} = DateTime.from_iso8601(sampled_at)
    end

    test "emitted [:phoenix, :endpoint, :stop] events feed the window", %{
      name: name,
      table: table
    } do
      # Emit known durations (ms -> native) straight through the handler this
      # instance attached; assert both meters move off empty.
      for ms <- [10, 20, 30, 40, 50] do
        native = System.convert_time_unit(ms, :millisecond, :native)

        RequestStats.handle_event([:phoenix, :endpoint, :stop], %{duration: native}, %{}, %{
          table: table
        })
      end

      %{req_per_s: rps, p95_ms: p95, window_s: 60, count: count} = RequestStats.stats(name)
      assert rps > 0.0
      assert count == 5
      # p95 of [10,20,30,40,50] nearest-rank (ceil(0.95*5)=5) -> 50ms.
      assert p95 == 50
    end

    test "the conn's status rides the SAME event into the 5xx rate", %{
      name: name,
      table: table
    } do
      # Phoenix hands the handler the conn as metadata; this is exactly the shape
      # the endpoint emits, and the status is what the old handler discarded.
      for status <- [200, 200, 200, 500, 503] do
        native = System.convert_time_unit(10, :millisecond, :native)

        RequestStats.handle_event(
          [:phoenix, :endpoint, :stop],
          %{duration: native},
          %{conn: %Plug.Conn{status: status}},
          %{table: table}
        )
      end

      %{req_per_s: rps, err_5xx_per_s: err5xx} = RequestStats.stats(name)
      assert rps > 0.0
      # 2 of the 5 samples are 5xx; the rate is over lived uptime, so assert the
      # ratio rather than a wall-clock-dependent absolute.
      assert err5xx > 0.0
      assert_in_delta err5xx / rps, 0.4, 0.001
    end

    test "a metadata shape without a conn never counts as an error and classifies pre_router",
         %{
           name: name,
           table: table
         } do
      native = System.convert_time_unit(10, :millisecond, :native)

      RequestStats.handle_event([:phoenix, :endpoint, :stop], %{duration: native}, %{}, %{
        table: table
      })

      %{err_5xx_per_s: err5xx, classes: classes} = RequestStats.stats(name)
      # Measured window, unknown status: a real 0.0 (not an error, not a nil).
      assert err5xx == +0.0
      # A synthetic emit has no router and no auth plug — the honest bucket.
      assert %{pre_router: %{count: 1, authed: 0, anon: 0, auth_unknown: 1}} = classes
    end

    test "prune deletes aged rows at the WIDENED row arity", %{
      name: name,
      table: table,
      pid: pid
    } do
      # A stale-arity matchspec (the pre-class 3-element row) would match nothing
      # against these 5-element rows and this test would be red on the leak.
      old_t = System.monotonic_time(:millisecond) - 120_000
      fresh_t = System.monotonic_time(:millisecond)
      :ets.insert(table, {{old_t, 0}, 5.0, 200, :api, :anon})
      :ets.insert(table, {{fresh_t, 1}, 5.0, 200, :api, :anon})

      send(pid, :prune)
      # A GenServer processes messages in order: this call syncs after :prune.
      _ = RequestStats.stats(name)

      assert [{{^fresh_t, 1}, _d, 200, :api, :anon}] = :ets.tab2list(table)
    end

    test "the served route body carries the additive 8-key payload as real JSON keys", %{
      name: name
    } do
      # The controller is `json(conn, RequestStats.stats())` — encoding the map is
      # the route's whole body, so encoding it here pins the wire contract the Go
      # agent decodes (and pins that an empty window serialises as `null`).
      body = Jason.encode!(RequestStats.stats(name))

      assert body =~ ~s("err_5xx_per_s":null)
      assert body =~ ~s("req_per_s")
      assert body =~ ~s("p95_ms":null)
      assert body =~ ~s("window_s":60)
      assert body =~ ~s("count":0)
      assert body =~ ~s("classes":{})
      assert body =~ ~s("sampled_at":")
      assert body =~ ~s("elapsed_s":)

      decoded = Jason.decode!(body)
      assert Map.has_key?(decoded, "err_5xx_per_s")
      assert decoded["err_5xx_per_s"] == nil
      assert decoded["classes"] == %{}
    end
  end

  # ── The Plug/Phoenix behaviours this meter INHERITS (charter D132) ─────────
  #
  # Two of the three facts every latency and 5xx claim rests on are NOT
  # Barkpark behaviours — they belong to `Plug.Telemetry` and to
  # `Phoenix.Endpoint.RenderErrors`, so a dependency bump can flip them with no
  # diff in this repo. They are pinned here through a REAL Phoenix endpoint
  # (its own `Plug.Telemetry` + its own `Phoenix.Router`), never by calling a
  # private function, so the thing under test is the hook path itself:
  #
  #   1. `Plug.Telemetry.call/2` computes the duration inside
  #      `Plug.Conn.register_before_send/2` (plug/lib/plug/telemetry.ex), and
  #      before_send fires on the FIRST `send_chunked/2`. A stream is therefore
  #      sampled at OPEN, at ~0 ms, and never again — a 25-second SSE stream
  #      lands as a ~0 ms sample and pulls p95 DOWN.
  #   2. A raise INSIDE the router is wrapped by `Plug.Conn.WrapperError`
  #      carrying the conn as it stood at the router — before_send included —
  #      so `RenderErrors.__catch__/5` renders the 500 ON THAT CONN, the
  #      callback fires, and the sample lands with the request's FULL duration
  #      and a 500 status. That is why a 17-second pool-timeout 500 shows up as
  #      a 17-second sample and a 5xx tick, rather than vanishing.
  #
  # The third test is the CONTROL for (2), and it is the boundary nobody should
  # re-derive the hard way: a raise from an endpoint-level plug OUTSIDE the
  # router is not wrapped, so `__catch__/5` falls back to the endpoint's
  # ORIGINAL conn, which carries no before_send. The 500 is still sent to the
  # client — and the meter never sees it. Without this arm, "a 500 lands"
  # reads as a law of 500s; it is a law of 500s raised inside the router.
  defmodule HookController do
    # A bare Plug, not `use Phoenix.Controller`: Phoenix.Router dispatches with
    # `plug.call(conn, plug.init(action))`, so this is the same door a real
    # controller comes through, with none of the view/format ceremony.
    def init(action), do: action

    def call(%{private: %{hook_test: test}} = conn, :chunked) do
      conn = Plug.Conn.send_chunked(conn, 200)
      # The stream is OPEN and the response is NOT finished. Hand the test the
      # keys and block until it has read the meter.
      send(test, {:stream_open, self()})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end

      {:ok, conn} = Plug.Conn.chunk(conn, "late\n")
      conn
    end

    def call(conn, :boom) do
      Process.sleep(conn.private.hook_sleep_ms)
      raise "hook boom — the pool-timeout shape"
    end
  end

  defmodule HookRouter do
    use Phoenix.Router

    get("/chunked", HookController, :chunked)
    get("/boom", HookController, :boom)
  end

  Application.put_env(:barkpark, __MODULE__.HookEndpoint,
    secret_key_base: String.duplicate("x", 64),
    render_errors: [formats: [json: BarkparkWeb.ErrorJSON], layout: false],
    server: false
  )

  defmodule HookEndpoint do
    use Phoenix.Endpoint, otp_app: :barkpark

    plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
    plug(:hook_bare_raise)
    plug(HookRouter)

    # An endpoint-level raise: OUTSIDE the router, so nothing wraps it in a
    # Plug.Conn.WrapperError carrying the live conn.
    def hook_bare_raise(%{path_info: ["bare-boom"]}, _opts) do
      raise "hook bare boom — raised outside the router"
    end

    def hook_bare_raise(conn, _opts), do: conn
  end

  describe "the hook path: what Plug.Telemetry + RenderErrors actually sample (D132)" do
    setup do
      table = :"req_stats_hook_#{System.unique_integer([:positive])}"
      name = :"req_stats_hook_proc_#{System.unique_integer([:positive])}"
      start_supervised!(HookEndpoint)
      start_supervised!({RequestStats, name: name, table: table})
      %{name: name}
    end

    defp hook_call(path, private) do
      conn =
        Enum.reduce(private, Plug.Test.conn(:get, path), fn {k, v}, c ->
          Plug.Conn.put_private(c, k, v)
        end)

      HookEndpoint.call(conn, HookEndpoint.init([]))
    end

    test "a chunked response is sampled at stream OPEN, not at close — and exactly once",
         %{name: name} do
      parent = self()

      task = Task.async(fn -> hook_call("/chunked", hook_test: parent) end)

      assert_receive {:stream_open, streamer}, 5_000

      # Hold the stream open well past any plausible sub-ms sampling window.
      Process.sleep(300)

      # THE SAMPLE IS ALREADY IN THE WINDOW while the response is still open,
      # and it carries the duration to stream OPEN (~0 ms), not the 300+ ms the
      # stream has been alive.
      mid = RequestStats.stats(name)
      assert %{count: 1, classes: %{api: %{count: 1}}} = mid
      assert mid.p95_ms <= 50

      # Now close the stream…
      send(streamer, :release)
      assert %Plug.Conn{state: :chunked} = Task.await(task, 5_000)
      Process.sleep(50)

      # …and NOTHING new lands: no second sample, and the ~0 ms reading stands.
      # A 25-second SSE stream is a ~0 ms sample in this window — the reason a
      # burst of long-lived streams pulls p95 DOWN instead of up.
      after_close = RequestStats.stats(name)
      assert after_close.count == 1
      assert after_close.p95_ms == mid.p95_ms
    end

    test "a 500 raised INSIDE the router lands with the request's FULL duration and ticks the 5xx rate",
         %{name: name} do
      assert_raise RuntimeError, ~r/hook boom/, fn ->
        hook_call("/boom", hook_sleep_ms: 250)
      end

      stats = RequestStats.stats(name)

      # One sample, and it carries the whole 250 ms the request spent before it
      # blew up — the 'Sent 500 in 17330ms' shape, not a 0 ms stub.
      assert %{count: 1, classes: %{api: %{count: 1}}} = stats
      assert stats.p95_ms >= 200

      # …and it is counted as an error: a real rate over the same elapsed
      # seconds, never the empty-window nil and never a 0.0.
      assert is_float(stats.err_5xx_per_s)
      assert stats.err_5xx_per_s > 0.0
    end

    test "CONTROL — a 500 raised OUTSIDE the router is served to the client and sampled by NOBODY",
         %{name: name} do
      assert_raise RuntimeError, ~r/hook bare boom/, fn -> hook_call("/bare-boom", []) end

      # The client DID get a 500: RenderErrors rendered and sent one. It just
      # sent it on the endpoint's original conn, which carries no before_send.
      assert_received {:plug_conn, :sent}
      assert_received {_ref, {500, _headers, _body}}

      # So the meter is empty — an unmeasured window, honestly nil, not a 0.0.
      assert %{count: 0, classes: %{}, err_5xx_per_s: nil, p95_ms: nil} = RequestStats.stats(name)
    end
  end
end
