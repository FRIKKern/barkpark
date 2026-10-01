defmodule BarkparkWeb.Studio.StudioTabTitleTest do
  @moduledoc """
  The Studio browser tab names the page it shows.

  Studio LiveViews assign `page_title` ("Media Library", "Workspace
  Settings", …), but root.html.heex rendered a static
  `<title>Barkpark Studio</title>`, so those assigns never reached the tab and
  every Studio tab read the same. The root now renders `<.live_title>`, the
  same pattern as sheets.html.heex and bulldocs.html.heex. Its default carries
  no site name because the suffix is appended to the default too.
  """
  use BarkparkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    raw = "tab-title-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(
        raw,
        "tab-title",
        "production",
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"api_token" => raw})

    {:ok, conn: conn}
  end

  test "the dead render's <title> carries the LiveView's page_title", %{conn: conn} do
    html = conn |> get(scoped_studio("/d/production/studio/media")) |> html_response(200)

    assert [title] = Regex.run(~r{<title[^>]*>([^<]*)</title>}, html, capture: :all_but_first)
    assert title == "Media Library · Barkpark"
  end

  test "the connected view reports its page_title, and the desk its own", %{conn: conn} do
    {:ok, media, _} = live(conn, scoped_studio("/d/production/studio/media"))
    assert page_title(media) == "Media Library · Barkpark"

    {:ok, desk, _} = live(conn, scoped_studio("/d/production/studio"))
    assert page_title(desk) == "Studio · Barkpark"
  end

  test "the root layout no longer hardcodes the tab title" do
    root = File.read!(Path.expand("../../../../lib/barkpark_web/layouts/root.html.heex", __DIR__))

    refute root =~ "<title>Barkpark Studio</title>"

    assert root =~
             ~s(<.live_title default="Studio" suffix=" · Barkpark">{assigns[:page_title]}</.live_title>)
  end
end
