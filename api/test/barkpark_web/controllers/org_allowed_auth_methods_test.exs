defmodule BarkparkWeb.OrgAllowedAuthMethodsTest do
  @moduledoc """
  era-bl-allowed-auth-methods — the ENFORCEMENT surface.

  A member of an SSO-only org who presents a CORRECT password (or a valid
  magic link) is refused with a specific `403 auth_method_not_allowed`, not a
  silent 401 and not a session. A member of an org with no policy — the
  overwhelming majority — takes a byte-identical path to before the column
  existed (zero tax).
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Accounts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")
  defp post_json(conn, path, body), do: conn |> json_conn() |> post(path, Jason.encode!(body))

  defp unique(prefix), do: prefix <> "-" <> String.replace(Ecto.UUID.generate(), "-", "")

  defp register!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  # Put `user` under an org whose allowed-auth-methods policy is `methods`
  # (nil = the org sets no policy at all).
  defp govern!(user, methods) do
    slug = unique("aam")
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})

    if methods do
      {:ok, _} = Tenancy.set_organization_allowed_auth_methods(org.id, methods)
    end

    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: slug <> "-ws"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    org
  end

  describe "POST /v1/auth/login — the password door" do
    test "an SSO-only org refuses a CORRECT password with 403 auth_method_not_allowed", %{
      conn: conn
    } do
      email = unique("sso") <> "@example.com"
      user = register!(email)
      govern!(user, ["sso"])

      body =
        conn
        |> post_json("/v1/auth/login", %{email: email, password: @password})
        |> json_response(403)

      assert body["error"]["code"] == "auth_method_not_allowed"
      assert body["error"]["message"] =~ "Password sign-in is disabled"
      # The refusal must not smuggle a session out on the side.
      refute Map.has_key?(body, "token")
      assert Accounts.list_user_sessions(user) == []
    end

    test "the refusal is a POLICY answer, not a credential oracle: a WRONG password on the " <>
           "same account still gets the generic 401",
         %{conn: conn} do
      email = unique("oracle") <> "@example.com"
      user = register!(email)
      govern!(user, ["sso"])

      body =
        conn
        |> post_json("/v1/auth/login", %{email: email, password: "not-the-password"})
        |> json_response(401)

      assert body["error"]["code"] == "invalid_credentials"
    end

    test "an org with NO policy is unaffected — login still 201s (zero tax)", %{conn: conn} do
      email = unique("plain") <> "@example.com"
      user = register!(email)
      govern!(user, nil)

      body =
        conn
        |> post_json("/v1/auth/login", %{email: email, password: @password})
        |> json_response(201)

      assert is_binary(body["token"])
      assert body["user"]["id"] == user.id
    end

    test "a policy that still names password leaves that door open", %{conn: conn} do
      email = unique("mixed") <> "@example.com"
      user = register!(email)
      govern!(user, ["sso", "password"])

      body =
        conn
        |> post_json("/v1/auth/login", %{email: email, password: @password})
        |> json_response(201)

      assert is_binary(body["token"])
    end

    test "a user with NO membership at all is never governed", %{conn: conn} do
      email = unique("free") <> "@example.com"
      register!(email)

      assert conn
             |> post_json("/v1/auth/login", %{email: email, password: @password})
             |> json_response(201)
    end
  end

  describe "POST /v1/auth/magic-login — the magic-link door" do
    test "a magic link is NOT a side door around an SSO-only policy", %{conn: conn} do
      email = unique("magic") <> "@example.com"
      user = register!(email)
      govern!(user, ["sso"])

      {:ok, token, _} = Accounts.build_login_token(email)

      body =
        conn
        |> post_json("/v1/auth/magic-login", %{token: token})
        |> json_response(403)

      assert body["error"]["code"] == "auth_method_not_allowed"
      assert body["error"]["message"] =~ "Magic-link sign-in is disabled"
      assert Accounts.list_user_sessions(user) == []
    end

    test "a magic link into an unpoliced org still works", %{conn: conn} do
      email = unique("magicok") <> "@example.com"
      user = register!(email)
      govern!(user, nil)

      {:ok, token, _} = Accounts.build_login_token(email)

      assert conn
             |> post_json("/v1/auth/magic-login", %{token: token})
             |> json_response(201)
    end
  end

  describe "the browser doors (/login/account, /auth/magic/:token)" do
    test "password sign-in into an SSO-only org re-renders the form with the policy reason", %{
      conn: conn
    } do
      email = unique("bsso") <> "@example.com"
      user = register!(email)
      govern!(user, ["sso"])

      conn = post(conn, "/login/account", %{"email" => email, "password" => @password})

      assert html_response(conn, 200) =~ "Password sign-in is disabled"
      refute get_session(conn, "user_session")
      assert Accounts.list_user_sessions(user) == []
    end

    test "a magic link in the browser is refused the same way", %{conn: conn} do
      email = unique("bmagic") <> "@example.com"
      user = register!(email)
      govern!(user, ["sso"])

      {:ok, token, _} = Accounts.build_login_token(email)
      conn = get(conn, "/auth/magic/" <> token)

      assert html_response(conn, 200) =~ "Magic-link sign-in is disabled"
      refute get_session(conn, "user_session")
    end

    test "an unpoliced browser password sign-in still mints a session", %{conn: conn} do
      email = unique("bok") <> "@example.com"
      user = register!(email)
      govern!(user, nil)

      conn = post(conn, "/login/account", %{"email" => email, "password" => @password})

      assert redirected_to(conn) == "/studio"
      assert get_session(conn, "user_session")
      refute Accounts.list_user_sessions(user) == []
    end
  end

  test "the refusal lands on the tamper-evident audit trail", %{conn: conn} do
    email = unique("audit") <> "@example.com"
    user = register!(email)
    govern!(user, ["sso"])

    conn |> post_json("/v1/auth/login", %{email: email, password: @password}) |> response(403)

    events =
      Barkpark.Repo.all(
        from e in Barkpark.Audit.Event,
          where: e.subject == ^user.id and e.action == "auth_method_not_allowed"
      )

    assert [event] = events
    assert event.metadata["method"] == "password"
    assert event.metadata["allowed"] == ["sso"]
  end
end
