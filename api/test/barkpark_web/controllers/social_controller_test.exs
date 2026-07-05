defmodule BarkparkWeb.SocialControllerTest do
  @moduledoc "Social login HTTP surface — start redirect + callback session mint."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Sso.Social}

  defmodule MockHTTP do
    @behaviour Barkpark.Sso.Social.HTTP
    @impl true
    def post_form(_url, _params), do: {:ok, %{"access_token" => "at"}}
    @impl true
    def get_bearer(_url, _token), do: {:ok, Application.get_env(:barkpark, :social_test)}
  end

  setup do
    prev = Application.get_env(:barkpark, :social_http)
    Application.put_env(:barkpark, :social_http, MockHTTP)
    {:ok, _} = Social.enable_provider("google", "cid", "secret")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :social_http, prev),
        else: Application.delete_env(:barkpark, :social_http)

      Application.delete_env(:barkpark, :social_test)
    end)

    :ok
  end

  test "GET start redirects to the provider authorize endpoint", %{conn: conn} do
    conn = get(conn, "/v1/auth/social/google/start")
    loc = redirected_to(conn, 302)
    assert loc =~ "https://accounts.google.com/o/oauth2/v2/auth?"
    assert loc =~ "client_id=cid"
    assert get_session(conn, :social_state)
  end

  test "GET callback with matching state mints a session", %{conn: conn} do
    Application.put_env(:barkpark, :social_test, %{
      "email" => "dave@example.com",
      "sub" => "g-1",
      "id" => "g-1"
    })

    conn =
      conn
      |> init_test_session(%{social_state: "s1"})
      |> get("/v1/auth/social/google/callback?code=abc&state=s1")

    body = json_response(conn, 201)
    assert body["user"]["email"] == "dave@example.com"
    assert body["token"]
    assert Accounts.verify_user_session_token(body["token"])
  end

  test "GET callback with a mismatched state is rejected", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{social_state: "real"})
      |> get("/v1/auth/social/google/callback?code=abc&state=forged")

    assert json_response(conn, 400)
  end

  test "start for an unconfigured provider is 404", %{conn: conn} do
    assert conn |> get("/v1/auth/social/github/start") |> json_response(404)
  end
end
