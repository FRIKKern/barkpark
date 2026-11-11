defmodule BarkparkWeb.Studio.DeskBadBytesTest do
  @moduledoc """
  task-4291e57c6d7352da: bytes Postgres refuses as text (not UTF-8, or a NUL)
  in the dataset segment or the desk's search box never reach a query. The
  pane splat's own case is in `desk_live_test.exs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.DeskLive

  # Not UTF-8, a NUL, a cut-off sequence, an overlong "/", and each inside a
  # longer name. The router decodes the segment once.
  @bad ~w(production%FF production%00 %00 %C3%28 %E2%82 %C0%AF a%FFb%00c) ++
         [String.duplicate("%FF", 5_000)]

  setup %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    {:ok, conn: conn, scope: "/w/#{ws.slug}/p/#{proj.slug}"}
  end

  defp sign_in(conn, permissions) do
    raw = "desk-bad-bytes-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-bad-bytes", "production", permissions, ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp raised(fun) do
    fun.()
  rescue
    error -> error.__struct__
  end

  defp desk(scope, dataset), do: "#{scope}/d/#{dataset}/studio/_desk"

  test "a dataset segment that is not text is a 404, whoever asks", %{conn: conn, scope: scope} do
    for {who, conn} <- [
          admin: sign_in(conn, ["read", "write", "admin"]),
          reader: sign_in(conn, ["read"]),
          nobody: conn
        ],
        bad <- @bad,
        url <- [desk(scope, bad), desk(scope, bad) <> "/post;post-01"] do
      assert raised(fn -> get(conn, url) end) == DeskLive.NotFound, "#{who} GET #{bad}"
      assert raised(fn -> live(conn, url) end) == DeskLive.NotFound, "#{who} live #{bad}"
    end

    assert Plug.Exception.status(struct(DeskLive.NotFound)) == 404
  end

  test "a live patch to such a dataset segment goes back to the desk it left", %{
    conn: conn,
    scope: scope
  } do
    for bad <- @bad do
      {:ok, view, _html} =
        live(sign_in(conn, ["read", "write", "admin"]), desk(scope, "production"))

      render_async(view, 5_000)

      render_patch(view, desk(scope, bad))
      assert_redirect(view, desk(scope, "production"))
    end
  end

  test "a dataset segment that is text opens as it did, found or not", %{conn: conn, scope: scope} do
    # Escaped twice, the segment is the text of its escape: a name like any other.
    for dataset <- ~w(production nosuch production%25FF production%2500) do
      {:ok, view, _html} = live(sign_in(conn, ["read", "write", "admin"]), desk(scope, dataset))
      assert String.valid?(render_async(view, 5_000)), dataset
    end
  end

  test "a search value that is not text clears the box and reads nothing", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} =
      live(sign_in(conn, ["read", "write", "admin"]), desk(scope, "production"))

    render_async(view, 5_000)

    # A NUL is the one such byte a form can carry: Plug refuses a value that
    # is not UTF-8 before the event reaches the page.
    for bad <- [<<"al", 0>>, <<0, 0>>, <<0, "alpha">>, :binary.copy(<<0>>, 50_000)] do
      html = view |> element("#desk-search-form") |> render_change(%{"value" => bad})

      assert String.valid?(html)
      refute has_element?(view, "#desk-search-hits")
    end

    # The box still searches.
    view |> element("#desk-search-form") |> render_change(%{"value" => "zz-no-such-title"})
    assert has_element?(view, "#desk-search-hits [role=status]")
  end

  # task-f8383ce8dd2ef270: the Studio's own events the desk page takes.
  test "a NUL in a workspace switch, a project switch or a paper search reads nothing", %{
    conn: conn,
    scope: scope
  } do
    # The desk takes the two switches in the Studio's chrome, the Studio
    # itself in its own handlers: both pages.
    for url <- [desk(scope, "production"), "#{scope}/d/production/studio"],
        {:ok, view, _html} = live(sign_in(conn, ["read", "write", "admin"]), url),
        render_async(view, 5_000),
        {event, params} <- [
          {"switch-workspace", %{"workspace" => <<"default", 0>>}},
          {"switch-workspace", %{"workspace" => <<0>>}},
          {"switch-project", %{"project" => <<"default", 0>>}},
          {"switch-project", %{"project" => <<0, "x">>}},
          {"paper-wikilink-search", %{"query" => <<"al", 0>>}},
          {"paper-wikilink-search", %{"query" => <<0>>}},
          {"paper-tag-search", %{"query" => <<"al", 0>>}},
          {"paper-tag-search", %{"query" => <<0, "al">>}}
        ] do
      html = render_hook(view, event, params)

      assert String.valid?(html), "#{event} #{url}"
      assert Process.alive?(view.pid), "#{event} #{url}"
    end
  end
end
