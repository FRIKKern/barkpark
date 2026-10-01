defmodule BarkparkWeb.Admin.PluginAdminOperatorMountTest do
  @moduledoc """
  LiveView authz sweep (r4a): the plugin admin LiveViews applied the
  platform-operator tier to some EVENTS but not to the MOUNT.

  With the operator allowlist armed (`BARKPARK_OPERATOR_*`), REST serves
  `GET /v1/plugins` and `GET /v1/plugins/settings/:name` to the operator only.
  The LiveViews admitted any `:admin`:

    * `PluginsLive` listed the instance-wide registry + run status, and its
      `reload-plugin` / `reload-all` re-ran instance-wide schema upserts and
      seeders;
    * `PluginSettingsLive` decrypted the credential record at mount and
      rendered its non-secret fields (API base URLs, roles).

  Both now refuse a non-operator at mount, and PluginsLive refuses the reload
  events. With the allowlist unset every admin is admitted, as before.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth

  @plugins_path "/w/default/p/default/d/production/studio/_plugins"
  @settings_path "/w/default/p/default/d/production/studio/_plugins/onixedit/settings"

  setup %{conn: conn} do
    raw = "plugin-admin-operator-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "plugin admin", "production", ["read", "write", "admin"])

    previous = Application.get_env(:barkpark, :operator_token_ids)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :operator_token_ids, previous),
        else: Application.delete_env(:barkpark, :operator_token_ids)
    end)

    {:ok, conn: init_test_session(conn, %{"api_token" => raw}), token: token}
  end

  defp arm_allowlist(ids), do: Application.put_env(:barkpark, :operator_token_ids, ids)

  test "armed allowlist: a non-operator admin is refused the plugins list", %{conn: conn} do
    arm_allowlist([Ecto.UUID.generate()])

    assert {:error, {:redirect, %{to: "/studio", flash: %{"error" => msg}}}} =
             live(conn, @plugins_path)

    assert msg =~ "platform operator"
  end

  test "armed allowlist: a non-operator admin is refused plugin settings", %{conn: conn} do
    arm_allowlist([Ecto.UUID.generate()])

    assert {:error, {:redirect, %{to: "/studio", flash: %{"error" => msg}}}} =
             live(conn, @settings_path)

    assert msg =~ "platform operator"
  end

  test "armed allowlist: the operator still mounts the plugins list", %{conn: conn, token: token} do
    arm_allowlist([token.id])
    assert {:ok, _view, html} = live(conn, @plugins_path)
    assert html =~ "plugins-admin"
  end

  test "allowlist unset: an admin still mounts (single-tenant posture)", %{conn: conn} do
    Application.delete_env(:barkpark, :operator_token_ids)
    assert {:ok, _view, _html} = live(conn, @plugins_path)
  end
end
