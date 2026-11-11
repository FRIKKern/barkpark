defmodule BarkparkWeb.Plugs.ResolveSlugBadBytesTest do
  @moduledoc """
  task-c79c4a8cbbc38a58: a workspace or project slug that Postgres refuses as
  text (not UTF-8, or a NUL) names nothing. It gets the answer an unknown slug
  gets on that route and never reaches a query (it raised Postgrex 22021).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy

  # Not UTF-8, a NUL, a cut-off sequence, an overlong "/". The router decodes
  # the segment once.
  @bad ~w(default%FF default%00 %00 %C3%28 %E2%82 %C0%AF a%FFb%00c)

  # Every route family that takes the slug: the Studio, the bare workspace
  # URL, the scoped API.
  defp routes(ws, proj) do
    [
      "/w/#{ws}/p/#{proj}/d/production/studio",
      "/w/#{ws}/p/#{proj}/d/production/studio/_desk",
      "/w/#{ws}/p/#{proj}/v1/data/query/production/post"
    ] ++ if(proj == "default", do: ["/w/#{ws}"], else: [])
  end

  defp answer(conn, url) do
    conn = get(conn, url)

    {conn.status,
     conn |> get_resp_header("location") |> Enum.map(&String.replace(&1, ~r/\?.*/, ""))}
  end

  defp admin(conn) do
    raw = "slug-bad-bytes-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "slug-bad-bytes", "production", ~w(read write admin), ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  setup do
    Barkpark.TenancyFixtures.ensure_default_scope!()
    :ok
  end

  test "a workspace slug that is not text gets the unknown-workspace answer", %{conn: conn} do
    for {who, conn} <- [nobody: conn, admin: admin(conn)],
        bad <- @bad,
        {url, unknown} <- Enum.zip(routes(bad, "default"), routes("no-such-ws", "default")) do
      assert answer(conn, url) == answer(conn, unknown), "#{who} #{url}"
    end

    conn = get(conn, "/w/default%00/p/default/v1/data/query/production/post")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "a project slug that is not text gets the unknown-project answer", %{conn: conn} do
    for {who, conn} <- [nobody: conn, admin: admin(conn)],
        bad <- @bad,
        {url, unknown} <- Enum.zip(routes("default", bad), routes("default", "no-such-proj")) do
      assert answer(conn, url) == answer(conn, unknown), "#{who} #{url}"
    end

    conn = get(admin(conn), "/w/default/p/default%00/v1/data/query/production/post")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "a live patch to such a slug is denied as one to an unknown slug is", %{conn: conn} do
    for bad <- ["/w/default%FF/p/default", "/w/default%00/p/default", "/w/default/p/default%00"] do
      {:ok, view, _html} = live(admin(conn), "/w/default/p/default/d/production/studio")

      assert {:error, {:redirect, %{to: "/login" <> _}}} =
               render_patch(view, bad <> "/d/production/studio")
    end
  end
end
