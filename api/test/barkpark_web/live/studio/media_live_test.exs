defmodule BarkparkWeb.Studio.MediaLiveTest do
  use BarkparkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    # THE MINT IS LOAD-BEARING. `LiveAuth.on_mount(:fetch_api_token)` assigns
    # `:api_token_raw` to the raw string ONLY when `Auth.verify_token/1`
    # succeeds, and to "" on every failure — and `MediaLive.render/1` emits it
    # as the explorer's `data-token`. Before this mint, the session carried the
    # bare literal "barkpark-dev-token" with nothing behind it (nothing in the
    # test suite mints that string; `seeds_clean_test` asserts it is
    # unauthorized), so `verify_token/1` failed, LiveAuth took its anonymous
    # branch, and every mount in this file ran ANONYMOUS while the file claimed
    # to cover the authenticated Studio Media tab.
    raw = "media-live-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(raw, "media-live", "production", ["read", "write", "admin"])

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"api_token" => raw})

    {:ok, conn: conn, raw: raw}
  end

  test "renders native bp-asset-explorer on the Media tab", %{conn: conn, raw: raw} do
    {:ok, view, html} = live(conn, scoped_studio("/d/production/studio/media"))

    assert html =~ "bp-asset-explorer"
    assert html =~ ~s(dataset="production")
    assert has_element?(view, "bp-asset-explorer")

    # THE AUTHENTICATED-ONLY ASSERTION. Every other assertion in this file is
    # identical under an anonymous mount — the explorer renders, and the
    # crash-class catch-alls hold, whether or not a token verified. This one
    # cannot: an unverified token drives LiveAuth's failure branch, which pins
    # `:api_token_raw` to "" and renders `data-token=""`. Delete the setup mint
    # and this line reds while the three above stay green.
    assert html =~ ~s(data-token="#{raw}")
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
