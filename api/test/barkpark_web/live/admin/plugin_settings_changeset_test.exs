defmodule BarkparkWeb.Admin.PluginSettingsChangesetTest do
  @moduledoc """
  Task wbqs-api-changeset-plugin-settings.

  `plugin_settings_live.ex`'s save path discarded the `Ecto.Changeset`
  returned by `persist_rows/2` on a failed row write and flashed only a
  generic "Failed to save settings for <row>." — no indication of WHICH
  field failed. `studio/settings_live.ex` already surfaces this via
  `format_changeset/1` for the identical save-failure flow; this test
  proves plugin_settings_live.ex now does the same.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Plugins.{Settings, SettingsRecord}

  @admin_token "plugin-settings-changeset-admin-token"
  @row_name "bokbasen"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(
        @admin_token,
        "test admin",
        "production",
        ["read", "write", "admin"]
      )

    on_exit(fn ->
      _ = Settings.delete(@row_name)
    end)

    {:ok, conn: conn}
  end

  # A stub `put/3` that always returns an invalid changeset — exercises the
  # `{:error, row, changeset}` branch of `persist_rows/2` without touching
  # Cloak/DB. `validate_required/2` on an empty attrs map fails on
  # `:plugin_name`, `:settings`, and `:updated_at`, giving deterministic
  # field-level errors to assert against.
  defmodule FailingSettings do
    def put(_plugin_name, _settings_map, _opts \\ []) do
      changeset =
        %SettingsRecord{}
        |> SettingsRecord.changeset(%{})
        |> Map.put(:action, :insert)

      {:error, changeset}
    end

    def delete(plugin_name, opts \\ []), do: Settings.delete(plugin_name, opts)
  end

  describe "save failure surfaces the failing field" do
    setup do
      Application.put_env(:barkpark, :plugin_settings_impl, FailingSettings)
      on_exit(fn -> Application.delete_env(:barkpark, :plugin_settings_impl) end)
      :ok
    end

    test "a failed row write flashes the changeset's field-level errors", %{conn: conn} do
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

      # The generic per-row message still leads (back-compat with the
      # existing plugin_settings_live_test.exs assertion) …
      assert html =~ "Failed to save settings for bokbasen."
      # … but now names the failing field, mirroring settings_live.ex's
      # format_changeset/1 output for the identical save-failure flow.
      assert html =~ "settings: can&#39;t be blank" or html =~ "settings: can't be blank"
      refute html =~ "Settings saved."
      assert {:error, :not_found} = Settings.get(@row_name)
    end
  end
end
