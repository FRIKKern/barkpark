defmodule BarkparkWeb.Plugs.ResolveSlugBadBytesTest do
  @moduledoc """
  task-c79c4a8cbbc38a58: a workspace or project slug that Postgres refuses as
  text (not UTF-8, or a NUL) names nothing. `Tenancy.get_workspace_by_slug/1`
  and `Tenancy.get_project/2` answer nil for it, unread, so every caller gives
  the answer it gives an unknown slug, where the read raised Postgrex 22021.
  One test per kind of caller; the answers are what is compared.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.PreviewToken
  alias Barkpark.Tenancy
  alias BarkparkWeb.Plugs.PreviewToken, as: PreviewTokenPlug

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

  defp admin_token do
    raw = "slug-bad-bytes-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "slug-bad-bytes", "production", ~w(read write admin), ws.id)
    raw
  end

  defp admin(conn), do: Plug.Test.init_test_session(conn, %{"api_token" => admin_token()})

  # The same slugs as the router hands them on: decoded once.
  defp raw_bad, do: Enum.map(@bad, &URI.decode/1)

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

  # RequireShareScope runs before ResolveWorkspace and reads both slugs once
  # a `?share=` token is a live link, whatever scope the link is for.
  test "a slug that is not text is not read for the holder of a live share link", %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok, {raw, _link}} =
      Barkpark.Sharing.Links.create(%{
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: "production",
        kind: "doc",
        ref_type: "post",
        ref_id: "slug-bad-bytes",
        access: "read"
      })

    share = &(&1 <> "?share=" <> raw)

    for bad <- @bad,
        {bad_routes, unknown_routes} <- [
          {routes(bad, "default"), routes("no-such-ws", "default")},
          {routes("default", bad), routes("default", "no-such-proj")}
        ],
        {url, unknown} <- Enum.zip(bad_routes, unknown_routes) do
      assert answer(conn, share.(url)) == answer(conn, share.(unknown)), url
    end
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

  test "the two reads answer nil for a slug that is not text" do
    for bad <- raw_bad() do
      assert Tenancy.get_workspace_by_slug(bad) == nil, inspect(bad)
      assert Tenancy.get_project(bad, "default") == nil, inspect(bad)
      assert Tenancy.get_project("default", bad) == nil, inspect(bad)
    end

    assert %Tenancy.Workspace{} = Tenancy.get_workspace_by_slug("default")
    assert %Tenancy.Project{} = Tenancy.get_project("default", "default")
  end

  # LiveAuth :scoped_admin reads the workspace slug before LiveScope does.
  test "the workspace settings pages give such a slug the unknown-workspace answer",
       %{conn: conn} do
    pages = ~w(settings chat-hosts chat chat/some-session connectors)

    for {who, conn} <- [nobody: conn, admin: admin(conn)], bad <- @bad, page <- pages do
      assert answer(conn, "/w/#{bad}/p/default/studio/#{page}") ==
               answer(conn, "/w/no-such-ws/p/default/studio/#{page}"),
             "#{who} #{bad} #{page}"
    end
  end

  # LiveAuth :admin reads the slug only to pick the language of its refusal.
  test "the plugins page refuses a visitor on such a slug as on an unknown one", %{conn: conn} do
    for bad <- @bad do
      assert answer(conn, "/w/#{bad}/p/default/d/production/studio/_plugins") ==
               answer(conn, "/w/no-such-ws/p/default/d/production/studio/_plugins"),
             bad
    end
  end

  test "a Preview token on such a slug is judged as on an unknown slug" do
    prior = Application.get_env(:barkpark, :preview)
    secret = "test-preview-secret-abcdefghijklmnop"
    Application.put_env(:barkpark, :preview, secret: secret, ttl_seconds: 600, issuer: "barkpark")
    on_exit(fn -> Application.put_env(:barkpark, :preview, prior || []) end)

    ws = Tenancy.get_default_workspace()

    answer = fn ws_slug, proj_slug ->
      {jwt, _claims} = PreviewToken.sign(%{dataset: "production", workspace_id: ws.id}, secret)

      params = %{
        "workspace_slug" => ws_slug,
        "project_slug" => proj_slug,
        "dataset" => "production",
        "type" => "post"
      }

      conn =
        %{build_conn(:get, "/v1/preview/query/production/post") | path_params: params}
        |> put_req_header("authorization", "Preview " <> jwt)
        |> PreviewTokenPlug.call(PreviewTokenPlug.init(optional: true))

      {conn.halted, conn.status}
    end

    for bad <- raw_bad() do
      assert answer.(bad, "default") == answer.("no-such-ws", "default"), inspect(bad)
      assert answer.("default", bad) == answer.("default", "no-such-proj"), inspect(bad)
    end
  end

  test "the flat workspace API gives such a slug the unknown-workspace answer", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer " <> admin_token())
    answer = fn url -> get(conn, url).status end

    for bad <- @bad do
      assert answer.("/api/workspaces/#{bad}/projects") ==
               answer.("/api/workspaces/no-such-ws/projects"),
             bad

      assert answer.("/api/workspaces/#{bad}/projects/default/datasets") ==
               answer.("/api/workspaces/no-such-ws/projects/default/datasets"),
             bad

      assert answer.("/api/workspaces/default/projects/#{bad}/datasets") ==
               answer.("/api/workspaces/default/projects/no-such-proj/datasets"),
             bad
    end

    assert answer.("/api/workspaces/no-such-ws/projects") == 404
  end
end
