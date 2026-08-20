defmodule BarkparkWeb.Studio.StudioAccountSessionScopeTest do
  @moduledoc """
  Gyldendal field report #34 (the migration's ONLY critical), slice
  `gfr-w1-studio-principal-kind`: an ACCOUNT session (`user_session`, minted by
  `/login/account` or the cloud SSO handoff) was teleported to the seeded
  Default workspace by the flat→scoped Studio funnel, and the workspace
  switcher then hid the way back.

  Mechanism: both `ScopeResolver` call sites read `conn.assigns[:api_token]`,
  which `OptionalSessionToken` leaves nil for an account session (it assigns
  `:current_user`), so `resolve_workspace(nil)` returned
  `Tenancy.get_default_workspace()`. `StudioChrome.open_scope_menu/1` read the
  same nil and built the switcher from `list_workspaces_for(nil) == []`.

  ## The fixture kind is the whole test

  Every principal below is an ACCOUNT (`user_session`) principal, never a
  token. `scoped_studio_mount_test.exs` already pins the TOKEN arm ("a member's
  flat bookmark resolves to THEIR first workspace") and passed throughout —
  which is exactly why this shipped. A token fixture here would certify
  nothing.

  ## Mutation proof (run on the patched tree, 2026-08-20)

  Reverting ONE half at a time reds exactly that half — neither arm can pass by
  accident, and each half alone would have read as "done":

    * `ScopeResolver.principal(conn)` → `conn.assigns[:api_token]` in
      `studio_redirect_controller.ex` → 3 failures, switcher still green:
        Assertion with == failed
        left:  "/w/default/p/default/d/production/studio/post/p1?desk=drafts"
        right: "/w/gfr-acct-a-4/p/gfr-acct-pa-36/d/production/studio/post/p1?desk=drafts"
    * `(socket.assigns[:api_token] || socket.assigns[:current_user])` →
      `socket.assigns[:api_token]` in `studio_chrome.ex` → 1 failure, the
      redirects still green:
        code:  assert html =~ ws_b.name
        right: "gfr-acct-b-166"

  Unpatched main reds all 5 (every redirect resolved to `/w/default/...`).

  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    # Slugs deliberately sort AFTER "default": a fix that merely threads the
    # principal through and takes `List.first/1` of the slug-ordered
    # memberships would still land on Default for an SSO user, and these
    # fixtures would catch it.
    ws_a = create_workspace!("gfr-acct-a-#{System.unique_integer([:positive])}")
    proj_a = create_project!(ws_a, "gfr-acct-pa-#{System.unique_integer([:positive])}")
    ws_b = create_workspace!("gfr-acct-b-#{System.unique_integer([:positive])}")
    _proj_b = create_project!(ws_b, "gfr-acct-pb-#{System.unique_integer([:positive])}")

    ensure_default_scope!()

    {:ok, conn: conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b}
  end

  # An ACCOUNT principal: a real %User{} with `principal_type: "user"`
  # memberships and a `user_session` in the session — the shape
  # `OptionalSessionToken` resolves to `:current_user`, NOT `:api_token`.
  defp user_session!(conn, memberships) do
    email = "gfr-acct-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    Enum.each(memberships, fn {ws, role} ->
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    end)

    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  describe "flat→scoped funnel with an ACCOUNT session" do
    test "a flat deep link lands in the account's OWN workspace, not Default", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {_user, conn} = user_session!(conn, [{ws_a, "owner"}])

      conn = get(conn, "/studio/#{@dataset}/post/p1?desk=drafts")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio/post/p1?desk=drafts"
    end

    test "the SSO shape — a Default membership alongside — still lands in the real workspace",
         %{conn: conn, ws_a: ws_a, proj_a: proj_a} do
      {default_ws, _default_proj} = ensure_default_scope!()
      {_user, conn} = user_session!(conn, [{ws_a, "owner"}, {default_ws, "owner"}])

      conn = get(conn, "/studio/#{@dataset}")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio"
    end

    test "the Referer's scope still wins when the account is a member of it", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      proj_b = List.first(Tenancy.list_projects(ws_b.id))
      {_user, conn} = user_session!(conn, [{ws_a, "owner"}, {ws_b, "owner"}])

      conn =
        conn
        |> Plug.Conn.put_req_header("referer", "/w/#{ws_b.slug}/p/#{proj_b.slug}/d/#{@dataset}")
        |> get("/studio/#{@dataset}")

      assert redirected_to(conn, 302) ==
               "/w/#{ws_b.slug}/p/#{proj_b.slug}/d/#{@dataset}/studio"

      refute redirected_to(conn, 302) =~ "/w/#{ws_a.slug}/"
      refute redirected_to(conn, 302) =~ "/p/#{proj_a.slug}/"
    end

    test "the flat ADMIN funnel (/studio/settings) resolves the account's workspace too", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      {_user, conn} = user_session!(conn, [{ws_a, "owner"}])

      conn = get(conn, "/studio/settings")

      assert redirected_to(conn, 302) == "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/settings"
    end
  end

  describe "workspace switcher with an ACCOUNT session" do
    test "the switcher lists the account's OTHER workspace (the way back exists)", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      {_user, conn} = user_session!(conn, [{ws_a, "owner"}, {ws_b, "owner"}])

      {:ok, view, _html} =
        live(conn, "/w/#{ws_a.slug}/p/#{proj_a.slug}/d/#{@dataset}/studio")

      html = render_click(view, "scope-menu-toggle", %{})

      assert html =~ ws_a.name
      assert html =~ ws_b.name
    end
  end
end
