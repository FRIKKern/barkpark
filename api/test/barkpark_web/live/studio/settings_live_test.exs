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

    test "an unknown/stale phx event does not crash the LiveView", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/settings")

      render_hook(view, "totally-unknown-stale-event", %{})

      assert Process.alive?(view.pid)
      assert is_binary(render(view))
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

      # First set the plugin_name in the LV state via the load form's
      # phx-change="update_name" — LiveView 1.1+ rejects test forms that
      # override a hidden input's server-rendered value, so we sync state
      # before submitting save.
      view
      |> form("form[phx-submit=load]", %{plugin_name: "myplug"})
      |> render_change()

      view
      |> form("form[phx-submit=save]", %{settings_json: json})
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

  describe "typed renderer driven by settings_schema/0 (bokbasen example)" do
    setup %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      prev = Application.get_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)
      Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen, prev),
          else: Application.delete_env(:barkpark, Barkpark.Plugins.OnixEdit.Bokbasen)
      end)

      {:ok, conn: conn}
    end

    test "loading bokbasen renders 5 typed inputs (no raw textarea)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/settings")

      html =
        view
        |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
        |> render_submit()

      assert html =~ ~s(data-preset="bokbasen")
      assert html =~ ~s(name="api_base")
      assert html =~ ~s(name="oauth_token_url")
      assert html =~ ~s(name="client_id")
      assert html =~ ~s(name="client_secret")
      assert html =~ ~s(name="client_role")
      assert html =~ ~s(type="password")
      refute html =~ ~s(id="settings_json")
    end

    test "submitting the typed form persists via Settings.put", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/settings")

      view
      |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
      |> render_submit()

      view
      |> form(~s(form[data-preset="bokbasen"]), %{
        api_base: "https://api.bokbasen.io",
        oauth_token_url: "https://login.bokbasen.io/oauth2/token",
        client_id: "ui-client-id",
        client_secret: "ui-secret-value",
        client_role: "publisher"
      })
      |> render_submit()

      assert {:ok,
              %{
                "client_id" => "ui-client-id",
                "client_secret" => "ui-secret-value",
                "api_base" => "https://api.bokbasen.io",
                "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
                "client_role" => "publisher"
              }} = Settings.reveal("bokbasen")
    end

    test "loading bokbasen masks secrets but shows URL + role plain", %{conn: conn} do
      Settings.put("bokbasen", %{
        "api_base" => "https://api.bokbasen.io",
        "oauth_token_url" => "https://login.bokbasen.io/oauth2/token",
        "client_id" => "longclientidvalue",
        "client_secret" => "longsecretvalue",
        "client_role" => "publisher"
      })

      {:ok, view, _html} = live(conn, "/studio/settings")

      html =
        view
        |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
        |> render_submit()

      refute html =~ "longclientidvalue"
      refute html =~ "longsecretvalue"
      assert html =~ "********alue"
      assert html =~ "https://api.bokbasen.io"
      assert html =~ ~s(value="publisher")
    end

    test "rejects submit with missing required fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/settings")

      view
      |> form("form[phx-submit=load]", %{plugin_name: "bokbasen"})
      |> render_submit()

      html =
        view
        |> form(~s(form[data-preset="bokbasen"]), %{
          api_base: "",
          oauth_token_url: "",
          client_id: "x",
          client_secret: "y",
          client_role: "publisher"
        })
        |> render_submit()

      assert html =~ "Missing or invalid"
      assert {:error, :not_found} = Settings.get("bokbasen")
    end
  end

  defp audited?(plugin, action) do
    Repo.exists?(
      from a in SettingsAudit,
        where: a.plugin_name == ^plugin and a.action == ^action
    )
  end
end
