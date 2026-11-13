defmodule BarkparkWeb.Studio.DeskUrlCapTest do
  @moduledoc """
  task-f8383ce8dd2ef270 criterion 9: a pane splat or a hovered row's href
  longer than any desk URL is refused before it is parsed. Over the socket
  nothing else bounds it: a 3.2 MB href cost about 1.8 s before the parse.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.DeskLive

  setup %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-url-cap-#{System.unique_integer([:positive])}"
    perms = ~w(read write admin)
    {:ok, _} = Barkpark.Auth.create_token(raw, "desk-url-cap", "production", perms, ws.id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/production/studio/_desk"}
  end

  # A document pane with a long param: a hover of it is one read, when read.
  defp href(base, bytes), do: "#{base}/post;post-01,rev=" <> String.duplicate("a", bytes)

  test "a hovered href past the cap is not read", %{conn: conn, base: base} do
    {:ok, view, _html} = live(conn, base)
    render_async(view, 5_000)

    test = self()

    Application.put_env(:barkpark, PaneComponent,
      reader: fn pane, node, dataset, scope, title ->
        send(test, {:reading, pane[:id]})
        PaneComponent.read(pane, node, dataset, scope, title)
      end
    )

    on_exit(fn -> Application.delete_env(:barkpark, PaneComponent) end)

    view |> element("#desk-panes") |> render_hook("warm", %{"href" => href(base, 1_000_000)})
    render(view)
    refute_receive {:reading, "post-01"}, 300

    # One of a length a link can have is read as before.
    view |> element("#desk-panes") |> render_hook("warm", %{"href" => href(base, 100)})
    assert_receive {:reading, "post-01"}, 2_000
  end

  @tag capture_log: true
  test "a pane splat past the cap is a 404, and a live patch to one goes back", %{
    conn: conn,
    base: base
  } do
    assert_error_sent(404, fn -> get(conn, href(base, 100_000)) end)
    assert_raise DeskLive.NotFound, fn -> live(conn, href(base, 100_000)) end

    {:ok, view, _html} = live(conn, base)
    render_async(view, 5_000)
    render_patch(view, href(base, 100_000))
    assert_redirect(view, base)

    {:ok, view, _html} = live(conn, href(base, 100))
    assert render_async(view, 5_000) =~ "post-01"

    # A hand-made query the page answered before is answered still.
    assert html_response(get(conn, base <> "?panes[][]=post"), 200)
  end
end
