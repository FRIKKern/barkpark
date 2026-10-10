defmodule BarkparkWeb.Plugs.RateLimitBrowserMountsTest do
  @moduledoc """
  am-w2-s8 (anonymous-metering D4 Gate A, D7): the five HTML browser pipelines
  mount `RateLimit` with `class: :browser`, so the dead-render class is
  metered. Shadow only: past the budget a request is still served (never a
  429) and a `would_429` lands on `[:barkpark, :rate_limit, :shadow]` with
  `class: :browser`.

  One real route per pipeline, through the endpoint, so a pipeline that loses
  the line reds by name.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  setup :reset_rate_limiter!

  setup do
    :ets.delete_all_objects(:barkpark_rate_limiter)
    original = Application.get_env(:barkpark, :rate_limits)
    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)

    # A browser budget of 1/min: the second request in each test is past it.
    Application.put_env(
      :barkpark,
      :rate_limits,
      Keyword.merge(original || [], browser_per_minute: 1, browser_enabled: true)
    )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    %{ws: ws, proj: proj}
  end

  defp shadow_events(fun) do
    ref = make_ref()
    test_pid = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:barkpark, :rate_limit, :shadow],
      fn _e, m, md, _ ->
        send(test_pid, {ref, m, md})
      end,
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

  defp twice(path) do
    shadow_events(fn ->
      for _ <- 1..2 do
        conn = scoped_conn() |> get(path)
        refute conn.status == 429, "#{path} answered 429: the browser class must stay shadow-only"
      end
    end)
  end

  defp paths(%{ws: ws, proj: proj}) do
    [
      browser: "/finder",
      scoped_browser: "/w/#{ws.slug}/p/#{proj.slug}/admin/onixedit/bokbasen",
      shared_studio_browser: "/w/#{ws.slug}/p/#{proj.slug}/d/production/studio",
      shared_paper_browser: "/w/#{ws.slug}/p/#{proj.slug}/papers/no-such-paper/source",
      workspace_browser: "/w/#{ws.slug}"
    ]
  end

  for pipeline <-
        ~w(browser scoped_browser shared_studio_browser shared_paper_browser workspace_browser)a do
    test "the :#{pipeline} pipeline meters the browser class in shadow", ctx do
      path = Keyword.fetch!(paths(ctx), unquote(pipeline))
      events = twice(path)

      assert Enum.any?(events, fn {m, md} -> md[:class] == :browser and m[:would_429] == 1 end),
             "no browser-class would_429 from #{path} (#{unquote(pipeline)}): #{inspect(events)}"
    end
  end

  test "the kill switch silences the browser class (control)", ctx do
    Application.put_env(
      :barkpark,
      :rate_limits,
      Keyword.merge(Application.get_env(:barkpark, :rate_limits), browser_enabled: false)
    )

    assert twice(Keyword.fetch!(paths(ctx), :browser)) == []
  end
end
