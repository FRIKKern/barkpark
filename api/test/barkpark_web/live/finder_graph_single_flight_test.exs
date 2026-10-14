defmodule BarkparkWeb.FinderGraphSingleFlightTest do
  @moduledoc """
  am-w2-s4: the finder's corpus graph is derived once and shared. Every
  connected /finder mount used to walk the whole corpus (seconds on a loaded
  box); now mounts of the same graph share one derivation through
  `Barkpark.SingleFlight` and its result serves later mounts for a TTL.
  Concurrency itself is pinned in `Barkpark.SingleFlightTest`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @event [:barkpark, :finder, :graph_derived]

  setup do
    Application.put_env(:barkpark, :finder_graph_ttl_ms, 60_000)
    Barkpark.SingleFlight.evict(:all)

    test_pid = self()
    handler = "finder-graph-derived-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, @event, fn _e, _m, _md, _ -> send(test_pid, :derived) end, nil)

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:barkpark, :finder_graph_ttl_ms, 0)
      Barkpark.SingleFlight.evict(:all)
    end)

    :ok
  end

  defp derivations(acc \\ 0) do
    receive do
      :derived -> derivations(acc + 1)
    after
      200 -> acc
    end
  end

  test "three mounts inside the TTL derive the graph once", %{conn: conn} do
    for _ <- 1..3 do
      {:ok, view, _} = live(conn, "/finder")
      assert render_async(view, 5_000) =~ "data-rev="
    end

    assert derivations() == 1
  end

  test "with the cache evicted, the next mount derives again (control)", %{conn: conn} do
    {:ok, view, _} = live(conn, "/finder")
    render_async(view, 5_000)
    Barkpark.SingleFlight.evict(:all)
    {:ok, view, _} = live(conn, "/finder")
    render_async(view, 5_000)

    assert derivations() == 2
  end
end
