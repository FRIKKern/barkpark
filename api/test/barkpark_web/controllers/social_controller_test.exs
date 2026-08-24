defmodule BarkparkWeb.SocialControllerTest do
  @moduledoc "Social login HTTP surface — start redirect + callback session mint."
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Accounts, Repo, Tenancy, Sso.Social}

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

  test "GET callback with a mismatched state is rejected and audited", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{social_state: "real"})
      |> get("/v1/auth/social/google/callback?code=abc&state=forged")

    assert json_response(conn, 400)

    # era-w8: the failed callback is on the audit trail.
    assert Repo.exists?(
             from e in Barkpark.Audit.Event,
               where: e.action == "sso_login_failed"
           )
  end

  # acpc-w1-sso-list-param-guard. NOT a vacuous green: the shared `setup`
  # enables a real "google" provider row and the session state below MATCHES,
  # so this request clears both cond arms and would reach
  # Social.handle_callback/3 — whose own `when is_binary(code)` guard would
  # raise BELOW the action frame (500). The action-head guard turns it into the
  # same 400 the missing-param fallback clause already returned.
  test "GET callback with a LIST-valued code is 400, not a 500", %{conn: conn} do
    Application.put_env(:barkpark, :social_test, %{
      "email" => "listy@example.com",
      "sub" => "g-9",
      "id" => "g-9"
    })

    conn =
      conn
      |> init_test_session(%{social_state: "s1"})
      |> get("/v1/auth/social/google/callback?code[]=abc&state=s1")

    assert json_response(conn, 400)
    # Fail closed: no user was created and no session minted off the bad request.
    refute Accounts.get_user_by_email("listy@example.com")
  end

  # The missing-param fallback clause (social_controller.ex callback/2 second
  # head) is what the guarded head falls through to — pin it.
  test "GET callback with no code at all is still 400", %{conn: conn} do
    body =
      conn
      |> init_test_session(%{social_state: "s1"})
      |> get("/v1/auth/social/google/callback?state=s1")
      |> json_response(400)

    # §9 envelope, not the bare string this used to answer.
    assert body["error"]["code"] == "malformed"
    assert body["error"]["message"] == "code and state are required"
    assert is_binary(body["error"]["request_id"])
  end

  test "start for an unconfigured provider is 404", %{conn: conn} do
    assert conn |> get("/v1/auth/social/github/start") |> json_response(404)
  end

  test "org-require-MFA: a governed factor-less user is refused a session at the callback (era-w8)",
       %{conn: conn} do
    # A user already governed via workspace membership in a require_mfa org —
    # social login is app-level (no org of its own), so governance comes from
    # the user's existing memberships.
    {:ok, user} =
      Accounts.register_user(%{email: "governed@example.com", password: "correct-horse-battery"})

    {:ok, org} = Tenancy.create_organization(%{slug: "social-strict", name: "social-strict"})
    {:ok, _} = Tenancy.set_organization_require_mfa(org.id, true)
    {:ok, ws} = Tenancy.create_workspace(%{slug: "social-strict-ws", name: "social-strict-ws"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")

    Application.put_env(:barkpark, :social_test, %{
      "email" => "governed@example.com",
      "sub" => "g-7",
      "id" => "g-7"
    })

    conn =
      conn
      |> init_test_session(%{social_state: "s1"})
      |> get("/v1/auth/social/google/callback?code=abc&state=s1")

    body = json_response(conn, 403)
    assert body["error"]["code"] == "mfa_enrolment_required"
    refute body["token"]

    # Fail closed: NO session was minted.
    refute Repo.exists?(from s in Barkpark.Accounts.UserSession, where: s.user_id == ^user.id)
  end
end
