defmodule BarkparkWeb.Studio.StudioLiveSharesScopeTenancyTest do
  @moduledoc """
  `arpss-w10-bl-shares-add-instance-wide-scope-hole`.

  `Handlers.Shares.shares_add/2` gates on `Caps.admin?/1` — admin of the
  MOUNTED workspace — and then hands `params["scope"]` to
  `Barkpark.Sharing.add_share/1` without ever comparing that scope's workspace
  against the mounted one. `Sharing.parse_scope/1` accepts any slug, so an
  admin of workspace A could declare a public read share over workspace B.

  ## Why the SESSION arm is the whole test

  The escalation exists ONLY for an account principal. `Caps.admin?/1`'s token
  arm requires `token_admin?/1` — the same `admin` permission that
  `/v1/shares`'s `:require_admin` pipeline requires — so a token principal
  already holds instance-wide declare authority by design, and the LiveView
  path is in fact STRICTER (it also demands a membership). An account admin of
  one workspace holds no such authority: `POST /v1/shares` refuses them.

  A token fixture here would certify nothing, exactly as
  `studio_account_session_scope_test.exs` records for its own defect.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Sharing, Tenancy}

  @dataset "production"

  setup %{conn: conn} do
    ws_a = create_workspace!("arpss-shares-a-#{System.unique_integer([:positive])}")
    proj_a = create_project!(ws_a, "arpss-shares-pa-#{System.unique_integer([:positive])}")
    ws_b = create_workspace!("arpss-shares-b-#{System.unique_integer([:positive])}")
    _proj_b = create_project!(ws_b, "arpss-shares-pb-#{System.unique_integer([:positive])}")

    ensure_default_scope!()

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    {:ok, conn: conn, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp account_admin_session!(conn, ws, role) do
    email = "arpss-shares-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp mount_on(conn, ws, proj) do
    live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio")
  end

  describe "an account admin of ONE workspace" do
    test "cannot declare a share over a DIFFERENT workspace", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b
    } do
      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      render_hook(view, "shares-add", %{
        "scope" => "#{ws_b.slug}/default/#{@dataset}",
        "surfaces" => ["papers"]
      })

      refute Sharing.shared?(ws_b.slug, "default", @dataset, :papers),
             "an admin of #{ws_a.slug} declared a public share over #{ws_b.slug}"
    end

    test "CAN still declare a share over its OWN workspace (the guard is not a blanket deny)",
         %{conn: conn, ws_a: ws_a, proj_a: proj_a} do
      {_user, conn} = account_admin_session!(conn, ws_a, "admin")
      {:ok, view, _html} = mount_on(conn, ws_a, proj_a)

      render_hook(view, "shares-add", %{
        "scope" => "#{ws_a.slug}/#{proj_a.slug}/#{@dataset}",
        "surfaces" => ["papers"]
      })

      assert Sharing.shared?(ws_a.slug, proj_a.slug, @dataset, :papers)
    end
  end
end
