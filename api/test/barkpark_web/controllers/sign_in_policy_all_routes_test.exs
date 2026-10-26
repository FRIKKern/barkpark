defmodule BarkparkWeb.SignInPolicyAllRoutesTest do
  @moduledoc """
  The two settings for the doors that carry no second factor: API token paste
  (`POST /login`), the Barkpark Cloud browser ticket (`GET /login/ticket/:t`)
  and the Studio exchange (`POST /v1/auth/login-tickets/exchange`).

    * `:sign_in_policy_all_routes` on: the org's allowed_auth_methods and
      require_mfa refuse these doors.
    * `:cloud_handoff` false: the handoff doors answer 404.
    * both absent: every door behaves as before.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Auth, Repo, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @admin_token "policy-admin-token-abcdef"
  @user_token "policy-user-token-abcdef"
  @email "editor@policy.example"
  @audience "https://studio.example.com"
  @verifier "dBjftJeZ4CVP-mJ92K9gEhZn7hrdsX2HhhRWqkdOkkZ6"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "policy admin", "production", ["read", "write", "admin"])

    {:ok, user} = Accounts.register_user(%{email: @email, password: "correct horse ok"})
    {:ok, token} = Auth.create_token(@user_token, "policy user", "production", ["read"])
    token |> Ecto.Changeset.change(owner_user_id: user.id) |> Repo.update!()

    on_exit(fn ->
      Application.delete_env(:barkpark, :sign_in_policy_all_routes)
      Application.delete_env(:barkpark, :cloud_handoff)
    end)

    %{user: user}
  end

  defp policy_on, do: Application.put_env(:barkpark, :sign_in_policy_all_routes, true)

  defp govern!(user, attrs) do
    {:ok, org} = Tenancy.create_organization(%{slug: "policy-org", name: "Policy Org"})

    if methods = attrs[:methods],
      do: {:ok, _} = Tenancy.set_organization_allowed_auth_methods(org.id, methods)

    if attrs[:require_mfa], do: {:ok, _} = Tenancy.set_organization_require_mfa(org.id, true)

    {:ok, ws} = Tenancy.create_workspace(%{slug: "policy-ws", name: "Policy WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    org
  end

  defp post_json(path, body, token \\ nil) do
    conn = put_req_header(scoped_conn(), "content-type", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    post(conn, path, Jason.encode!(body))
  end

  defp browser_ticket! do
    resp = post_json("/v1/auth/login-tickets", %{email: @email, role: "member"}, @admin_token)
    json_response(resp, 201)["ticket"]
  end

  defp exchange! do
    challenge = Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false)

    resp =
      post_json(
        "/v1/auth/login-tickets",
        %{
          email: @email,
          role: "member",
          purpose: "exchange",
          audience: @audience,
          code_challenge: challenge
        },
        @admin_token
      )

    ticket = json_response(resp, 201)["ticket"]

    post_json("/v1/auth/login-tickets/exchange", %{
      ticket: ticket,
      audience: @audience,
      code_verifier: @verifier
    })
  end

  defp paste(token) do
    scoped_conn()
    |> put_req_header("accept", "text/html")
    |> post("/login", %{"token" => token})
  end

  describe "sign-in policy setting on, SSO-only org" do
    setup %{user: user} do
      policy_on()
      govern!(user, methods: ["sso"])
      :ok
    end

    test "API token paste is refused", %{user: user} do
      conn = paste(@user_token)
      assert redirected_to(conn) == "/login"
      refute get_session(conn, "api_token_session")
      assert Repo.exists?(audit("auth_method_not_allowed", user.id))
    end

    test "the Cloud browser ticket is refused" do
      conn =
        scoped_conn()
        |> put_req_header("accept", "text/html")
        |> get("/login/ticket/#{browser_ticket!()}")

      assert redirected_to(conn) == "/login"
      refute get_session(conn, "user_session")
    end

    test "the Studio exchange is refused" do
      body = json_response(exchange!(), 403)
      assert body["error"]["code"] == "auth_method_not_allowed"
    end

    test "an API token with no owner is not governed" do
      {:ok, _} = Auth.create_token("policy-app-token-abcdef", "app", "production", ["read"])
      conn = paste("policy-app-token-abcdef")
      assert get_session(conn, "api_token_session")
    end
  end

  describe "sign-in policy setting on, org requires MFA" do
    test "the Studio exchange is refused for a user without a factor", %{user: user} do
      policy_on()
      govern!(user, require_mfa: true)

      body = json_response(exchange!(), 403)
      assert body["error"]["code"] == "mfa_enrolment_required"
    end
  end

  describe "both settings absent" do
    setup %{user: user} do
      govern!(user, methods: ["sso"], require_mfa: true)
      :ok
    end

    test "API token paste signs in as before" do
      conn = paste(@user_token)
      assert redirected_to(conn) == "/studio"
      assert get_session(conn, "api_token_session")
    end

    test "the Cloud browser ticket signs in as before" do
      conn = scoped_conn() |> get("/login/ticket/#{browser_ticket!()}")
      assert redirected_to(conn) == "/studio"
      assert get_session(conn, "user_session")
    end

    test "the Studio exchange signs in as before" do
      assert %{"token" => _} = json_response(exchange!(), 201)
    end
  end

  describe "Cloud handoff setting off" do
    setup do
      Application.put_env(:barkpark, :cloud_handoff, false)
      :ok
    end

    test "the handoff routes answer 404" do
      assert json_response(
               post_json("/v1/auth/login-tickets", %{email: @email}, @admin_token),
               404
             )

      assert json_response(
               post_json("/v1/auth/login-tickets/exchange", %{
                 ticket: "t",
                 audience: @audience,
                 code_verifier: @verifier
               }),
               404
             )

      assert json_response(
               post_json("/v1/auth/cloud-users/deprovision", %{email: @email}, @admin_token),
               404
             )
    end

    test "a token-shaped login ticket is still minted" do
      assert %{"ticket" => _} =
               json_response(post_json("/v1/auth/login-tickets", %{}, @admin_token), 201)
    end
  end

  defp audit(action, user_id) do
    import Ecto.Query
    from e in Barkpark.Audit.Event, where: e.action == ^action and e.subject == ^user_id
  end
end
