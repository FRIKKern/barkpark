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

  @issuer "https://idp.example.com"
  @client_id "bp-client"

  defmodule MockIdP do
    @behaviour Barkpark.Sso.Oidc.HTTP
    @impl true
    def post_form(_url, _params), do: {:ok, %{"id_token" => fx(:id_token)}}
    @impl true
    def get_json(_url), do: {:ok, %{"keys" => [fx(:jwk)]}}
    defp fx(k), do: Application.get_env(:barkpark, :oidc_test)[k]
  end

  defmodule MockSocialHTTP do
    @behaviour Barkpark.Sso.Social.HTTP
    @impl true
    def post_form(_url, _params), do: {:ok, %{"access_token" => "at"}}
    @impl true
    def get_bearer(_url, _token), do: {:ok, Application.get_env(:barkpark, :social_test)}
  end

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

  # ── the ENTERPRISE sso door (OIDC) ─────────────────────────────────────────
  #
  # The enforcement set is derived from the VOCABULARY, not from the doors the
  # filing happened to list: every term in `Organization.auth_methods/0` has a
  # gated mint site, and every local mint site answers to exactly one term.
  # OIDC and SAML are bound to a per-org connection, so both answer to "sso";
  # SAML's arm lives in `saml_controller_test.exs` beside its signing fixture.

  describe "OIDC callback — the enterprise sso door" do
    setup do
      prev = Application.get_env(:barkpark, :oidc_http)
      Application.put_env(:barkpark, :oidc_http, MockIdP)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, :oidc_http, prev),
          else: Application.delete_env(:barkpark, :oidc_http)

        Application.delete_env(:barkpark, :oidc_test)
      end)

      :ok
    end

    test "an org whose policy OMITS sso refuses the OIDC mint with 403", %{conn: conn} do
      %{slug: slug, email: email} = oidc_org!(["password"])

      body =
        conn
        |> oidc_callback(slug, email)
        |> json_response(403)

      assert body["error"]["code"] == "auth_method_not_allowed"
      assert body["error"]["message"] =~ "Single sign-on is disabled"
      refute body["token"]

      user = Accounts.get_user_by_email(email)
      assert user
      assert Accounts.list_user_sessions(user) == []
    end

    test "an org whose policy INCLUDES sso mints unchanged", %{conn: conn} do
      %{slug: slug, email: email} = oidc_org!(["sso"])

      body = conn |> oidc_callback(slug, email) |> json_response(201)
      assert body["token"]
    end

    test "an org with NO policy mints unchanged (zero tax)", %{conn: conn} do
      %{slug: slug, email: email} = oidc_org!(nil)

      body = conn |> oidc_callback(slug, email) |> json_response(201)
      assert body["token"]
    end
  end

  # ── the CONSUMER oauth door (social) ───────────────────────────────────────
  #
  # `social` is a SEPARATE term from `sso` and that is the point:
  # `Sso.Social.handle_callback/3` find-or-links by email against a consumer
  # provider with NO org binding. If social counted as sso, a personal Google
  # account matching a member's address would satisfy an `["sso"]` policy —
  # exactly the bypass this feature exists to close. The first test below is
  # the one that would go quietly green under the collapsed vocabulary.

  describe "social callback — the consumer oauth door" do
    setup do
      prev = Application.get_env(:barkpark, :social_http)
      Application.put_env(:barkpark, :social_http, MockSocialHTTP)
      {:ok, _} = Barkpark.Sso.Social.enable_provider("google", "cid", "secret")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, :social_http, prev),
          else: Application.delete_env(:barkpark, :social_http)

        Application.delete_env(:barkpark, :social_test)
      end)

      :ok
    end

    test "an SSO-ONLY org refuses consumer Google login — social is not sso", %{conn: conn} do
      email = unique("gsso") <> "@example.com"
      user = register!(email)
      govern!(user, ["sso"])

      body = conn |> social_callback(email) |> json_response(403)

      assert body["error"]["code"] == "auth_method_not_allowed"
      assert body["error"]["message"] =~ "Social sign-in is disabled"
      assert Accounts.list_user_sessions(user) == []
    end

    test "the audit trail records the PRECISE provider, not just the policy term", %{conn: conn} do
      email = unique("gaudit") <> "@example.com"
      user = register!(email)
      govern!(user, ["sso"])

      conn |> social_callback(email) |> response(403)

      events =
        Barkpark.Repo.all(
          from e in Barkpark.Audit.Event,
            where: e.subject == ^user.id and e.action == "auth_method_not_allowed"
        )

      assert [event] = events
      assert event.metadata["method"] == "social"
      assert event.metadata["provider"] == "social:google"
    end

    test "an org whose policy INCLUDES social mints unchanged", %{conn: conn} do
      email = unique("gok") <> "@example.com"
      user = register!(email)
      govern!(user, ["sso", "social"])

      assert conn |> social_callback(email) |> json_response(201)
    end

    test "an org with NO policy mints unchanged (zero tax)", %{conn: conn} do
      email = unique("gplain") <> "@example.com"
      user = register!(email)
      govern!(user, nil)

      assert conn |> social_callback(email) |> json_response(201)
    end
  end

  # ── fixtures for the SSO arms ──────────────────────────────────────────────

  # An org with a real OIDC connection and `methods` as its policy (nil = none).
  # Returns the org slug plus the email the mocked IdP will assert.
  defp oidc_org!(methods) do
    slug = unique("oidcaam")
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})

    if methods do
      {:ok, _} = Tenancy.set_organization_allowed_auth_methods(org.id, methods)
    end

    # jit_provision/3 creates one membership PER WORKSPACE in the org, and
    # membership is what makes the user GOVERNED. An org with no workspace
    # provisions nothing and the policy would be silently inert — the fixture
    # must give the org a workspace or the test proves nothing.
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: slug <> "-ws"})
    {:ok, _ws} = Tenancy.assign_workspace_to_organization(ws, org.id)

    {:ok, _c} =
      Barkpark.Sso.Oidc.create_connection(%{
        organization_id: org.id,
        issuer: @issuer,
        client_id: @client_id,
        client_secret: "s",
        authorization_endpoint: @issuer <> "/authorize",
        token_endpoint: @issuer <> "/token",
        jwks_uri: @issuer <> "/jwks"
      })

    %{org: org, slug: slug, email: slug <> "@example.com"}
  end

  # Sign a real RS256 id_token for `email` and drive the callback with a
  # matching state + verifier, so the request reaches the mint seam for real.
  defp oidc_callback(conn, slug, email) do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    pub = jwk |> JOSE.JWK.to_public_map() |> elem(1) |> Map.put("kid", "k1")

    claims = %{
      "iss" => @issuer,
      "aud" => @client_id,
      "sub" => "oidc-" <> slug,
      "email" => email,
      "exp" => System.system_time(:second) + 300,
      "iat" => System.system_time(:second),
      "nonce" => "n1"
    }

    token =
      jwk
      |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "RS256", "kid" => "k1"})
      |> JOSE.JWS.compact()
      |> elem(1)

    Application.put_env(:barkpark, :oidc_test, %{id_token: token, jwk: pub})

    conn
    |> init_test_session(%{oidc_state: "s1", oidc_verifier: "v1", oidc_nonce: "n1"})
    |> get("/v1/auth/oidc/#{slug}/callback?code=abc&state=s1")
  end

  # Drive the Google callback for `email` with a matching state.
  defp social_callback(conn, email) do
    # `email_verified` is required on the ADOPTION path: these accounts are
    # registered first, so Social.find_or_create_user/2 consults
    # verified_email?/4 before linking. Without it the callback 401s
    # `email_unverified` and never reaches the policy seam.
    Application.put_env(:barkpark, :social_test, %{
      "email" => email,
      "email_verified" => true,
      "sub" => "g-" <> email,
      "id" => "g-" <> email
    })

    conn
    |> init_test_session(%{social_state: "s1"})
    |> get("/v1/auth/social/google/callback?code=abc&state=s1")
  end
end
