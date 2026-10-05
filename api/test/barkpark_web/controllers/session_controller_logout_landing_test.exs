defmodule BarkparkWeb.SessionControllerLogoutLandingTest do
  @moduledoc """
  Where a sign-out lands on a host WITHOUT the public demo Studio
  (task-429d3c7559ea8a3c). Its own module, `async: false`, because it swaps
  the node-global `:public_demo_studio` env (AsyncGlobalSeamGuardTest).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts

  describe "POST /logout on a host without the public demo Studio" do
    setup do
      prev = Application.get_env(:barkpark, :public_demo_studio)
      Application.put_env(:barkpark, :public_demo_studio, false)
      on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev) end)
      :ok
    end

    # task-429d3c7559ea8a3c: /studio sent a signed-out browser through the
    # DEFAULT workspace's Studio to /login, which lost the receipt and set a
    # return_to the editor may not be a member of.
    test "lands on /login, and the login page shows the receipt", %{conn: conn} do
      {:ok, user} =
        Accounts.register_user(%{
          email: "logout-landing@example.com",
          password: "correct-horse-battery"
        })

      {:ok, token} = Accounts.create_user_session_token(user)

      out =
        conn
        |> init_test_session(%{"user_session" => token})
        |> post("/logout")

      assert redirected_to(out, 302) == "/login"

      page = out |> recycle() |> get("/login")
      assert html_response(page, 200) =~ "Signed out."
    end
  end
end
