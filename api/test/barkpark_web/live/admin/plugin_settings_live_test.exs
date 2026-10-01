defmodule BarkparkWeb.Admin.PluginSettingsLiveTest do
  @moduledoc """
  Task barkpark-dbg — admin LV tests for
  `/studio/:dataset/_plugins/:plugin/settings`.

  Covers:

    * Auth gate — unauthenticated and non-admin tokens are redirected.
    * Mount — unknown plugin redirects to /_plugins with a flash; known
      plugin renders one form group per `:group` and one input per
      declared field.
    * Save — submitted form values land in the right `plugin_settings`
      row with flat keys (matching the shape `Bokbasen.Client` reads).
    * Reveal — clicking Reveal calls `Plugins.Settings.reveal/2`,
      decrypts the stored value, and renders it inside the
      `revealed-…` block. Hide re-hides it.
    * Validation — submitting with a required field blank surfaces an
      inline per-field error (not a flash crash) and does not call
      `Plugins.Settings.put/3`.
    * Secret retention — saving with the password input left blank
      preserves the previously-stored value (does not wipe).
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Plugins.Settings

  @admin_token "plugin-settings-admin-token"
  @junior_token "plugin-settings-junior-token"
  @row_name "bokbasen"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(
        @admin_token,
        "test admin",
        "production",
        ["read", "write", "admin"]
      )

    {:ok, _} =
      Auth.create_token(@junior_token, "test junior", "production", ["read"])

    on_exit(fn ->
      _ = Settings.delete(@row_name)
    end)

    {:ok, conn: conn}
  end

  describe "admin gate" do
    test "redirects to /studio without an admin token", %{conn: conn} do
      conn = init_test_session(conn, %{})

      assert {:error, {:redirect, %{to: "/studio"}}} =
               live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")
    end

    test "redirects to /studio for non-admin tokens", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @junior_token})

      assert {:error, {:redirect, %{to: "/studio"}}} =
               live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")
    end
  end

  describe "mount" do
    test "unknown plugin redirects to /_plugins with flash", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})

      assert {:error,
              {:redirect,
               %{
                 to: "/w/default/p/default/d/production/studio/_plugins",
                 flash: %{"error" => msg}
               }}} =
               live(
                 conn,
                 "/w/default/p/default/d/production/studio/_plugins/no-such-plugin/settings"
               )

      assert msg =~ "not registered"
    end

    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "renders one group + one input per declared field", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      assert html =~ "onixedit settings"
      assert html =~ "Bokbasen"

      for name <- ~w(
            bokbasen.api_base
            bokbasen.oauth_token_url
            bokbasen.client_id
            bokbasen.client_secret
            bokbasen.client_role
          ) do
        assert has_element?(view, ~s|[data-test-field="#{name}"]|),
               "form field missing for #{name}"

        assert has_element?(view, ~s|[data-test-input="#{name}"]|),
               "form input missing for #{name}"
      end
    end

    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "masked :string field (client_id) never echoes its stored value into the DOM", %{
      conn: conn
    } do
      {:ok, _} =
        Settings.put(@row_name, %{
          "api_base" => "https://api.bokbasen.io",
          "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
          "client_id" => "leaky-client-id",
          "client_secret" => "shhh-hidden",
          "client_role" => "publisher"
        })

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      # The input still renders (masked as a password box) …
      assert has_element?(view, ~s|[data-test-input="bokbasen.client_id"]|)
      # … but the raw stored value must NOT be serialised into the DOM.
      refute html =~ "leaky-client-id"
      refute render(view) =~ "leaky-client-id"
    end

    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "renders a Save button", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      assert has_element?(view, ~s|button[data-test-action="save"]|)
    end
  end

  describe "save" do
    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "stores submitted values flat in the bokbasen row", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      view
      |> form(~s|[data-test-id="plugin-settings-form"]|,
        settings: %{
          "bokbasen.api_base" => "https://api.bokbasen.io",
          "bokbasen.oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
          "bokbasen.client_id" => "my-client-id",
          "bokbasen.client_secret" => "super-secret",
          "bokbasen.client_role" => "publisher"
        }
      )
      |> render_submit()

      assert {:ok, stored} = Settings.get(@row_name)
      assert stored["api_base"] == "https://api.bokbasen.io"
      assert stored["client_id"] == "my-client-id"
      assert stored["client_secret"] == "super-secret"
      assert stored["client_role"] == "publisher"
    end

    # With the operator allowlist ARMED, a non-operator admin cannot rewrite the
    # stored credentials either: saving an attacker oauth_token_url (keeping the
    # stored client_secret) and pressing test-connection would post that secret
    # to the attacker. Save, clear and test-connection take the reveal's tier.
    @tag :requires_plugins
    test "an armed operator allowlist refuses save, clear and test-connection to a non-operator admin",
         %{conn: conn} do
      stored = %{
        "api_base" => "https://api.bokbasen.io",
        "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
        "client_id" => "id-1",
        "client_secret" => "kept-secret",
        "client_role" => "publisher"
      }

      {:ok, _} = Settings.put(@row_name, stored)

      previous = Application.get_env(:barkpark, :operator_token_ids)
      Application.put_env(:barkpark, :operator_token_ids, [Ecto.UUID.generate()])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:barkpark, :operator_token_ids, previous),
          else: Application.delete_env(:barkpark, :operator_token_ids)
      end)

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      html =
        view
        |> form(~s|[data-test-id="plugin-settings-form"]|,
          settings: %{
            "bokbasen.api_base" => "https://api.bokbasen.io",
            "bokbasen.oauth_token_url" => "https://attacker.example/token",
            "bokbasen.client_id" => "id-1",
            "bokbasen.client_secret" => "",
            "bokbasen.client_role" => "publisher"
          }
        )
        |> render_submit()

      assert html =~ "requires the platform operator"
      assert {:ok, ^stored} = Settings.get(@row_name)

      render_hook(view, "clear", %{"name" => "bokbasen.client_secret"})
      assert {:ok, ^stored} = Settings.get(@row_name)

      assert render_hook(view, "test-connection", %{}) =~ "requires the platform operator"
    end

    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "flashes success after a clean save", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      view
      |> form(~s|[data-test-id="plugin-settings-form"]|,
        settings: %{
          "bokbasen.api_base" => "https://api.bokbasen.io",
          "bokbasen.oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
          "bokbasen.client_id" => "id",
          "bokbasen.client_secret" => "secret",
          "bokbasen.client_role" => "publisher"
        }
      )
      |> render_submit()

      assert render(view) =~ "Settings saved."
    end
  end

  describe "reveal" do
    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "clicking Reveal decrypts and renders the stored value", %{conn: conn} do
      {:ok, _} =
        Settings.put(@row_name, %{
          "api_base" => "https://api.bokbasen.io",
          "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
          "client_id" => "id-1",
          "client_secret" => "shhh-hidden",
          "client_role" => "publisher"
        })

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      refute render(view) =~ "shhh-hidden"

      view
      |> element(~s|button[data-test-action="reveal-bokbasen.client_secret"]|)
      |> render_click()

      assert render(view) =~ "shhh-hidden"
    end

    # The REST twin sits behind RequirePlatformOperator; with the operator
    # allowlist ARMED and this admin not on it, the LiveView reveal refuses too
    # (task-a1c518158045be04).
    @tag :requires_plugins
    test "an armed operator allowlist refuses the reveal to a non-operator admin", %{conn: conn} do
      {:ok, _} =
        Settings.put(@row_name, %{
          "api_base" => "https://api.bokbasen.io",
          "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
          "client_id" => "id-1",
          "client_secret" => "operator-only-secret",
          "client_role" => "publisher"
        })

      previous = Application.get_env(:barkpark, :operator_token_ids)
      Application.put_env(:barkpark, :operator_token_ids, [Ecto.UUID.generate()])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:barkpark, :operator_token_ids, previous),
          else: Application.delete_env(:barkpark, :operator_token_ids)
      end)

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      html =
        view
        |> element(~s|button[data-test-action="reveal-bokbasen.client_secret"]|)
        |> render_click()

      refute html =~ "operator-only-secret"
      assert html =~ "requires the platform operator"
    end

    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "Hide button takes the revealed value back out of the DOM", %{conn: conn} do
      {:ok, _} =
        Settings.put(@row_name, %{
          "api_base" => "https://api.bokbasen.io",
          "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
          "client_id" => "id-1",
          "client_secret" => "shhh-hidden",
          "client_role" => "publisher"
        })

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      view
      |> element(~s|button[data-test-action="reveal-bokbasen.client_secret"]|)
      |> render_click()

      assert render(view) =~ "shhh-hidden"

      view
      |> element(~s|button[data-test-action="hide-bokbasen.client_secret"]|)
      |> render_click()

      refute render(view) =~ "shhh-hidden"
    end

    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "Reveal still surfaces a masked :string field (client_id)", %{conn: conn} do
      {:ok, _} =
        Settings.put(@row_name, %{
          "api_base" => "https://api.bokbasen.io",
          "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
          "client_id" => "reveal-me-id",
          "client_secret" => "shhh-hidden",
          "client_role" => "publisher"
        })

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      refute render(view) =~ "reveal-me-id"

      view
      |> element(~s|button[data-test-action="reveal-bokbasen.client_id"]|)
      |> render_click()

      assert render(view) =~ "reveal-me-id"
    end
  end

  describe "validation" do
    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "missing required field surfaces inline per-field error", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      html =
        view
        |> form(~s|[data-test-id="plugin-settings-form"]|,
          settings: %{
            "bokbasen.api_base" => "",
            "bokbasen.oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
            "bokbasen.client_id" => "id",
            "bokbasen.client_secret" => "secret",
            "bokbasen.client_role" => "publisher"
          }
        )
        |> render_submit()

      assert html =~ ~s|data-test-id="error-bokbasen.api_base"|
      assert html =~ "is required"
      assert {:error, :not_found} = Settings.get(@row_name)
    end

    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "non-URL value in a :url field surfaces inline error", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      html =
        view
        |> form(~s|[data-test-id="plugin-settings-form"]|,
          settings: %{
            "bokbasen.api_base" => "ftp://nope",
            "bokbasen.oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
            "bokbasen.client_id" => "id",
            "bokbasen.client_secret" => "secret",
            "bokbasen.client_role" => "publisher"
          }
        )
        |> render_submit()

      assert html =~ ~s|data-test-id="error-bokbasen.api_base"|
      assert html =~ "must be a URL"
    end
  end

  describe "secret retention" do
    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "saving with the password input blank preserves the existing value", %{
      conn: conn
    } do
      {:ok, _} =
        Settings.put(@row_name, %{
          "api_base" => "https://api.bokbasen.io",
          "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
          "client_id" => "id-keep",
          "client_secret" => "keep-me",
          "client_role" => "publisher"
        })

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      view
      |> form(~s|[data-test-id="plugin-settings-form"]|,
        settings: %{
          "bokbasen.api_base" => "https://api.bokbasen.io",
          "bokbasen.oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
          "bokbasen.client_id" => "id-keep",
          # left blank — the existing encrypted value must survive
          "bokbasen.client_secret" => "",
          "bokbasen.client_role" => "publisher"
        }
      )
      |> render_submit()

      assert {:ok, stored} = Settings.get(@row_name)
      assert stored["client_secret"] == "keep-me"
    end

    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "saving with the masked client_id blank preserves the existing value", %{conn: conn} do
      {:ok, _} =
        Settings.put(@row_name, %{
          "api_base" => "https://api.bokbasen.io",
          "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
          "client_id" => "id-keep",
          "client_secret" => "keep-me",
          "client_role" => "publisher"
        })

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      view
      |> form(~s|[data-test-id="plugin-settings-form"]|,
        settings: %{
          "bokbasen.api_base" => "https://api.bokbasen.io",
          "bokbasen.oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
          # left blank — masked field, existing value must survive
          "bokbasen.client_id" => "",
          "bokbasen.client_secret" => "",
          "bokbasen.client_role" => "publisher"
        }
      )
      |> render_submit()

      assert {:ok, stored} = Settings.get(@row_name)
      assert stored["client_id"] == "id-keep"
      assert stored["client_secret"] == "keep-me"
    end
  end

  # A failed encrypted write (Cloak/DB/changeset) must NOT be reported as a
  # success — the admin would otherwise walk away believing a Bokbasen/Indx
  # credential was stored when nothing persisted. The LV routes settings
  # mutations through `:plugin_settings_impl`, so a stub that always errors on
  # `put/3` exercises the failure branch.
  defmodule FailingSettings do
    alias Barkpark.Plugins.{Settings, SettingsRecord}

    def put(_plugin_name, _settings_map, _opts \\ []) do
      changeset =
        %SettingsRecord{}
        |> SettingsRecord.changeset(%{})
        |> Map.put(:action, :insert)

      {:error, changeset}
    end

    # Not exercised by the save-path test, but keep the seam coherent.
    def delete(plugin_name, opts \\ []), do: Settings.delete(plugin_name, opts)
  end

  describe "save failure surfaces an error, never a false success" do
    setup do
      Application.put_env(:barkpark, :plugin_settings_impl, FailingSettings)
      on_exit(fn -> Application.delete_env(:barkpark, :plugin_settings_impl) end)
      :ok
    end

    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "a failed encrypted write flashes an error and preserves the form", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      html =
        view
        |> form(~s|[data-test-id="plugin-settings-form"]|,
          settings: %{
            "bokbasen.api_base" => "https://api.bokbasen.io",
            "bokbasen.oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
            "bokbasen.client_id" => "id",
            "bokbasen.client_secret" => "super-secret",
            "bokbasen.client_role" => "publisher"
          }
        )
        |> render_submit()

      # The admin is told the save failed …
      assert html =~ "Failed to save settings for bokbasen."
      # … and is NOT falsely told it succeeded.
      refute html =~ "Settings saved."
      # … nothing was persisted …
      assert {:error, :not_found} = Settings.get(@row_name)
      # … and the typed (non-secret) value is preserved so the admin can retry.
      assert has_element?(
               view,
               ~s|[data-test-input="bokbasen.api_base"][value="https://api.bokbasen.io"]|
             )
    end
  end

  # Crash-class closure (#819): PluginSettingsLive had neither dispatch
  # fall-through, so a stale/forged phx event or a stray message
  # FunctionClauseError-crashed the admin session. The trailing catch-alls now
  # no-op both paths.
  describe "dispatch fall-through keeps the session alive" do
    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "an unknown/stale phx event does not crash the LiveView", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      render_hook(view, "totally-unknown-stale-event", %{"leftover" => "true"})

      assert Process.alive?(view.pid)
      assert is_binary(render(view))
    end

    # Plugins-off: the onixedit plugin registered (its bokbasen settings_schema is the fixture)
    @tag :requires_plugins
    test "a stray/unmatched message does not crash the LiveView", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})

      {:ok, view, _html} =
        live(conn, "/w/default/p/default/d/production/studio/_plugins/onixedit/settings")

      send(view.pid, {:some_unrouted_pubsub, %{"payload" => 1}})
      send(view.pid, :bare_unknown_atom)

      assert is_binary(render(view))
      assert Process.alive?(view.pid)
    end
  end
end
