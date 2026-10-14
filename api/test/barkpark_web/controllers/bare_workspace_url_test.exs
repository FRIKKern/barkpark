defmodule BarkparkWeb.BareWorkspaceUrlTest do
  @moduledoc """
  task-5e0c5c2533936e77 — `GET /w/:ws` (the owner's guerrilla login,
  `/w/studio-parity`) answered a plain 404. It now runs the same admission as
  every Studio URL in that workspace:

    * a MEMBER is 302'd to the workspace's default project/dataset Studio;
    * a signed-in NON-member and an UNKNOWN slug get the not-a-member page
      `/w/:ws/p/...` renders, IDENTICAL for both (no existence leak);
    * a signed-out browser goes to sign-in with this URL as return_to, the same
      for a real and an unknown slug.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  setup do
    prev = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev) end)

    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "bw-#{n}", name: "Bare #{n}"})
    {:ok, project} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    %{ws: ws, project: project, n: n}
  end

  defp signed_in(conn, email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    conn = post(conn, "/login/account", %{"email" => email, "password" => @password})
    {recycle(conn), user}
  end

  # The CSRF token in the page's sign-out form is per-session; everything else
  # must match byte for byte.
  defp normalize(body), do: Regex.replace(~r/value="[^"]{20,}"/, body, ~s(value="CSRF"))

  test "a member is redirected (302) to the default project/dataset Studio", ctx do
    {conn, user} = signed_in(ctx.conn, "bw-member-#{ctx.n}@example.com")
    {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, user.id, "member", "user")

    conn = get(conn, "/w/#{ctx.ws.slug}")

    assert conn.status == 302
    assert redirected_to(conn) == "/w/#{ctx.ws.slug}/p/site/d/production/studio"
  end

  test "the redirect keeps the query string", ctx do
    {conn, user} = signed_in(ctx.conn, "bw-member-q-#{ctx.n}@example.com")
    {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, user.id, "member", "user")

    conn = get(conn, "/w/#{ctx.ws.slug}?lang=nb")
    assert redirected_to(conn) == "/w/#{ctx.ws.slug}/p/site/d/production/studio?lang=nb"
  end

  test "a signed-in non-member and an unknown slug get the IDENTICAL not-a-member page, the same one /w/:ws/p/... renders",
       ctx do
    # The non-member holds a seat elsewhere, as the owner's probe did.
    {:ok, home} = Tenancy.create_workspace(%{slug: "bw-home-#{ctx.n}", name: "Home"})
    {:ok, _} = Tenancy.create_project(home, %{slug: "default", name: "Default"})
    {conn, user} = signed_in(ctx.conn, "bw-outsider-#{ctx.n}@example.com")
    {:ok, _} = TenancyAuth.create_membership(home.id, user.id, "admin", "user")

    real = get(conn, "/w/#{ctx.ws.slug}")
    unknown = get(recycle(real), "/w/bw-nonexistent-#{ctx.n}")
    deep = get(recycle(unknown), "/w/#{ctx.ws.slug}/p/site/d/production/studio")

    for resp <- [real, unknown, deep] do
      assert resp.status == 403
      assert resp.resp_body =~ "not a member of this workspace"
      assert get_resp_header(resp, "content-type") |> Enum.any?(&(&1 =~ "text/html"))
    end

    assert normalize(real.resp_body) == normalize(unknown.resp_body)
    assert normalize(real.resp_body) == normalize(deep.resp_body)
  end

  test "signed out: real and unknown slugs both go to sign-in with return_to", ctx do
    real = get(ctx.conn, "/w/#{ctx.ws.slug}")
    unknown = get(scoped_conn(), "/w/bw-nonexistent-#{ctx.n}")

    assert redirected_to(real) == "/login?return_to=" <> URI.encode_www_form("/w/#{ctx.ws.slug}")

    assert redirected_to(unknown) ==
             "/login?return_to=" <> URI.encode_www_form("/w/bw-nonexistent-#{ctx.n}")
  end

  test "a member of a workspace with no project yet gets a 404, not a redirect loop", ctx do
    {:ok, empty} = Tenancy.create_workspace(%{slug: "bw-empty-#{ctx.n}", name: "Empty"})
    {conn, user} = signed_in(ctx.conn, "bw-empty-#{ctx.n}@example.com")
    {:ok, _} = TenancyAuth.create_membership(empty.id, user.id, "member", "user")

    conn = get(conn, "/w/#{empty.slug}")
    assert conn.status == 404
  end
end
