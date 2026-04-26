defmodule BarkparkWeb.Studio.SettingsLiveTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Plugins.Settings
  alias Barkpark.Plugins.SettingsAudit
  alias Barkpark.Repo

  import Ecto.Query

  @admin_token "admin-test-token"
  @junior_token "junior-test-token"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "test junior", "production", ["read"])

    {:ok, conn: conn}
  end

  describe "admin gate" do
    test "redirects to /studio when no session token", %{conn: conn} do
      conn = init_test_session(conn, %{})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/settings")
    end

    test "redirects to /studio when token lacks admin permission", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @junior_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/settings")
    end

    test "renders form for admin token", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, "/studio/settings")
      assert html =~ "Plugin Settings"
      assert html =~ "Plugin name"
    end
  end

  describe "load / save / reveal / delete" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/settings")
      {:ok, view: view}
    end

    test "save valid JSON stores settings and emits write audit", %{view: view} do
      json = ~s({"api_key": "supersecret-1234", "url": "https://x.example"})

      view
      |> form("form[phx-submit=save]", %{plugin_name: "myplug", settings_json: json})
      |> render_submit()

      # row exists
      assert {:ok, %{"api_key" => "supersecret-1234"}} = Settings.reveal("myplug")

      # write audit row
      assert audited?("myplug", "write")
    end

    test "load shows masked values", %{view: view} do
      Settings.put("masktest", %{"api_key" => "longsecretvalue"})

      html =
        view
        |> form("form[phx-submit=load]", %{plugin_name: "masktest"})
        |> render_submit()

      # last 4 chars exposed, prefix masked
      assert html =~ "********alue"
      refute html =~ "longsecretvalue"
    end

    test "reveal fetches unmasked + writes reveal audit", %{view: view} do
      Settings.put("revealme", %{"api_key" => "longsecretvalue"})

      view
      |> form("form[phx-submit=load]", %{plugin_name: "revealme"})
      |> render_submit()

      html = render_click(view, "reveal", %{"plugin_name" => "revealme"})

      assert html =~ "longsecretvalue"
      assert audited?("revealme", "reveal")
    end

    test "delete removes row + writes delete audit", %{view: view} do
      Settings.put("zapme", %{"k" => "v"})

      view
      |> form("form[phx-submit=load]", %{plugin_name: "zapme"})
      |> render_submit()

      render_click(view, "delete", %{"plugin_name" => "zapme"})

      assert {:error, :not_found} = Settings.get("zapme")
      assert audited?("zapme", "delete")
    end
  end

  defp audited?(plugin, action) do
    Repo.exists?(
      from a in SettingsAudit,
        where: a.plugin_name == ^plugin and a.action == ^action
    )
  end
end
