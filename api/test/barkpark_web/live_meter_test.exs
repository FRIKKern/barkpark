defmodule BarkparkWeb.LiveMeterTest do
  @moduledoc """
  am-w2-s6 (anonymous-metering D4 Gate B): `BarkparkWeb.LiveMeter` meters the
  /live socket — the connected mount and every event — on the `:browser`
  budget, shadow-only.

    * WIRING — every `:public_root` LiveView's live_session carries the hook
      FIRST (one emission in `Router.Plugins` covers papers, sheets and quiz),
      and FinderLive's `:finder` session carries it too. Drop the hook from
      either and the census reds by route.
    * SHADOW — past the budget the socket keeps working (the event is still
      handled) and a `would_429` lands with `surface: :live`; never a refusal.
    * TRUST WALK — the key is the canonical client address: a forwarded hop
      counts only from a trusted front, never from an untrusted peer.
    * CONTROLS — the kill switch silences it; the dead render never bills it.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest
  import Barkpark.RateLimiterSandbox

  alias Barkpark.Quiz

  setup :reset_rate_limiter!

  setup do
    original = Application.get_env(:barkpark, :rate_limits)
    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)

    # A browser budget of 1/min: the connected mount spends it, the first
    # event is past it.
    Application.put_env(
      :barkpark,
      :rate_limits,
      Keyword.merge(original || [], browser_per_minute: 1, browser_enabled: true)
    )

    pin = "LM#{System.unique_integer([:positive])}"
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  # ── wiring ──

  defp live_routes do
    for %{path: path, metadata: %{phoenix_live_view: {mod, _action, _opts, session}}} <-
          Phoenix.Router.routes(BarkparkWeb.Router),
        do: {path, mod, session.name, hook_modules(session.extra)}
  end

  defp hook_modules(extra) do
    extra
    |> Map.get(:on_mount, [])
    |> Enum.map(fn
      %{id: {mod, _fun}} -> mod
      %{id: mod} -> mod
      other -> other
    end)
  end

  test "every :public_root LiveView carries the meter first, papers/sheets/quiz included" do
    roots =
      for {path, _mod, name, hooks} <- live_routes(),
          String.starts_with?(Atom.to_string(name), "plugin_root_"),
          do: {path, hooks}

    paths = Enum.map(roots, &elem(&1, 0))

    for want <- ["/papers/:slug", "/sheets/:slug", "/quiz/host/:pin", "/quiz/play/:pin"] do
      assert want in paths, "#{want} is not a :public_root route any more: #{inspect(paths)}"
    end

    for {path, hooks} <- roots do
      assert List.first(hooks) == BarkparkWeb.LiveMeter,
             "#{path} does not mount BarkparkWeb.LiveMeter first: #{inspect(hooks)}"
    end

    # The plugin's own hook still rides behind it.
    {_, paper_hooks} = Enum.find(roots, fn {p, _} -> p == "/papers/:slug" end)
    assert BarkparkWeb.PaperViewer in paper_hooks
  end

  test "FinderLive's session carries the meter" do
    assert [{"/finder", BarkparkWeb.FinderLive, :finder, hooks}] =
             Enum.filter(live_routes(), fn {path, _, _, _} -> path == "/finder" end)

    assert BarkparkWeb.LiveMeter in hooks
  end

  # ── behaviour ──

  defp shadow_events(fun) do
    ref = make_ref()
    test_pid = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      BarkparkWeb.Plugs.RateLimit.shadow_event(),
      fn _e, m, md, _ -> send(test_pid, {ref, m, md}) end,
      nil
    )

    try do
      fun.()
      drain(ref, [])
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(ref, acc) do
    receive do
      {^ref, m, md} -> drain(ref, [{m, md} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp live_events(events), do: Enum.filter(events, fn {_m, md} -> md[:surface] == :live end)

  # A browser whose socket arrives from `peer` carrying `xff`.
  defp browser(peer, xff \\ []) do
    scoped_conn()
    |> Plug.Test.init_test_session(%{
      "_csrf_token" => Base.url_encode64(:crypto.strong_rand_bytes(18))
    })
    |> Plug.Conn.put_private(:live_view_connect_info, %{
      peer_data: %{address: peer, port: 4000, ssl_cert: nil},
      x_headers: Enum.map(xff, &{"x-forwarded-for", &1})
    })
  end

  defp unique_peer, do: {198, 51, 100, rem(System.unique_integer([:positive]), 250) + 1}

  test "shadow: past the budget the event is still handled and a live would_429 lands",
       %{pin: pin} do
    peer = unique_peer()

    events =
      shadow_events(fn ->
        {:ok, host, _} = live(browser(peer), "/quiz/host/#{pin}")
        host |> element(~s{button[phx-value-action="lock"]}) |> render_click()
        assert Quiz.state(pin).locked, "the event past the budget was not handled"
        host |> element(~s{button[phx-value-action="unlock"]}) |> render_click()
        refute Quiz.state(pin).locked
      end)

    live = live_events(events)
    assert length(live) >= 2, "expected a would_429 per event past the budget: #{inspect(events)}"

    for {m, md} <- live do
      assert m == %{would_429: 1}
      assert md[:class] == :browser
      assert md[:on] == :event
      assert md[:key] == "ip:#{:inet.ntoa(peer)}:browser:live"
    end
  end

  test "enforce set still never refuses the socket", %{pin: pin} do
    Application.put_env(
      :barkpark,
      :rate_limits,
      Keyword.merge(Application.get_env(:barkpark, :rate_limits), browser_enforce: true)
    )

    {:ok, host, _} = live(browser(unique_peer()), "/quiz/host/#{pin}")

    # Far past a 1/min budget, with enforce on: every event is still handled.
    for _ <- 1..5 do
      host |> element(~s{button[phx-value-action="lock"]}) |> render_click()
      assert Quiz.state(pin).locked, "an event past the budget was refused with enforce on"
      host |> element(~s{button[phx-value-action="unlock"]}) |> render_click()
      refute Quiz.state(pin).locked
    end

    assert Process.alive?(host.pid)
  end

  test "trust walk: a forwarded hop counts from a trusted front, not from an untrusted peer",
       %{pin: pin} do
    forwarded = "203.0.113.77"

    trusted =
      shadow_events(fn ->
        {:ok, host, _} = live(browser({127, 0, 0, 1}, [forwarded]), "/quiz/host/#{pin}")
        host |> element(~s{button[phx-value-action="lock"]}) |> render_click()
      end)

    assert Enum.any?(live_events(trusted), fn {_, md} ->
             md[:key] == "ip:#{forwarded}:browser:live"
           end),
           "a trusted front's hop was not the key: #{inspect(trusted)}"

    reset_rate_limiter!(%{})
    peer = unique_peer()

    spoofed =
      shadow_events(fn ->
        # A second browser on the host URL: no controls, but its events still
        # ride the socket (QuizHostFloodControlsTest pins that they do nothing).
        {:ok, other, _} = live(browser(peer, [forwarded]), "/quiz/host/#{pin}")
        render_click(other, "host", %{"action" => "lock"})
      end)

    keys = live_events(spoofed) |> Enum.map(fn {_, md} -> md[:key] end)
    assert keys != [], "no live would_429 from the untrusted peer: #{inspect(spoofed)}"
    assert Enum.all?(keys, &(&1 == "ip:#{:inet.ntoa(peer)}:browser:live"))
  end

  # ── controls ──

  test "the kill switch silences the socket meter (control)", %{pin: pin} do
    Application.put_env(
      :barkpark,
      :rate_limits,
      Keyword.merge(Application.get_env(:barkpark, :rate_limits), browser_enabled: false)
    )

    events =
      shadow_events(fn ->
        {:ok, host, _} = live(browser(unique_peer()), "/quiz/host/#{pin}")
        host |> element(~s{button[phx-value-action="lock"]}) |> render_click()
      end)

    assert live_events(events) == []
  end

  test "the dead render never bills the socket meter (control)", %{pin: pin} do
    events =
      shadow_events(fn ->
        for _ <- 1..3, do: browser(unique_peer()) |> get("/quiz/host/#{pin}")
      end)

    assert live_events(events) == []
  end
end
