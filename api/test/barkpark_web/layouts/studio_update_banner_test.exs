defmodule BarkparkWeb.Layouts.StudioUpdateBannerTest do
  @moduledoc """
  The Studio self-update banner (isu-4): renders in `studio.html.heex`
  directly below the topbar ONLY when the session is an INSTANCE admin
  (the HOST-level `instance_admin?` chrome flag — NOT the
  workspace-scoped `shares_admin?`; see the oracle describe below) AND
  `Barkpark.SelfUpdate.status/0` reports `state: :behind`. Any other state — including the `:disabled`
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

  # Arm the one-click apply Runner (BARKPARK_SELF_UPDATE_APPLY=1 equivalent)
  # for the duration of a test, so the "Update now" button renders.
  defp with_apply_enabled(fun) do
    prior = Application.get_env(:barkpark, Barkpark.SelfUpdate.Runner)

    Application.put_env(
      :barkpark,
      Barkpark.SelfUpdate.Runner,
      Keyword.merge(prior || [], enabled: true)
    )

    try do
      fun.()
    after
      restore_env(Barkpark.SelfUpdate.Runner, prior)
    end
  end

  describe "update bar" do
    test "admin session sees the bar with release pair and digest", %{conn: conn} do
      prime_behind!()

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      assert html =~ ~s|id="bp-update-bar"|
      assert html =~ "New update available — Barkpark"
      assert html =~ "999.0.0"
      assert html =~ "you run "
      # Digest is non-empty, so the collapsible changelog renders.
      assert html =~ "What&#39;s changed"
      assert html =~ "fix: a"
      assert html =~ "feat: b"
    end

    test "curated release notes (isu-w2) win over the digest and link out", %{conn: conn} do
      prime_behind!()

      # Prime the Fake with a curated GitHub Release body + URL for this check.
      Application.put_env(:barkpark, Barkpark.SelfUpdate.Client.Fake,
        latest: {:ok, %{release: "999.0.0", tag: "v999.0.0"}},
        digest: {:ok, ["fix: a", "feat: b"]},
        release_notes:
          {:ok,
           %{
             body: "## Highlights\nShiny new thing",
             url: "https://example.test/releases/v999.0.0"
           }}
      )

      assert Barkpark.SelfUpdate.check_now().notes_body =~ "Shiny new thing"

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      assert html =~ ~s|class="bp-update-notes"|
      assert html =~ "Shiny new thing"
      assert html =~ "Full release notes"
      assert html =~ "https://example.test/releases/v999.0.0"
      # With curated notes present, the raw commit digest is NOT rendered.
      refute html =~ "fix: a"
    end

    test "apply OFF (default) shows 'How to update', not the Update-now button", %{conn: conn} do
      prime_behind!()

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      assert html =~ ~s|data-apply="false"|
      assert html =~ "How to update"
      refute html =~ ~s|data-bp-update-action="apply"|
    end

    test "apply ON shows the Update-now button and carries the raw token", %{conn: conn} do
      prime_behind!()

      with_apply_enabled(fn ->
        conn = init_test_session(conn, %{"api_token" => @admin_token})
        {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

        assert html =~ ~s|data-apply="true"|
        assert html =~ ~s|data-bp-update-action="apply"|
        assert html =~ "Update now"
        # The bar carries the session token so the vanilla fetch can auth.
        assert html =~ ~s|data-token="#{@admin_token}"|
      end)
    end

    test "non-admin session does NOT see the bar even when behind", %{conn: conn} do
      prime_behind!()

      conn = init_test_session(conn, %{"api_token" => @member_token})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      refute html =~ ~s|id="bp-update-bar"|
    end

    test "bar absent when the Checker is not running (:disabled default)", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

      refute html =~ ~s|id="bp-update-bar"|
    end
  end

  # ── task-4cfc68a1e3bec452: the bar rides instance_admin?, not shares_admin? ──
  #
  # arpss-w10 split StudioChrome's single admin flag in two:
  #
  #   * `shares_admin?` — WORKSPACE-scoped seat authority on the MOUNTED
  #     workspace (literally `BarkparkWeb.Studio.Caps.admin?/1`).
  #   * `instance_admin?` — the HOST-level oracle (admin api_token OR an
  #     account with admin authority on the DEFAULT workspace).
  #
  # The self-update bar is host-level: it offers to upgrade the BEAM that
  # every workspace runs on. `layouts/studio.html.heex` was outside that
  # PR's fence, so it kept passing the now-NARROWED `shares_admin?` and the
  # bar vanished for a host operator browsing a workspace where they hold no
  # admin seat. These two tests pin the split at the RENDERED layer — the
  # defect is pure wiring, so asserting on assigns alone would pass on the
  # broken layout and prove nothing.
  #
  # MediaLive is the surface on purpose: StudioLive re-derives `shares_admin?`
  # from `Caps.admin?/1` in its own mount, so the chrome values are only
  # cleanly observable on the other chrome surfaces.
  describe "self-update bar oracle (instance vs. workspace admin)" do
    setup do
      {default_ws, _proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
      foreign_ws = Barkpark.TenancyFixtures.create_workspace!("banner-foreign")

      {:ok, foreign_proj} =
        Barkpark.Tenancy.create_project_with_dataset(foreign_ws, %{name: "banner-foreign-p"})

      %{default_ws: default_ws, foreign_ws: foreign_ws, foreign_proj: foreign_proj}
    end

    defp user_conn_for(memberships) do
      email = "banner-oracle-#{System.unique_integer([:positive])}@example.com"

      {:ok, user} =
        Barkpark.Accounts.register_user(%{email: email, password: "correct-horse-battery"})

      for {ws, role} <- memberships do
        {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
      end

      {:ok, raw} = Barkpark.Accounts.create_user_session_token(user)
      Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{"user_session" => raw})
    end

    defp media_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/production/studio/media"

    test "an INSTANCE admin with no admin seat in the mounted workspace STILL sees the bar (and no Share chrome)",
         %{default_ws: default_ws, foreign_ws: foreign_ws, foreign_proj: foreign_proj} do
      prime_behind!()

      conn = user_conn_for([{default_ws, "admin"}, {foreign_ws, "member"}])
      {:ok, view, html} = live(conn, media_url(foreign_ws, foreign_proj))

      # The socket under test really is the split case: host-level YES,
      # workspace seat NO.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.instance_admin? == true
      assert assigns.shares_admin? == false

      # THE PROOF. Reds on the pre-fix layout (`admin?={assigns[:shares_admin?]}`)
      # — the host operator lost the bar the moment they browsed a workspace
      # they merely belong to.
      assert html =~ ~s|id="bp-update-bar"|
      assert html =~ "New update available — Barkpark"

      # ...while the WORKSPACE-scoped affordance stays correctly hidden. The
      # split must not be re-merged in either direction.
      refute html =~ ~s{phx-click="shares-open"}
    end

    test "a seated WORKSPACE admin who is not an instance admin gets Share chrome and NO bar",
         %{foreign_ws: foreign_ws, foreign_proj: foreign_proj} do
      prime_behind!()

      conn = user_conn_for([{foreign_ws, "admin"}])
      {:ok, view, html} = live(conn, media_url(foreign_ws, foreign_proj))

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.shares_admin? == true
      assert assigns.instance_admin? == false

      assert html =~ ~s{phx-click="shares-open"}
      refute html =~ ~s|id="bp-update-bar"|
    end
  end
end
