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
    def post_form(_url, _params, _headers), do: {:ok, %{"id_token" => fx(:id_token)}}
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
    assert scoped_conn()
           |> get("/v1/auth/oidc/ghost-org/callback?code=x&state=y")
           |> json_response(404)

    # State mismatch → 400, audited.
    assert scoped_conn()
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

    assert scoped_conn()
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

  test "a strict connection refuses a token without exp and records the reason", %{org: org} do
    Barkpark.Sso.OidcConnection
    |> Repo.get_by!(organization_id: org.id)
    |> Ecto.Changeset.change(strict_validation: true)
    |> Repo.update!()

    mock_op(%{"iss" => @issuer, "aud" => @client_id, "nonce" => "n1", "email" => "x@octrl.com"})

    assert scoped_conn()
           |> init_test_session(%{oidc_state: "s1", oidc_nonce: "n1", oidc_verifier: "v1"})
           |> get("/v1/auth/oidc/octrl/callback?code=abc&state=s1")
           |> json_response(401)

    assert Repo.exists?(
             from e in Barkpark.Audit.Event,
               where: e.action == "sso_login_failed" and e.metadata["reason"] == "missing_exp"
           )
  end

  describe "a Studio signs in through the instance's SSO (task-8bdf1b15305af840)" do
    @studio "https://studio.example.com"
    @verifier String.duplicate("v", 43)

    setup do
      prev = Application.get_env(:barkpark, :studio_sso_origins)
      Application.put_env(:barkpark, :studio_sso_origins, [@studio])

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, :studio_sso_origins, prev),
          else: Application.delete_env(:barkpark, :studio_sso_origins)
      end)
    end

    defp challenge, do: Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false)

    defp start_query(return_to),
      do:
        URI.encode_query(%{
          "return_to" => return_to,
          "state" => "studio-state",
          "code_challenge" => challenge()
        })

    # The IdP signs eve in and the callback answers for the Studio that started.
    defp studio_callback(conn) do
      nonce = "n#{System.unique_integer([:positive])}"

      mock_op(%{
        "iss" => @issuer,
        "aud" => @client_id,
        "exp" => System.system_time(:second) + 300,
        "nonce" => nonce,
        "email" => "eve@octrl.com"
      })

      studio = %{
        "to" => @studio <> "/auth/cloud/callback",
        "origin" => @studio,
        "state" => "studio-state",
        "challenge" => challenge()
      }

      conn =
        conn
        |> init_test_session(%{
          oidc_state: "s1",
          oidc_nonce: nonce,
          oidc_verifier: "v1",
          oidc_studio: studio
        })
        |> get("/v1/auth/oidc/octrl/callback?code=#{nonce}&state=s1")

      location = URI.parse(redirected_to(conn, 302))
      assert "#{location.scheme}://#{location.host}#{location.path}" == studio["to"]
      refute get_session(conn, "user_session")
      URI.decode_query(location.query)
    end

    defp exchange(audience, ticket, verifier \\ @verifier) do
      scoped_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/auth/sso/exchange",
        Jason.encode!(%{ticket: ticket, audience: audience, code_verifier: verifier})
      )
    end

    test "start keeps the Studio's return only for an allowed origin", %{conn: conn} do
      allowed =
        get(conn, "/v1/auth/oidc/octrl/start?" <> start_query(@studio <> "/auth/cloud/callback"))

      assert redirected_to(allowed, 302) =~ @issuer <> "/authorize?"
      assert get_session(allowed, :oidc_studio)["origin"] == @studio

      for to <- [
            "https://evil.example.com/cb",
            "https://studio.example.com.evil.test/cb",
            "https://studio.example.com/cb#x",
            "/studio"
          ] do
        refused = get(scoped_conn(), "/v1/auth/oidc/octrl/start?" <> start_query(to))
        assert json_response(refused, 400)["error"]["code"] == "malformed"
      end

      Application.delete_env(:barkpark, :studio_sso_origins)
      refused = get(scoped_conn(), "/v1/auth/oidc/octrl/start?" <> start_query(@studio <> "/cb"))
      assert json_response(refused, 400)
    end

    test "the callback sends a ticket the Studio trades once for a login session", %{conn: conn} do
      %{"ticket" => ticket, "state" => "studio-state"} = studio_callback(conn)

      body = json_response(exchange(@studio, ticket), 201)
      assert body["user"]["email"] == "eve@octrl.com"
      assert Accounts.verify_user_session_token(body["token"]).email == "eve@octrl.com"

      assert json_response(exchange(@studio, ticket), 401)["error"]["code"] == "invalid_ticket"
    end

    for {name, audience, verifier} <- [
          {"audience", "https://evil.example.com", String.duplicate("v", 43)},
          {"verifier", "https://studio.example.com", "x"}
        ] do
      test "a wrong #{name} is refused and the session it carried is revoked", %{conn: conn} do
        %{"ticket" => ticket} = studio_callback(conn)
        [session] = Repo.all(from t in Barkpark.Auth.LoginTicket, select: t.api_token)

        assert json_response(exchange(unquote(audience), ticket, unquote(verifier)), 401)
        refute Accounts.verify_user_session_token(session)
        assert Repo.all(Barkpark.Auth.LoginTicket) == []
      end
    end

    test "the Cloud exchange does not take an SSO ticket", %{conn: conn} do
      %{"ticket" => ticket} = studio_callback(conn)

      assert scoped_conn()
             |> put_req_header("content-type", "application/json")
             |> post(
               "/v1/auth/login-tickets/exchange",
               Jason.encode!(%{ticket: ticket, audience: @studio, code_verifier: @verifier})
             )
             |> json_response(401)
    end
  end

  describe "IdP MFA in a require-MFA org" do
    # An org that requires MFA, with a workspace so JIT-provisioned users are
    # governed, and an OIDC connection with `extra` settings.
    defp mfa_org(slug, extra) do
      {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
      {:ok, _} = Tenancy.set_organization_require_mfa(org.id, true)
      {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: slug <> "-ws"})
      {:ok, _} = Tenancy.assign_workspace_to_organization(ws, org.id)

      {:ok, _c} =
        Oidc.create_connection(
          Map.merge(
            %{
              organization_id: org.id,
              issuer: @issuer,
              client_id: @client_id,
              client_secret: "s",
              authorization_endpoint: @issuer <> "/authorize",
              token_endpoint: @issuer <> "/token",
              jwks_uri: @issuer <> "/jwks"
            },
            extra
          )
        )

      org
    end

    defp mfa_callback(slug, extra_claims) do
      mock_op(
        Map.merge(
          %{
            "iss" => @issuer,
            "aud" => @client_id,
            "exp" => System.system_time(:second) + 300,
            "nonce" => "n1",
            "email" => "editor@#{slug}.com"
          },
          extra_claims
        )
      )

      scoped_conn()
      |> init_test_session(%{oidc_state: "s1", oidc_nonce: "n1", oidc_verifier: "v1"})
      |> get("/v1/auth/oidc/#{slug}/callback?code=abc&state=s1")
    end

    test "amr with mfa on a trusting connection mints an MFA-verified session" do
      mfa_org("idpmfa", %{trust_idp_mfa: true})

      body = mfa_callback("idpmfa", %{"amr" => ["pwd", "mfa"]}) |> json_response(201)
      {_user, session} = Accounts.verify_user_session(body["token"])
      assert session.mfa_verified_at
      assert session.idp_mfa

      # The org MFA gate accepts the session without a Barkpark factor.
      assert scoped_conn()
             |> put_req_header("authorization", "Bearer " <> body["token"])
             |> get("/v1/auth/sessions")
             |> json_response(200)
    end

    test "acr equal to the connection's mfa_acr counts as MFA" do
      mfa_org("idpacr", %{trust_idp_mfa: true, mfa_acr: "urn:example:mfa"})

      body = mfa_callback("idpacr", %{"acr" => "urn:example:mfa"}) |> json_response(201)
      assert {_user, %{idp_mfa: true}} = Accounts.verify_user_session(body["token"])
    end

    test "without amr mfa or the configured acr, the org MFA rule applies as before" do
      mfa_org("idpnomfa", %{trust_idp_mfa: true, mfa_acr: "urn:example:mfa"})

      body =
        mfa_callback("idpnomfa", %{"amr" => ["pwd"], "acr" => "urn:example:pwd"})
        |> json_response(403)

      assert body["error"]["code"] == "mfa_enrolment_required"
    end

    test "a connection that does not trust IdP MFA ignores amr" do
      mfa_org("idpoff", %{})

      body = mfa_callback("idpoff", %{"amr" => ["mfa"]}) |> json_response(403)
      assert body["error"]["code"] == "mfa_enrolment_required"
    end
  end
end
