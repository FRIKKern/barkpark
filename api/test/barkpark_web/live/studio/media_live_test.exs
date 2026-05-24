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
    {:ok, view, html} = live(conn, "/studio/production/media")

    assert html =~ "bp-asset-explorer"
    assert html =~ ~s(dataset="production")
    assert has_element?(view, "bp-asset-explorer")
  end
end
