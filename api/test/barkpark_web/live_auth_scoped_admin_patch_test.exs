defmodule BarkparkWeb.LiveAuthScopedAdminPatchTest do
  @moduledoc """
  LiveView authz sweep (r4a): `LiveAuth.:scoped_admin` decided ONCE, at mount.

  `on_mount` hooks do not re-run on a live patch. A client may `live_patch` to
  any URL that routes to the SAME LiveView in the SAME live_session, and
  `/w/:workspace_slug/...` is a param of that route. So an owner/admin of
  workspace A (any workspace — they can create their own) who is only a plain
  member of workspace B could mount `/w/A/p/x/studio/settings` (admin check
  passes against A), then patch to `/w/B/p/y/studio/settings`.
  `LiveScope`'s handle_params hook re-checks READ for B and lets it through,
  and the page now runs as an admin page for B — SettingsLive loads B's
  settings, ChatLive lists and replays B's chat sessions.

  The fix re-runs the target-workspace admin check in a handle_params hook
  whenever the URL's workspace slug moves away from the one admitted.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    ensure_default_scope!()
    suffix = System.unique_integer([:positive])

    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "patch-a-#{suffix}", name: "Own A"})
    {:ok, _} = Tenancy.create_project(ws_a, %{slug: "default", name: "Default"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "patch-b-#{suffix}", name: "Victim B"})
    {:ok, _} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    {:ok, conn: conn, ws_a: ws_a, ws_b: ws_b}
  end

  defp user_conn!(conn, memberships) do
    email = "patch-user-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    Enum.each(memberships, fn {ws, role} ->
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    end)

    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(conn, %{"user_session" => raw})
  end

  defp token_conn!(conn, memberships) do
    raw = "patch-tok-#{System.unique_integer([:positive])}"

    {:ok, tok} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "patch token",
        dataset: @dataset,
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    Enum.each(memberships, fn {ws, role} ->
      {:ok, _} = TenancyAuth.create_membership(ws.id, tok.id, role)
    end)

    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp current_ws_id(view), do: :sys.get_state(view.pid).socket.assigns[:current_workspace].id

  for surface <- ["settings", "chat-hosts"] do
    describe "#{surface}: admin of A, plain member of B" do
      test "USER session: a live patch into B is refused", %{conn: conn, ws_a: a, ws_b: b} do
        conn = user_conn!(conn, [{a, "owner"}, {b, "member"}])
        {:ok, view, _} = live(conn, "/w/#{a.slug}/p/default/studio/#{unquote(surface)}")
        assert current_ws_id(view) == a.id

        result = render_patch(view, "/w/#{b.slug}/p/default/studio/#{unquote(surface)}")

        assert match?({:error, {:redirect, _}}, result) or
                 match?({:error, {:live_redirect, _}}, result),
               "the patch into B ran as an admin page for B: #{inspect(result, limit: 3)}"
      end

      test "TOKEN session: a live patch into B is refused", %{conn: conn, ws_a: a, ws_b: b} do
        conn = token_conn!(conn, [{a, "admin"}, {b, "member"}])
        {:ok, view, _} = live(conn, "/w/#{a.slug}/p/default/studio/#{unquote(surface)}")

        result = render_patch(view, "/w/#{b.slug}/p/default/studio/#{unquote(surface)}")

        assert match?({:error, {:redirect, _}}, result) or
                 match?({:error, {:live_redirect, _}}, result),
               "the patch into B ran as an admin page for B: #{inspect(result, limit: 3)}"
      end
    end
  end

  test "admin of BOTH workspaces may still patch between them (control)", %{
    conn: conn,
    ws_a: a,
    ws_b: b
  } do
    conn = user_conn!(conn, [{a, "owner"}, {b, "admin"}])
    {:ok, view, _} = live(conn, "/w/#{a.slug}/p/default/studio/settings")

    html = render_patch(view, "/w/#{b.slug}/p/default/studio/settings")

    assert is_binary(html)
    assert current_ws_id(view) == b.id
  end
end
