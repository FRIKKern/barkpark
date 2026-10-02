defmodule BarkparkWeb.StudioAnonLockdownTest do
  @moduledoc """
  studio-anonymous-default-lockdown — with `:public_demo_studio` OFF (the
  production default), an anonymous browser cannot enter Studio: the scoped
  Studio dead render redirects to /login, and the LiveScope socket gate
  denies the Default allowance. Members (user or token) still enter, a
  `:docs`-shared scope stays anonymously readable, and the public paper
  reader is untouched. With the flag ON (dev/test default) the demo posture
  is byte-identical to before.

  The two halves live in DIFFERENT modules and need different vehicles. The
  dead render is gated by `BarkparkWeb.Plugs.ResolveWorkspace`, so a `get/2`
  measures that half and ONLY that half — `BarkparkWeb.LiveScope` is never
  consulted, because the redirect happens before any socket is opened. The
  socket half is measured in the "LiveScope socket gate" describe below, on an
  already-established anonymous socket moving into the Default scope by live
  navigation (the seam plugs cannot see), in BOTH flag directions.

  async: false — flips a global app env per test (restored in on_exit).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  setup do
    prev = Application.get_env(:barkpark, :public_demo_studio)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev) end)
    :ok
  end

  defp flag!(value), do: Application.put_env(:barkpark, :public_demo_studio, value)

  describe "flag OFF (production posture)" do
    setup do
      flag!(false)
      :ok
    end

    test "anonymous scoped Studio redirects to /login with return_to", %{conn: conn} do
      resp = get(conn, "/w/default/p/default/d/production/studio")
      assert redirected_to(resp) =~ "/login?return_to="

      assert redirected_to(resp) =~
               URI.encode_www_form("/w/default/p/default/d/production/studio")
    end

    test "a signed-in Default member still enters", %{conn: conn} do
      {:ok, user} = Accounts.register_user(%{email: "insider@example.com", password: @password})
      %{id: default_ws_id} = Tenancy.get_default_workspace()
      {:ok, _} = TenancyAuth.create_membership(default_ws_id, user.id, "member", "user")

      conn =
        post(conn, "/login/account", %{"email" => "insider@example.com", "password" => @password})

      assert {:ok, _view, _html} =
               conn |> recycle() |> live("/w/default/p/default/d/production/studio")
    end

    test "a session token still enters", %{conn: conn} do
      raw = "lockdown-token-entry"

      {:ok, _} =
        Barkpark.Auth.create_token(
          raw,
          "t",
          "production",
          ["read", "write"],
          Barkpark.TenancyFixtures.default_workspace_id!()
        )

      conn = post(conn, "/login", %{"token" => raw})

      assert {:ok, _view, _html} =
               conn |> recycle() |> live("/w/default/p/default/d/production/studio")
    end

    test "the public paper reader stays anonymously readable", %{conn: conn} do
      # The reader pipeline keeps the literal allowance — an anonymous GET for
      # a Default-scope paper slug must NOT redirect to /login. (404/200 both
      # prove the gate passed; only a redirect would mean the flag leaked.)
      # A raise with plug_status 404 renders 404 in prod; in ConnTest it
      # surfaces via assert_error_sent. A redirect would send no error and
      # fail this assertion — the leak this test guards is still caught.
      assert_error_sent 404, fn ->
        get(conn, "/w/default/p/default/papers/no-such-paper-slug")
      end
    end
  end

  # ------------------------------------------------------------------
  # The LiveScope SOCKET gate.
  #
  # The dead-render tests above are gated by `BarkparkWeb.Plugs.ResolveWorkspace`
  # — a DIFFERENT module from `BarkparkWeb.LiveScope`. A `live/2` on the Default
  # scope can never reach LiveScope with the flag OFF, because ResolveWorkspace
  # redirects the dead render first, so the socket is never opened. The socket
  # gate is therefore unreachable from a cold anonymous navigation, and asserting
  # it needs an ALREADY-ESTABLISHED anonymous socket that then moves INTO the
  # Default scope by live navigation — the exact seam LiveScope exists for
  # (plugs do not run on a `push_patch`).
  #
  # The vehicle: a `:docs`-shared NON-default workspace grades an anonymous
  # socket `:share_read` under EITHER flag setting (the anonymous-default arm
  # requires `ws.id == default.id`, so it never answers for this workspace).
  # `render_patch` toward `/w/default/...` then re-enters
  # `LiveScope.reauthorize/3` -> `resolve_and_authorize/2` -> `authorize_read/4`
  # with no token and no user — landing exactly on the anonymous-default
  # admission arm, with the flag as the only thing standing between the socket
  # and the Default workspace.
  #
  # Both directions are measured here, on the SAME seam:
  #   flag OFF -> the arm must NOT fire -> fall through to share (Default is not
  #               shared) -> deny -> full-page redirect to /login;
  #   flag ON  -> the arm MUST fire -> the socket lands in Default, anonymously,
  #               and NOT as a share_read (share_access back to nil).
  # ------------------------------------------------------------------
  describe "the LiveScope socket gate on an established anonymous socket" do
    setup %{conn: conn} do
      # arpss-w8: snapshots :shares AND :shares_env (refresh/0 reads both).
      Barkpark.SharingFixtures.snapshot_shares!()

      ws = create_workspace!("anon-lockdown-#{System.unique_integer([:positive])}")
      proj = create_project!(ws, "anon-lockdown-proj")
      {:ok, _} = Tenancy.get_or_create_dataset(proj, "production")

      Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{proj.slug}/production:docs:read")

      %{id: default_ws_id} = Tenancy.get_default_workspace()

      {:ok, conn: conn, ws: ws, proj: proj, default_ws_id: default_ws_id}
    end

    defp socket_of(view), do: :sys.get_state(view.pid).socket

    # An anonymous socket the share arm admits — NOT the Default workspace, so
    # the anonymous-default arm is not what let it in.
    defp mount_anonymous_share_read!(conn, ws, proj) do
      {:ok, view, _html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/production/studio")

      assigns = socket_of(view).assigns
      # PRECONDITION, asserted rather than assumed: the socket really is
      # anonymous and really is graded :share_read. If this ever mounted as a
      # member (or not at all), the patch assertions below would measure
      # nothing.
      assert assigns[:current_user] == nil
      assert assigns[:share_access] == :read
      assert assigns[:current_workspace].id != Tenancy.get_default_workspace().id

      view
    end

    test "flag OFF: patching an anonymous socket into the Default workspace is denied -> /login",
         %{conn: conn, ws: ws, proj: proj} do
      flag!(true)
      view = mount_anonymous_share_read!(conn, ws, proj)

      # The production posture arrives while the socket is ALIVE — the gate that
      # decides the patch is LiveScope's, not any plug's.
      flag!(false)

      assert {:error, {:redirect, %{to: to}}} =
               render_patch(view, "/w/default/p/default/d/production/studio")

      assert to =~ "/login",
             "with :public_demo_studio OFF the LiveScope socket gate must refuse the " <>
               "anonymous-default allowance; got a patch to #{inspect(to)}"
    end

    test "flag ON: the same patch IS admitted, anonymously, as the Default demo allowance",
         %{conn: conn, ws: ws, proj: proj, default_ws_id: default_ws_id} do
      flag!(true)
      view = mount_anonymous_share_read!(conn, ws, proj)

      # Assert the ADMISSION first and by itself: a denial kills the view
      # process, so reading its socket state would fail with an opaque
      # `:sys.get_state` exit instead of naming what broke.
      patched = render_patch(view, "/w/default/p/default/d/production/studio")

      refute match?({:error, {:redirect, _}}, patched),
             "with :public_demo_studio ON the LiveScope socket gate must ADMIT the " <>
               "anonymous-default allowance; got #{inspect(patched)}"

      assigns = socket_of(view).assigns

      assert assigns[:current_workspace].id == default_ws_id,
             "with :public_demo_studio ON the anonymous-default admission arm must " <>
               "admit the socket into the Default workspace"

      assert assigns[:current_user] == nil
      # The grade is :anonymous_default, NOT :share_read — Default carries no
      # share, so a lingering :read here would mean the socket kept the old
      # grade instead of being re-graded by the admission arm.
      assert assigns[:share_access] == nil
    end
  end

  describe "flag ON (dev/demo posture — byte-identical to before)" do
    setup do
      flag!(true)
      :ok
    end

    test "anonymous scoped Studio mounts the demo Default workspace", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, "/w/default/p/default/d/production/studio")
    end
  end
end
