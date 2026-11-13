defmodule BarkparkWeb.Admin.PluginSettingsBadBytesTest do
  @moduledoc """
  task-559d2656a69b016a: a dataset segment the database refuses as text (not
  UTF-8, or a NUL) on the plugin settings page names no dataset. It is a 404
  for an admin, where the page redirected with the byte raw in its Location
  (0xFF) or raised Plug.Conn.InvalidHeaderError (a NUL).
  """
  use BarkparkWeb.ConnCase, async: true

  setup %{conn: conn} do
    raw = "plugin-settings-bad-bytes-#{System.unique_integer([:positive])}"
    ws = Barkpark.TenancyFixtures.default_workspace_id!()

    {:ok, _} =
      Barkpark.Auth.create_token(raw, "bad-bytes", "production", ~w(read write admin), ws)

    {:ok, conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  defp settings(dataset, plugin),
    do: "/w/default/p/default/d/#{dataset}/studio/_plugins/#{plugin}/settings"

  test "a dataset that is not text is a 404 for an admin", %{conn: conn} do
    for bad <- ~w(production%FF production%00 %00 %C3%28),
        plugin <- ~w(no-such-plugin onixedit) do
      assert_error_sent(404, fn -> get(conn, settings(bad, plugin)) end)
    end

    # A dataset that is text answers as before: the unknown plugin's redirect.
    conn = get(conn, settings("production", "no-such-plugin"))
    assert redirected_to(conn) == "/w/default/p/default/d/production/studio/_plugins"
  end
end
