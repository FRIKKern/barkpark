defmodule BarkparkWeb.Studio.StudioPageMainLandmarkTest do
  @moduledoc """
  task-48f34bf81564a082: workspace settings had no main landmark, and its h1
  sat outside every landmark (axe landmark-one-main, region). Every Studio page
  that renders through `studio_page_scroll/1` had the same gap. The wrapper is
  now the page's `<main>`, so a page using it must not mark another.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures
  import BarkparkWeb.Studio.PageScroll

  alias Barkpark.Auth

  @admin_token "page-main-admin-token"
  @studio_dir Path.expand("../../../../lib/barkpark_web/live/studio", __DIR__)

  test "the page scroll wrapper is a main landmark" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.studio_page_scroll><h1>Page</h1></.studio_page_scroll>
      """)

    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.query(doc, "main.studio-page-scroll h1") |> Enum.count() == 1
  end

  test "no page that renders through the wrapper marks a main of its own" do
    users =
      @studio_dir
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) == "page_scroll.ex"))
      |> Enum.filter(&(File.read!(&1) =~ "<.studio_page_scroll"))

    assert length(users) >= 5, "found #{length(users)} pages using the wrapper"

    for file <- users do
      source = File.read!(file)
      refute source =~ ~r/<main[\s>]|role="main"/, "#{Path.basename(file)} marks a second main"
    end
  end

  describe "workspace settings" do
    setup %{conn: conn} do
      ensure_default_scope!()

      {:ok, _} =
        Auth.create_token(
          @admin_token,
          "page main admin",
          "production",
          ["read", "write", "admin"],
          Barkpark.TenancyFixtures.default_workspace_id!()
        )

      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "has exactly one main, and its h1 is inside it", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/w/default/p/default/studio/settings")
      doc = LazyHTML.from_document(html)

      assert LazyHTML.query(doc, ~s(main, [role="main"])) |> Enum.count() == 1
      assert LazyHTML.query(doc, "main h1") |> Enum.count() == 1
      assert LazyHTML.query(doc, "h1") |> Enum.count() == 1
    end
  end
end
