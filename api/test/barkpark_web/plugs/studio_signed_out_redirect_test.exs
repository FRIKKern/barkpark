defmodule BarkparkWeb.Plugs.StudioSignedOutRedirectTest do
  @moduledoc """
  task-c1ccdbfaa26876cb — a signed-out browser opening a Studio URL got the raw
  JSON 403 envelope. It is not refused, it is just not signed in: it now goes
  to `/login?return_to=<the URL it asked for>` and lands back there after
  signing in. A real and an unknown workspace redirect alike (no existence
  leak), the JSON API keeps its envelope, and `return_to` only ever sends the
  browser to a same-origin relative path.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  setup do
    prev = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev) end)

    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "so-#{n}", name: "Signed out #{n}"})
    {:ok, project} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    {:ok, _} = Tenancy.create_dataset(project, %{slug: "production", name: "production"})
    {:ok, n: n, ws: ws}
  end

  defp studio(slug), do: "/w/#{slug}/p/default/d/production/studio"

  test "a signed-out browser is sent to sign in with the Studio URL as return_to",
       %{conn: conn, ws: ws} do
    conn = get(conn, studio(ws.slug) <> "/post/p1?pane=2")

    assert redirected_to(conn) ==
             "/login?return_to=" <> URI.encode_www_form(studio(ws.slug) <> "/post/p1?pane=2")
  end

  test "an unknown workspace redirects exactly the same way", %{conn: conn, ws: ws, n: n} do
    real = get(conn, studio(ws.slug))
    unknown = get(conn, studio("so-missing-#{n}"))

    assert real.status == 302 and unknown.status == 302

    assert redirected_to(unknown) ==
             "/login?return_to=" <> URI.encode_www_form(studio("so-missing-#{n}"))

    assert real.resp_body == String.replace(unknown.resp_body, "so-missing-#{n}", ws.slug)
  end

  test "after signing in the browser lands on the Studio URL it asked for",
       %{conn: conn, ws: ws, n: n} do
    email = "so-member-#{n}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "admin", "user")

    target = studio(ws.slug) <> "/post"
    "/login?return_to=" <> encoded = redirected_to(get(conn, target))

    signed_in =
      post(conn, "/login/account", %{
        "email" => email,
        "password" => @password,
        "return_to" => URI.decode_www_form(encoded)
      })

    assert redirected_to(signed_in) == target
  end

  test "the workspace's JSON API keeps its envelope for a signed-out caller",
       %{conn: conn, ws: ws} do
    conn = get(conn, "/w/#{ws.slug}/p/default/v1/data/query/production/post")

    refute conn.status in [301, 302]
    assert conn.resp_body =~ "\"error\""
  end

  for bad <- [
        "https://evil.example/x",
        "//evil.example/x",
        "/\\evil.example/x",
        "/\t/evil.example/x",
        "javascript:alert(1)",
        "evil.example/x"
      ] do
    test "return_to #{inspect(bad)} never leaves the site", %{conn: conn, ws: ws, n: n} do
      email = "so-redirect-#{n}@example.com"
      {:ok, user} = Accounts.register_user(%{email: email, password: @password})
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "admin", "user")

      signed_in =
        post(conn, "/login/account", %{
          "email" => email,
          "password" => @password,
          "return_to" => unquote(bad)
        })

      to = redirected_to(signed_in)
      assert String.starts_with?(to, "/")
      refute String.starts_with?(to, "//")
      refute to =~ "evil.example"
    end
  end
end
