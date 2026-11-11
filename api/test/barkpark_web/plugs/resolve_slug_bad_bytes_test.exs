defmodule BarkparkWeb.Plugs.ResolveSlugBadBytesTest do
  @moduledoc """
  task-c79c4a8cbbc38a58: a workspace or project slug that Postgres refuses as
  text (not UTF-8, or a NUL) names nothing. In ResolveWorkspace, ResolveProject
  and LiveScope it gets the answer an unknown slug gets on that route, where
  it raised Postgrex 22021. The answers are what is compared here; a read
  with such bytes would raise.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy

  # Not UTF-8, a NUL, a cut-off sequence, an overlong "/". The router decodes
  # the segment once.
  @bad ~w(default%FF default%00 %00 %C3%28 %E2%82 %C0%AF a%FFb%00c)

  # Routes of three families that take the slug: the Studio, the bare
  # workspace URL, the scoped API. Not every `/w/` route.
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

  # ResolveWorkspace reads the project itself for a signed-in account that is
  # not a member, to weigh its grants, before ResolveProject runs.
  test "a project slug that is not text is not read for a signed-in non-member", %{conn: conn} do
    ws = Barkpark.TenancyFixtures.create_workspace!()

    {:ok, user} =
      Barkpark.Accounts.register_user(%{
        email: "slug-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery staple"
      })

    answer = fn project_slug ->
      params = %{"workspace_slug" => ws.slug, "project_slug" => project_slug}

      conn =
        %{conn | path_params: params, params: params}
        |> Plug.Conn.assign(:current_user, user)
        |> BarkparkWeb.Plugs.ResolveWorkspace.call(BarkparkWeb.Plugs.ResolveWorkspace.init([]))

      {conn.halted, conn.status}
    end

    for bad <- [<<"default", 0xFF>>, <<"default", 0>>, <<0>>, <<0xC3, 0x28>>, <<0xC0, 0xAF>>] do
      assert answer.(bad) == answer.("no-such-proj"), inspect(bad)
    end

    assert {true, 403} = answer.("no-such-proj")
  end

  test "a live patch to such a slug is denied as one to an unknown slug is", %{conn: conn} do
    for bad <- ["/w/default%FF/p/default", "/w/default%00/p/default", "/w/default/p/default%00"] do
      {:ok, view, _html} = live(admin(conn), "/w/default/p/default/d/production/studio")

      assert {:error, {:redirect, %{to: "/login" <> _}}} =
               render_patch(view, bad <> "/d/production/studio")
    end
  end
end
