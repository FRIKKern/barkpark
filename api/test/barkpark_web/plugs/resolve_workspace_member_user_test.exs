defmodule BarkparkWeb.Plugs.ResolveWorkspaceMemberUserTest do
  @moduledoc """
  task-ce99fd602a697010 — `:member_user` is the positive signal the read gates
  (`QueryController.authed?/1`, `AnonPerspective`) accept for a login-session
  caller. It must be set ONLY when a user (no token) is admitted by
  MEMBERSHIP, and never on the other admits.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Plugs.ResolveWorkspace

  defp user! do
    {:ok, u} =
      Accounts.register_user(%{
        email: "mu-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery staple"
      })

    u
  end

  defp run(ws, assigns, opts \\ []) do
    conn =
      Enum.reduce(
        assigns,
        %{
          build_conn()
          | path_params: %{"workspace_slug" => ws.slug},
            params: %{"workspace_slug" => ws.slug}
        },
        fn {k, v}, c ->
          Plug.Conn.assign(c, k, v)
        end
      )

    ResolveWorkspace.call(conn, ResolveWorkspace.init(opts))
  end

  test "a member user (no token) is marked :member_user" do
    ws = create_workspace!()
    user = user!()
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

    conn = run(ws, current_user: user)
    refute conn.halted
    assert conn.assigns[:member_user] == true
  end

  test "a token caller is never marked, even with a member user beside it" do
    ws = create_workspace!()
    user = user!()
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

    {:ok, token} =
      Auth.create_token("mu-tok-#{System.unique_integer([:positive])}", "t", "production", [
        "read"
      ])

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "member", "api_token")

    conn = run(ws, api_token: token, current_user: user)
    refute conn.halted
    refute conn.assigns[:member_user]
  end

  test "a signed-in NON-member admitted by the anonymous-default allowance is not marked" do
    ws = Barkpark.Tenancy.get_default_workspace() || elem(ensure_default_scope!(), 0)
    user = user!()

    conn = run(ws, [current_user: user], allow_anonymous_default: true)

    if conn.assigns[:anonymous_default_read] do
      refute conn.assigns[:member_user]
    else
      flunk(
        "precondition: the anonymous-default arm did not admit (assigns: #{inspect(Map.keys(conn.assigns))})"
      )
    end
  end

  test "a non-member user is refused and not marked" do
    ws = create_workspace!()
    conn = run(ws, current_user: user!())
    assert conn.halted
    refute conn.assigns[:member_user]
  end
end
