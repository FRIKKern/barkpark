defmodule BarkparkWeb.OidcControllerTest do
  @moduledoc "OIDC RP HTTP surface — start redirect + callback session mint (era-w3-oidc-rp)."
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Accounts, Repo, Tenancy}
  alias Barkpark.Sso.Oidc

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

  setup do
    prev = Application.get_env(:barkpark, :oidc_http)
    Application.put_env(:barkpark, :oidc_http, MockIdP)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :oidc_http, prev),
        else: Application.delete_env(:barkpark, :oidc_http)

      Application.delete_env(:barkpark, :oidc_test)
    end)

    {:ok, org} = Tenancy.create_organization(%{slug: "octrl", name: "octrl"})

    {:ok, _c} =
      Oidc.create_connection(%{
        organization_id: org.id,
        issuer: @issuer,
        client_id: @client_id,
        client_secret: "s",
        authorization_endpoint: @issuer <> "/authorize",
        token_endpoint: @issuer <> "/token",
        jwks_uri: @issuer <> "/jwks"
      })

    {:ok, org: org}
  end

  defp mock_op(claims) do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    pub = jwk |> JOSE.JWK.to_public_map() |> elem(1) |> Map.put("kid", "k1")

    token =
      jwk
      |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "RS256", "kid" => "k1"})
      |> JOSE.JWS.compact()
      |> elem(1)

    Application.put_env(:barkpark, :oidc_test, %{id_token: token, jwk: pub})
  end

  test "GET start redirects the browser to the IdP authorize endpoint", %{conn: conn} do
    conn = get(conn, "/v1/auth/oidc/octrl/start")
    assert redirected_to(conn, 302) =~ @issuer <> "/authorize?"
    assert redirected_to(conn, 302) =~ "code_challenge_method=S256"
    # PKCE verifier + state stashed for the callback
    assert get_session(conn, :oidc_verifier)
    assert get_session(conn, :oidc_state)
  end

  test "GET callback with a valid code + matching state mints a user session", %{conn: conn} do
    mock_op(%{
      "iss" => @issuer,
      "aud" => @client_id,
      "exp" => System.system_time(:second) + 300,
      "nonce" => "n1",
      "email" => "eve@octrl.com"
    })

    conn =
      conn
      |> init_test_session(%{oidc_state: "s1", oidc_nonce: "n1", oidc_verifier: "v1"})
      |> get("/v1/auth/oidc/octrl/callback?code=abc&state=s1")

    body = json_response(conn, 201)
    assert body["user"]["email"] == "eve@octrl.com"
    assert body["token"]
    # the minted session is valid
    assert Accounts.verify_user_session_token(body["token"])
  end

  test "GET callback with a mismatched state is rejected", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{oidc_state: "real", oidc_nonce: "n1", oidc_verifier: "v1"})
      |> get("/v1/auth/oidc/octrl/callback?code=abc&state=forged")

    assert json_response(conn, 400)
  end

  test "start for an org without a connection is 404", %{conn: conn} do
    assert conn |> get("/v1/auth/oidc/no-such-org/start") |> json_response(404)
  end

  # acpc-w1-sso-list-param-guard: reachable as a SAME-SESSION REPLAY — the
  # callback is behind a `state == get_session(conn, :oidc_state)` check, but
  # the session cookie is signed-only (endpoint.ex has signing_salt and NO
  # encryption_salt), so a caller who started the flow can read its own
  # oidc_state out of the cookie and replay it with `code[]=`. Before the
  # `when is_binary(code)` head guard, that raised FunctionClauseError inside
  # Barkpark.Sso.Oidc.handle_callback/3 — below the action frame, so Phoenix's
  # ActionClauseError→400 conversion never applied and the caller got a 500.
  test "GET callback with a LIST-valued code is 400, not a 500", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{oidc_state: "s1", oidc_nonce: "n1", oidc_verifier: "v1"})
      |> get("/v1/auth/oidc/octrl/callback?code[]=abc&state=s1")

    assert json_response(conn, 400)
  end

  # The missing-param fallback clause (oidc_controller.ex callback/2 second
  # head) is what the guarded head falls through to — pin it so the guard can
  # never be "fixed" by deleting the fallback.
  test "GET callback with no code at all is still 400", %{conn: conn} do
    body =
      conn
      |> init_test_session(%{oidc_state: "s1", oidc_nonce: "n1", oidc_verifier: "v1"})
      |> get("/v1/auth/oidc/octrl/callback?state=s1")
      |> json_response(400)

    assert body["error"]["code"] == "malformed"
    assert body["error"]["message"] == "code and state are required"
    assert is_binary(body["error"]["request_id"])
  end

  test "org-require-MFA: a governed factor-less user is refused a session at the callback (era-w8)",
       %{conn: conn, org: org} do
    # Make octrl govern: require MFA + give the org a workspace, so the
    # callback's JIT provisioning puts the user under governance.
    {:ok, _} = Tenancy.set_organization_require_mfa(org.id, true)
    {:ok, ws} = Tenancy.create_workspace(%{slug: "octrl-ws", name: "octrl-ws"})
    {:ok, _ws} = Tenancy.assign_workspace_to_organization(ws, org.id)

    mock_op(%{
      "iss" => @issuer,
      "aud" => @client_id,
      "exp" => System.system_time(:second) + 300,
      "nonce" => "n1",
      "email" => "governed@octrl.com"
    })

    conn =
      conn
      |> init_test_session(%{oidc_state: "s1", oidc_nonce: "n1", oidc_verifier: "v1"})
      |> get("/v1/auth/oidc/octrl/callback?code=abc&state=s1")

    body = json_response(conn, 403)
    assert body["error"]["code"] == "mfa_enrolment_required"
    refute body["token"]

    # Fail closed: the account exists (JIT ran) but NO session was minted.
    user = Accounts.get_user_by_email("governed@octrl.com")
    assert user
    refute Repo.exists?(from s in Barkpark.Accounts.UserSession, where: s.user_id == ^user.id)
  end

  test "failed callbacks audit: missing connection, state mismatch, exchange failure (era-w8)",
       %{conn: _conn} do
    # Missing connection → 404, audited.
    assert build_conn()
           |> get("/v1/auth/oidc/ghost-org/callback?code=x&state=y")
           |> json_response(404)

    # State mismatch → 400, audited.
    assert build_conn()
           |> init_test_session(%{oidc_state: "real", oidc_nonce: "n1", oidc_verifier: "v1"})
           |> get("/v1/auth/oidc/octrl/callback?code=abc&state=forged")
           |> json_response(400)

    # Token-exchange/claims failure (nonce mismatch in the id_token) → 401, audited.
    mock_op(%{
      "iss" => @issuer,
      "aud" => @client_id,
      "exp" => System.system_time(:second) + 300,
      "nonce" => "WRONG",
      "email" => "nope@octrl.com"
    })

    assert build_conn()
           |> init_test_session(%{oidc_state: "s1", oidc_nonce: "n1", oidc_verifier: "v1"})
           |> get("/v1/auth/oidc/octrl/callback?code=abc&state=s1")
           |> json_response(401)

    failures = Repo.all(from e in Barkpark.Audit.Event, where: e.action == "sso_login_failed")
    reasons = Enum.map(failures, & &1.metadata["reason"])

    assert length(failures) == 3
    assert Enum.all?(failures, &(&1.metadata["provider"] == "oidc"))
    assert "no_connection" in reasons
    assert "state_mismatch" in reasons
  end
end
