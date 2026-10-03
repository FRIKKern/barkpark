defmodule BarkparkWeb.Studio.MediaLivePublishRecheckTest do
  @moduledoc """
  task-a0d8bdd7b5a518cc: MediaLive's `publish_scope_media` (it mints the
  anonymous `:media` read share for the scope) checked the `shares_admin?`
  assign stamped once at mount. An admin demoted after mount kept that power
  until the socket reconnected. The event now asks `Caps.admin?/1` live.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Sharing, Tenancy}

  setup %{conn: conn} do
    ws = create_workspace!("media-recheck-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, "production")

    email = "media-recheck-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "admin", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)

    conn = Plug.Test.init_test_session(conn, %{"user_session" => raw})
    {:ok, conn: conn, ws: ws, user: user}
  end

  defp path(ws), do: "/w/#{ws.slug}/p/default/d/production/studio/media"

  test "an admin demoted after mount can no longer publish the scope's media", ctx do
    {:ok, view, _} = live(ctx.conn, path(ctx.ws))

    {:ok, _} = Tenancy.Members.update_role(ctx.ws.id, %{type: :user, id: ctx.user.id}, "member")
    render_click(view, "publish_scope_media", %{})

    refute Sharing.media_shared?(ctx.ws.slug, "default", "production"),
           "a demoted member minted the anonymous media share"
  end

  test "CONTROL: a current admin still publishes", ctx do
    {:ok, view, _} = live(ctx.conn, path(ctx.ws))
    render_click(view, "publish_scope_media", %{})
    assert Sharing.media_shared?(ctx.ws.slug, "default", "production")
  end
end
