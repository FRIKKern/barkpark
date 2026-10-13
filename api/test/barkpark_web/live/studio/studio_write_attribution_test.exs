defmodule BarkparkWeb.Studio.StudioWriteAttributionTest do
  @moduledoc """
  Owner ruling #51, RQ8 (task-6132833921b7dc36): Studio credits an edit to the
  signed-in account, never to the `user_id` the browser sends.

  `assigns.user_id` is read from the LiveView connect params (the browser's
  localStorage) for presence colour. It used to flow into `hook_opts/1` and
  from there into `revisions.actor_user_id` and the audit actor, so a browser
  could credit its edits to any id it chose.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.StudioLive.Shared

  @dataset "production"

  defp user_session!(conn, ws) do
    email = "rq8-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "owner", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  test "a signed-in Studio credits writes to the account, not the forged connect-param id",
       %{conn: conn} do
    {ws, _proj} = ensure_default_scope!()
    {user, conn} = user_session!(conn, ws)

    conn = put_connect_params(conn, %{"user_id" => "forged-someone-else", "user_name" => "X"})
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))

    socket = :sys.get_state(view.pid).socket

    # Presence identity is still the browser's.
    assert socket.assigns.user_id == "forged-someone-else"

    opts = Shared.hook_opts(socket)
    assert opts[:user_id] == to_string(user.id)
    refute opts[:user_id] == "forged-someone-else"
  end

  test "with no signed-in account the write carries no user id" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, user_id: "forged"}}
    assert Shared.actor_user_id(socket) == nil
  end
end
