defmodule BarkparkWeb.Layouts.StudioUpdateBannerTest do
  @moduledoc """
  The Studio self-update banner (isu-4): renders in `studio.html.heex`
  directly below the topbar ONLY when the session is admin (the
  `shares_admin?` chrome flag) AND `Barkpark.SelfUpdate.status/0`
  reports `state: :behind`. Any other state — including the `:disabled`
  default when the Checker is not supervised (test env) — must emit no
  banner markup.
  """
  # async: false — mutates Application env (SelfUpdate + Fake client
  # config) and starts the named SelfUpdate.Checker GenServer.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth

  @admin_token "studio-update-banner-admin-token"
  @member_token "studio-update-banner-member-token"

  setup do
    {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()

    # Workspace-bound tokens: create_token also mints the membership row,
    # so both sessions can mount the scoped Studio surface.
    {:ok, _} =
      Auth.create_token(
        @admin_token,
        "banner admin",
        "production",
        ["read", "write", "admin"],
        ws.id
      )

    {:ok, _} =
      Auth.create_token(@member_token, "banner member", "production", ["read", "write"], ws.id)

    :ok
  end

  # Enable self-update with the Fake client primed to report a release
  # far ahead of any real BuildInfo version, start the Checker, and force
  # a synchronous check so `status/0` reports `:behind` during mount.
  defp prime_behind! do
    prior_cfg = Application.get_env(:barkpark, Barkpark.SelfUpdate)
    prior_fake = Application.get_env(:barkpark, Barkpark.SelfUpdate.Client.Fake)

    Application.put_env(
      :barkpark,
      Barkpark.SelfUpdate,
      Keyword.merge(prior_cfg || [], enabled: true, client: Barkpark.SelfUpdate.Client.Fake)
    )

    Application.put_env(:barkpark, Barkpark.SelfUpdate.Client.Fake,
      latest: {:ok, %{release: "999.0.0", tag: "v999.0.0"}},
      digest: {:ok, ["fix: a", "feat: b"]}
    )

    on_exit(fn ->
      restore_env(Barkpark.SelfUpdate, prior_cfg)
      restore_env(Barkpark.SelfUpdate.Client.Fake, prior_fake)
    end)

    start_supervised!(Barkpark.SelfUpdate.Checker)

    status = Barkpark.SelfUpdate.check_now()

    assert status.state == :behind,
           "expected :behind from the primed Fake, got: #{inspect(status)}"

    status
  end

  defp restore_env(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore_env(key, prior), do: Application.put_env(:barkpark, key, prior)

  describe "update banner" do
    test "admin session sees the banner with release pair and digest", %{conn: conn} do
      prime_behind!()

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      assert html =~ ~s|id="bp-update-banner"|
      assert html =~ "Update available — Barkpark 999.0.0"
      assert html =~ "(you run "
      # Digest is non-empty, so the collapsible changelog renders.
      assert html =~ "what changed"
      assert html =~ "fix: a"
      assert html =~ "feat: b"
    end

    test "non-admin session does NOT see the banner even when behind", %{conn: conn} do
      prime_behind!()

      conn = init_test_session(conn, %{"api_token" => @member_token})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      refute html =~ ~s|id="bp-update-banner"|
    end

    test "banner absent when the Checker is not running (:disabled default)", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      refute html =~ ~s|id="bp-update-banner"|
    end
  end
end
