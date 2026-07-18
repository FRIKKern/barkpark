defmodule BarkparkWeb.StudioAnonLockdownTest do
  @moduledoc """
  studio-anonymous-default-lockdown — with `:public_demo_studio` OFF (the
  production default), an anonymous browser cannot enter Studio: the scoped
  Studio dead render redirects to /login, and the LiveScope socket gate
  denies the Default allowance. Members (user or token) still enter, a
  `:docs`-shared scope stays anonymously readable, and the public paper
  reader is untouched. With the flag ON (dev/test default) the demo posture
  is byte-identical to before.

  async: false — flips a global app env per test (restored in on_exit).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  setup do
    prev = Application.get_env(:barkpark, :public_demo_studio)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev) end)
    :ok
  end

  defp flag!(value), do: Application.put_env(:barkpark, :public_demo_studio, value)

  describe "flag OFF (production posture)" do
    setup do
      flag!(false)
      :ok
    end

    test "anonymous scoped Studio redirects to /login with return_to", %{conn: conn} do
      resp = get(conn, "/w/default/p/default/d/production/studio")
      assert redirected_to(resp) =~ "/login?return_to="

      assert redirected_to(resp) =~
               URI.encode_www_form("/w/default/p/default/d/production/studio")
    end

    test "a signed-in Default member still enters", %{conn: conn} do
      {:ok, user} = Accounts.register_user(%{email: "insider@example.com", password: @password})
      %{id: default_ws_id} = Tenancy.get_default_workspace()
      {:ok, _} = TenancyAuth.create_membership(default_ws_id, user.id, "member", "user")

      conn =
        post(conn, "/login/account", %{"email" => "insider@example.com", "password" => @password})

      assert {:ok, _view, _html} =
               conn |> recycle() |> live("/w/default/p/default/d/production/studio")
    end

    test "a session token still enters", %{conn: conn} do
      raw = "lockdown-token-entry"
      {:ok, _} = Barkpark.Auth.create_token(raw, "t", "production", ["read", "write"])

      conn = post(conn, "/login", %{"token" => raw})

      assert {:ok, _view, _html} =
               conn |> recycle() |> live("/w/default/p/default/d/production/studio")
    end

    test "the public paper reader stays anonymously readable", %{conn: conn} do
      # The reader pipeline keeps the literal allowance — an anonymous GET for
      # a Default-scope paper slug must NOT redirect to /login. (404/200 both
      # prove the gate passed; only a redirect would mean the flag leaked.)
      # A raise with plug_status 404 renders 404 in prod; in ConnTest it
      # surfaces via assert_error_sent. A redirect would send no error and
      # fail this assertion — the leak this test guards is still caught.
      assert_error_sent 404, fn ->
        get(conn, "/w/default/p/default/papers/no-such-paper-slug")
      end
    end
  end

  describe "flag ON (dev/demo posture — byte-identical to before)" do
    setup do
      flag!(true)
      :ok
    end

    test "anonymous scoped Studio mounts the demo Default workspace", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, "/w/default/p/default/d/production/studio")
    end
  end
end
