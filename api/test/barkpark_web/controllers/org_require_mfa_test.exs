defmodule BarkparkWeb.OrgRequireMfaTest do
  @moduledoc """
  era-w2-org-require-mfa — the enforcement surface. A user governed by a
  `require_mfa` org with no factor enrolled is held to enrolment: login still
  succeeds (flagged), the session surface 403s `mfa_enrolment_required`
  except the compliance paths (/me, /logout, enrolment), and the gate opens
  the moment a factor is armed. With no requiring org: byte-identical.
  """
  use BarkparkWeb.ConnCase, async: false

  # TOTP codes come from the window-stable helper ONLY — a code minted inline
  # can expire in the gap before the server validates it (honest-gates S1).
  import Barkpark.TotpTestHelper

  alias Barkpark.Accounts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")
  defp post_json(conn, path, body), do: conn |> json_conn() |> post(path, Jason.encode!(body))

  defp authed(token),
    do: scoped_conn() |> put_req_header("authorization", "Bearer #{token}") |> json_conn()

  defp register_and_login!(conn, email) do
    post_json(conn, "/v1/auth/register", %{email: email, password: @password})

    body =
      post_json(conn, "/v1/auth/login", %{email: email, password: @password})
      |> json_response(201)

    user = Accounts.get_user_by_email(email)
    {user, body}
  end

  defp govern!(user, org_slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: org_slug, name: org_slug})
    {:ok, org} = Tenancy.set_organization_require_mfa(org.id, true)
    {:ok, ws} = Tenancy.create_workspace(%{slug: "#{org_slug}-ws", name: "#{org_slug}-ws"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    org
  end

  # Enrol TOTP on `token`'s session. Returns the recovery codes (a factor a
  # later login can present without colliding with TOTP's one-time-per-window
  # consumption).
  defp enroll_totp!(token) do
    enroll =
      authed(token)
      |> post("/v1/auth/mfa/enroll", Jason.encode!(%{password: @password}))
      |> json_response(200)

    secret = Base.decode32!(enroll["secret"], padding: false)

    verify =
      authed(token)
      |> post(
        "/v1/auth/mfa/verify",
        Jason.encode!(%{
          secret: enroll["secret"],
          code: totp_code_stable!(secret),
          password: @password
        })
      )
      |> json_response(200)

    verify["recovery_codes"]
  end

  describe "a governed user without a factor" do
    setup %{conn: conn} do
      {user, login_body} = register_and_login!(conn, "governed@example.com")
      govern!(user, "governed-org")
      %{user: user, first_login: login_body}
    end

    test "is 403 mfa_enrolment_required on the session surface", %{conn: conn, user: _user} do
      token = relogin!(conn, "governed@example.com")

      resp = authed(token) |> get("/v1/auth/sessions") |> json_response(403)
      assert resp["error"]["code"] == "mfa_enrolment_required"

      resp = authed(token) |> post("/v1/auth/erase", Jason.encode!(%{})) |> json_response(403)
      assert resp["error"]["code"] == "mfa_enrolment_required"
    end

    test "login succeeds and carries the enrolment flag", %{conn: conn} do
      body =
        post_json(conn, "/v1/auth/login", %{email: "governed@example.com", password: @password})
        |> json_response(201)

      assert body["mfa_enrolment_required"] == true
      assert is_binary(body["token"])
    end

    test "/me and /logout stay reachable (the compliance paths)", %{conn: conn} do
      token = relogin!(conn, "governed@example.com")

      assert authed(token) |> get("/v1/auth/me") |> json_response(200)
      assert authed(token) |> delete("/v1/auth/logout") |> json_response(200)
    end

    test "enrolling a factor opens the gate", %{conn: conn} do
      token = relogin!(conn, "governed@example.com")

      # gated before…
      assert authed(token) |> get("/v1/auth/sessions") |> json_response(403)

      # …the enrolment endpoints themselves are exempt and work…
      enroll_totp!(token)

      # …and the same session passes afterwards.
      assert %{"sessions" => _} = authed(token) |> get("/v1/auth/sessions") |> json_response(200)
    end
  end

  describe "no org requires MFA (the zero-tax contract)" do
    test "AC6 golden: ungoverned login body is EXACTLY {token, user:{id,email}} and the surface is open",
         %{conn: conn} do
      {user, login_body} = register_and_login!(conn, "ungoverned@example.com")

      # The zero-tax golden — a login untouched by any org policy carries the
      # pre-epic body verbatim: two top-level keys, the user object exactly two
      # keys. No mfa_enrolment_required, no enrolment/SSO/policy tax bolted on.
      # (Structural, not golden-HTML: the login PAGE was legitimately rebuilt by
      # this epic; the JSON contract is what must stay byte-stable.)
      assert Map.keys(login_body) |> Enum.sort() == ["token", "user"]
      assert Map.keys(login_body["user"]) |> Enum.sort() == ["email", "id"]
      refute Map.has_key?(login_body, "mfa_enrolment_required")
      assert is_binary(login_body["token"])
      assert login_body["user"]["email"] == "ungoverned@example.com"
      assert login_body["user"]["id"] == user.id

      token = login_body["token"]
      assert %{"sessions" => _} = authed(token) |> get("/v1/auth/sessions") |> json_response(200)
    end

    test "a non-requiring org membership changes nothing", %{conn: conn} do
      {user, _} = register_and_login!(conn, "laxmember@example.com")
      {:ok, org} = Tenancy.create_organization(%{slug: "lax-org", name: "lax-org"})
      {:ok, ws} = Tenancy.create_workspace(%{slug: "lax-org-ws", name: "lax-org-ws"})
      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

      token = relogin!(conn, "laxmember@example.com")
      assert %{"sessions" => _} = authed(token) |> get("/v1/auth/sessions") |> json_response(200)
    end
  end

  test "a governed user WITH a factor is not gated and not flagged", %{conn: conn} do
    {user, login_body} = register_and_login!(conn, "armed@example.com")
    [recovery | _] = enroll_totp!(login_body["token"])
    govern!(user, "armed-org")

    body =
      post_json(conn, "/v1/auth/login", %{
        email: "armed@example.com",
        password: @password,
        recovery_code: recovery
      })
      |> json_response(201)

    refute Map.has_key?(body, "mfa_enrolment_required")

    assert %{"sessions" => _} =
             authed(body["token"]) |> get("/v1/auth/sessions") |> json_response(200)
  end

  defp relogin!(conn, email) do
    post_json(conn, "/v1/auth/login", %{email: email, password: @password})
    |> json_response(201)
    |> Map.fetch!("token")
  end
end
