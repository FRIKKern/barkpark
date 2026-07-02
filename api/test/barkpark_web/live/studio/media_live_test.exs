defmodule BarkparkWeb.Studio.MediaLiveTest do
  use BarkparkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"api_token" => "barkpark-dev-token"})

    {:ok, conn: conn}
  end

  test "renders native bp-asset-explorer on the Media tab", %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/production/studio/media"))

    assert html =~ "bp-asset-explorer"
    assert html =~ ~s(dataset="production")
    assert has_element?(view, "bp-asset-explorer")
  end

  # Crash-class closure (#819): MediaLive defined zero handlers, so any stale or
  # forged client phx event FunctionClauseError-crashed the session. The
  # trailing catch-alls now no-op both dispatch paths.
  test "an unknown/stale phx event does not crash the LiveView", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/production/studio/media"))

    render_hook(view, "totally-unknown-stale-event", %{"leftover" => "true"})

    assert Process.alive?(view.pid)
    assert is_binary(render(view))
  end

  test "a stray/unmatched message does not crash the LiveView", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/production/studio/media"))

    send(view.pid, {:some_unrouted_pubsub, %{"payload" => 1}})
    send(view.pid, :bare_unknown_atom)

    assert is_binary(render(view))
    assert Process.alive?(view.pid)
  end
end
