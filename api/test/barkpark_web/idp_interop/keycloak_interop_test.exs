defmodule BarkparkWeb.KeycloakInteropTest do
  @moduledoc """
  LIVE IdP interop — the self-hosted leg of SSO verification. Drives Barkpark's
  OIDC relying-party and SAML SP through full handshakes against a REAL
  Keycloak (an independent IdP implementation), simulating the browser with an
  HTTP client. Proves interop beyond the in-repo mocks with zero external
  accounts.

  Opt-in: excluded from the default suite (`@moduletag :idp_interop`). Run via

      scripts/idp-interop.sh                # boots Keycloak, runs this, tears down

  or, with the container already up (see that script's `docker run`):

      mix test --only idp_interop
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :idp_interop

  alias Barkpark.Tenancy
  alias Barkpark.Sso.{Oidc, Saml}

  @kc "http://localhost:8081"
  @realm_url "#{@kc}/realms/barkpark"
  @slug "keycloak-org"
  @username "alice"
  @password "interop-pass"
  @email "alice@interop.example"

  setup do
    case Req.get(@realm_url, retry: false) do
      {:ok, %{status: 200}} ->
        :ok

      _ ->
        raise """
        Keycloak is not reachable on #{@kc}.
        Start it with scripts/idp-interop.sh (which boots the container,
        imports the realm, runs this suite, and tears down).
        """
    end

    {:ok, org} = Tenancy.create_organization(%{slug: @slug, name: "Keycloak Interop"})
    %{org: org}
  end

  test "OIDC: full auth-code + PKCE handshake against live Keycloak mints a session",
       %{conn: conn, org: org} do
    {:ok, _} =
      Oidc.create_connection(%{
        organization_id: org.id,
        issuer: @realm_url,
        client_id: "barkpark-oidc",
        client_secret: "interop-secret",
        authorization_endpoint: "#{@realm_url}/protocol/openid-connect/auth",
        token_endpoint: "#{@realm_url}/protocol/openid-connect/token",
        jwks_uri: "#{@realm_url}/protocol/openid-connect/certs"
      })

    # 1. Our start step: stashes state/nonce/verifier in the session and
    #    redirects the "browser" to Keycloak.
    start = get(conn, "/v1/auth/oidc/#{@slug}/start")
    authorize_url = redirected_to(start, 302)
    assert authorize_url =~ @kc

    # 2. The "browser" logs in at Keycloak and is redirected back with a code.
    {code, state} = kc_oidc_login(authorize_url)

    # 3. Our callback: real back-channel code exchange + JWKS fetch + RS256
    #    verify + claims validation (iss/aud/exp/nonce) — all against Keycloak.
    cb =
      start
      |> recycle()
      |> get("/v1/auth/oidc/#{@slug}/callback", %{"code" => code, "state" => state})

    body = json_response(cb, 201)
    assert body["ok"] == true
    assert body["user"]["email"] == @email
    assert is_binary(body["token"])

    # JIT provisioned + the session token is live.
    assert %Barkpark.Accounts.User{} = Barkpark.Accounts.verify_user_session_token(body["token"])
  end

  test "SAML: full redirect → IdP login → ACS handshake against live Keycloak",
       %{conn: conn, org: org} do
    {:ok, _} =
      Saml.create_connection(%{
        organization_id: org.id,
        idp_entity_id: @realm_url,
        idp_sso_url: "#{@realm_url}/protocol/saml",
        # Trust anchor comes from Keycloak's own published descriptor — nothing
        # hardcoded, exactly how a real operator pastes IdP metadata.
        idp_cert_pem: fetch_idp_cert!()
      })

    # 1. Our start step: deflated HTTP-Redirect AuthnRequest to Keycloak.
    start = get(conn, "/v1/auth/saml/#{@slug}/start")
    redirect_url = redirected_to(start, 302)
    assert redirect_url =~ @kc

    # 2. The "browser" logs in; Keycloak answers with the auto-submit POST
    #    form carrying the signed SAMLResponse.
    saml_response = kc_saml_login(redirect_url)

    # 3. Our ACS: XML-dsig verification against the descriptor cert +
    #    recipient/audience/conditions validation (esaml) + JIT + session.
    acs =
      start
      |> recycle()
      |> post("/v1/auth/saml/#{@slug}/acs", %{"SAMLResponse" => saml_response})

    body = json_response(acs, 201)
    assert body["ok"] == true
    assert body["user"]["email"] == @email
    assert is_binary(body["token"])
  end

  # ── browser simulation ───────────────────────────────────────────────────────

  # Drive Keycloak's login form for an OIDC authorize URL; return {code, state}
  # from the redirect back to our callback.
  defp kc_oidc_login(authorize_url) do
    {:ok, resp2} = submit_login(authorize_url)
    assert resp2.status == 302, "expected Keycloak to redirect after login, got #{resp2.status}"

    location = header!(resp2, "location")
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {Map.fetch!(query, "code"), Map.fetch!(query, "state")}
  end

  # Drive Keycloak's login form for a SAML redirect-binding URL; return the
  # base64 SAMLResponse from the auto-submit form.
  defp kc_saml_login(redirect_url) do
    {:ok, resp2} = submit_login(redirect_url)
    assert resp2.status == 200, "expected Keycloak's SAML auto-submit form, got #{resp2.status}"

    [_, value] = Regex.run(~r/name="SAMLResponse" value="([^"]+)"/, resp2.body)
    value
  end

  # GET the IdP entry URL, parse the login form, POST credentials with the
  # IdP's session cookies. Returns the post-login response.
  defp submit_login(url) do
    {:ok, resp} = Req.get(url, redirect: false, retry: false)
    assert resp.status == 200, "expected Keycloak login form, got #{resp.status}"

    action =
      ~r/action="([^"]+)"/
      |> Regex.run(resp.body)
      |> Enum.at(1)
      |> String.replace("&amp;", "&")

    Req.post(action,
      form: [username: @username, password: @password],
      headers: [{"cookie", cookies(resp)}],
      redirect: false,
      retry: false
    )
  end

  defp cookies(resp) do
    resp.headers
    |> Map.get("set-cookie", [])
    |> Enum.map(&(&1 |> String.split(";") |> hd()))
    |> Enum.join("; ")
  end

  defp header!(resp, name), do: resp.headers |> Map.fetch!(name) |> hd()

  # Pull the IdP signing cert from Keycloak's published SAML descriptor and
  # wrap it as PEM (64-char lines).
  defp fetch_idp_cert! do
    {:ok, resp} = Req.get("#{@realm_url}/protocol/saml/descriptor", retry: false)
    [_, b64] = Regex.run(~r|<ds:X509Certificate>([^<]+)</ds:X509Certificate>|, resp.body)

    wrapped = b64 |> String.replace(~r/\s/, "") |> chunk64()
    "-----BEGIN CERTIFICATE-----\n" <> wrapped <> "\n-----END CERTIFICATE-----\n"
  end

  defp chunk64(s) do
    s
    |> String.codepoints()
    |> Enum.chunk_every(64)
    |> Enum.map_join("\n", &Enum.join/1)
  end
end
