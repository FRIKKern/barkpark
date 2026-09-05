defmodule BarkparkWeb.KeycloakInteropTest do
  @moduledoc """
  LIVE IdP interop — the self-hosted leg of SSO verification. Drives Barkpark's
  OIDC relying-party and SAML SP through full handshakes against a REAL
  Keycloak (an independent IdP implementation), simulating the browser with an
  HTTP client. Proves interop beyond the in-repo mocks with zero external
  accounts — including that login lands a GOVERNED session (org-require-MFA
  refusal at mint, org session-policy expiry; era-w10).

  Opt-in: excluded from the default suite (`@moduletag :idp_interop`). Run via

      scripts/idp-interop.sh                # boots Keycloak, runs this, tears down

  or, with the container already up (see that script's `docker run`):

      mix test --only idp_interop
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  @moduletag :idp_interop

  alias Barkpark.{Accounts, Audit, Repo, Tenancy}
  alias Barkpark.Accounts.UserSession
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

  test "OIDC: a REAL groups claim maps through group_role_mappings to a role (era-w7)",
       %{conn: conn, org: org} do
    # An org workspace to observe the granted role on.
    {:ok, ws} = Barkpark.Tenancy.create_workspace(%{slug: "kc-groups-ws", name: "WS"})
    {:ok, ws} = Barkpark.Tenancy.assign_workspace_to_organization(ws, org.id)

    # alice is in Keycloak group /barkpark-admins; the realm's protocol mapper
    # emits it in the id_token's "groups" claim; this mapping turns it into
    # the admin role.
    {:ok, _} =
      Oidc.create_connection(%{
        organization_id: org.id,
        issuer: @realm_url,
        client_id: "barkpark-oidc",
        client_secret: "interop-secret",
        authorization_endpoint: "#{@realm_url}/protocol/openid-connect/auth",
        token_endpoint: "#{@realm_url}/protocol/openid-connect/token",
        jwks_uri: "#{@realm_url}/protocol/openid-connect/certs",
        group_role_mappings: %{"barkpark-admins" => "admin"}
      })

    start = get(conn, "/v1/auth/oidc/#{@slug}/start")
    {code, state} = kc_oidc_login(redirected_to(start, 302))

    body =
      start
      |> recycle()
      |> get("/v1/auth/oidc/#{@slug}/callback", %{"code" => code, "state" => state})
      |> json_response(201)

    user = Barkpark.Accounts.get_user_by_email(body["user"]["email"])

    role =
      Barkpark.Repo.one(
        from(m in Barkpark.Tenancy.Membership,
          where:
            m.workspace_id == ^ws.id and m.principal_type == "user" and
              m.principal_id == ^user.id,
          select: m.role
        )
      )

    assert role == "admin"
  end

  test "SAML: full redirect → IdP login → ACS handshake against live Keycloak",
       %{conn: conn, org: org} do
    create_saml_connection(org)

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

  test "SAML: IdP-INITIATED login — the Okta-tile flow, no AuthnRequest at all",
       %{conn: conn, org: org} do
    create_saml_connection(org)

    # The user starts AT the IdP (Keycloak's IdP-initiated SSO URL for our
    # client — the same thing clicking an app tile does) and arrives at our
    # ACS with an unsolicited signed response.
    {saml_response, _jar} =
      kc_saml_login_jar("#{@realm_url}/protocol/saml/clients/barkpark")

    acs = post(conn, "/v1/auth/saml/#{@slug}/acs", %{"SAMLResponse" => saml_response})

    body = json_response(acs, 201)
    assert body["ok"] == true
    assert body["user"]["email"] == @email
    assert is_binary(body["token"])
  end

  test "SAML: SP-initiated SINGLE LOGOUT kills the live Keycloak session",
       %{conn: conn, org: org} do
    create_saml_connection(org)

    # 1. SP-initiated login, keeping the IdP browser session (cookie jar).
    start = get(conn, "/v1/auth/saml/#{@slug}/start")
    {saml_response, jar} = kc_saml_login_jar(redirected_to(start, 302))

    token =
      start
      |> recycle()
      |> post("/v1/auth/saml/#{@slug}/acs", %{"SAMLResponse" => saml_response})
      |> json_response(201)
      |> Map.fetch!("token")

    # 2. CONTROL — the IdP session is alive: a fresh AuthnRequest with the same
    #    cookies comes straight back with a SAMLResponse (no login form).
    start2 = scoped_conn() |> get("/v1/auth/saml/#{@slug}/start") |> redirected_to(302)

    {:ok, sso} =
      Req.get(start2, headers: [{"cookie", jar_header(jar)}], redirect: false, retry: false)

    assert sso.status == 200 and sso.body =~ "SAMLResponse"

    # 3. Barkpark logout hands back the SP-initiated LogoutRequest URL.
    logout =
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> delete("/v1/auth/logout")
      |> json_response(200)

    assert logout["slo_url"] =~ @kc

    # 4. The "browser" carries it to Keycloak: the IdP session dies and the
    #    LogoutResponse form (bound for our /slo endpoint) comes back.
    {:ok, slo} =
      Req.get(logout["slo_url"],
        headers: [{"cookie", jar_header(jar)}],
        redirect: false,
        retry: false
      )

    jar = jar_merge(jar, slo)
    assert slo.status == 200 and slo.body =~ "SAMLResponse"

    # 5. PROOF — the same cookies no longer SSO: a fresh AuthnRequest now shows
    #    the login form instead of an instant SAMLResponse.
    start3 = scoped_conn() |> get("/v1/auth/saml/#{@slug}/start") |> redirected_to(302)

    {:ok, after_slo} =
      Req.get(start3, headers: [{"cookie", jar_header(jar)}], redirect: false, retry: false)

    assert after_slo.status == 200
    refute after_slo.body =~ ~r/name="SAMLResponse"/
    assert after_slo.body =~ "password"
  end

  # ── governed sessions (era-w10) ──────────────────────────────────────────────
  #
  # The handshake tests above all run against an UNGOVERNED org. These prove
  # that login lands a GOVERNED session: the same live-IdP flows refuse to
  # mint for a factor-less user under org-require-MFA, and a live-minted
  # token dies under the org session policy.

  test "OIDC governed: org-require-MFA refuses a factor-less user at the live callback (era-w10)",
       %{conn: conn, org: org} do
    govern_with_workspace!(org, "kc-gov-oidc-ws")
    {:ok, _} = Tenancy.set_organization_require_mfa(org.id, true)
    create_oidc_connection(org)

    start = get(conn, "/v1/auth/oidc/#{@slug}/start")
    {code, state} = kc_oidc_login(redirected_to(start, 302))

    cb =
      start
      |> recycle()
      |> get("/v1/auth/oidc/#{@slug}/callback", %{"code" => code, "state" => state})

    # The interop client sends no text/html Accept header, so this is the
    # JSON contract of SessionIssuer.deny_org_mfa_enrolment/4.
    body = json_response(cb, 403)
    assert body["error"]["code"] == "mfa_enrolment_required"
    refute body["token"]

    # Fail closed: JIT provisioned the account, but NO session was minted.
    user = Accounts.get_user_by_email(@email)
    assert user
    refute Repo.exists?(from s in UserSession, where: s.user_id == ^user.id)

    # The block is on the tamper-evident audit trail.
    assert Repo.exists?(
             from e in Audit.Event,
               where:
                 e.category == "auth" and e.action == "mfa_enrolment_required" and
                   e.subject == ^user.id
           )
  end

  test "SAML governed: org-require-MFA refuses a factor-less user at the live ACS (era-w10)",
       %{conn: conn, org: org} do
    govern_with_workspace!(org, "kc-gov-saml-ws")
    {:ok, _} = Tenancy.set_organization_require_mfa(org.id, true)
    create_saml_connection(org)

    start = get(conn, "/v1/auth/saml/#{@slug}/start")
    saml_response = kc_saml_login(redirected_to(start, 302))

    acs =
      start
      |> recycle()
      |> post("/v1/auth/saml/#{@slug}/acs", %{"SAMLResponse" => saml_response})

    body = json_response(acs, 403)
    assert body["error"]["code"] == "mfa_enrolment_required"
    refute body["token"]

    # Fail closed: JIT ran, no session; the block is audited.
    user = Accounts.get_user_by_email(@email)
    assert user
    refute Repo.exists?(from s in UserSession, where: s.user_id == ^user.id)

    assert Repo.exists?(
             from e in Audit.Event,
               where:
                 e.category == "auth" and e.action == "mfa_enrolment_required" and
                   e.subject == ^user.id
           )
  end

  test "OIDC governed: a live-minted session EXPIRES under the org absolute-lifetime policy (era-w10)",
       %{conn: conn, org: org} do
    govern_with_workspace!(org, "kc-gov-policy-ws")
    create_oidc_connection(org)

    start = get(conn, "/v1/auth/oidc/#{@slug}/start")
    {code, state} = kc_oidc_login(redirected_to(start, 302))

    token =
      start
      |> recycle()
      |> get("/v1/auth/oidc/#{@slug}/callback", %{"code" => code, "state" => state})
      |> json_response(201)
      |> Map.fetch!("token")

    # Live before the policy bites…
    assert Accounts.verify_user_session_token(token)

    {:ok, _} =
      Tenancy.set_organization_session_policy(org.id, %{absolute_lifetime_seconds: 3600})

    # …then backdate its birth past the lifetime (org_session_policy_test idiom).
    hash = UserSession.hash_token(token)

    {1, _} =
      from(t in UserSession, where: t.token_hash == ^hash)
      |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), -7200, :second)])

    # Fail closed: the governed token is now dead.
    refute Accounts.verify_user_session_token(token)
  end

  # ── browser simulation ───────────────────────────────────────────────────────
  #
  # A tiny cookie jar (name → value map) stands in for the browser, so a flow
  # can span login → logout → re-login against the SAME IdP session.

  # Drive Keycloak's login form for an OIDC authorize URL; return {code, state}
  # from the redirect back to our callback.
  defp kc_oidc_login(authorize_url) do
    {resp2, _jar} = submit_login(authorize_url)
    assert resp2.status == 302, "expected Keycloak to redirect after login, got #{resp2.status}"

    location = header!(resp2, "location")
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {Map.fetch!(query, "code"), Map.fetch!(query, "state")}
  end

  # Drive Keycloak's login form for a SAML redirect-binding URL; return the
  # base64 SAMLResponse from the auto-submit form.
  defp kc_saml_login(redirect_url) do
    {saml_response, _jar} = kc_saml_login_jar(redirect_url)
    saml_response
  end

  # Same, but also return the IdP cookie jar (the "browser" session).
  defp kc_saml_login_jar(redirect_url) do
    {resp2, jar} = submit_login(redirect_url)
    assert resp2.status == 200, "expected Keycloak's SAML auto-submit form, got #{resp2.status}"

    [_, value] = Regex.run(~r/name="SAMLResponse" value="([^"]+)"/, resp2.body)
    {value, jar}
  end

  # GET the IdP entry URL, parse the login form, POST credentials with the
  # IdP's session cookies. Returns {post-login response, cookie jar}.
  defp submit_login(url) do
    {:ok, resp} = Req.get(url, redirect: false, retry: false)
    assert resp.status == 200, "expected Keycloak login form, got #{resp.status}"
    jar = jar_merge(%{}, resp)

    action =
      ~r/action="([^"]+)"/
      |> Regex.run(resp.body)
      |> Enum.at(1)
      |> String.replace("&amp;", "&")

    {:ok, resp2} =
      Req.post(action,
        form: [username: @username, password: @password],
        headers: [{"cookie", jar_header(jar)}],
        redirect: false,
        retry: false
      )

    {resp2, jar_merge(jar, resp2)}
  end

  # Fold a response's set-cookie headers into the jar (an emptied value drops
  # the cookie — that's how logout clears the identity).
  defp jar_merge(jar, resp) do
    resp.headers
    |> Map.get("set-cookie", [])
    |> Enum.reduce(jar, fn set, acc ->
      [pair | _] = String.split(set, ";")

      case String.split(pair, "=", parts: 2) do
        [name, ""] -> Map.delete(acc, name)
        [name, value] -> Map.put(acc, name, value)
        _ -> acc
      end
    end)
  end

  defp jar_header(jar), do: Enum.map_join(jar, "; ", fn {k, v} -> "#{k}=#{v}" end)

  defp header!(resp, name), do: resp.headers |> Map.fetch!(name) |> hd()

  # THE LAW (charter D27): governance binds through org → workspace →
  # membership. Assign a workspace to the org BEFORE driving the login, or
  # JIT never creates a membership, the user is never governed, and a
  # refusal test silently proves nothing (false green).
  defp govern_with_workspace!(org, slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    ws
  end

  # The org's OIDC connection against the live realm — same shape the
  # handshake test wires inline.
  defp create_oidc_connection(org) do
    {:ok, c} =
      Oidc.create_connection(%{
        organization_id: org.id,
        issuer: @realm_url,
        client_id: "barkpark-oidc",
        client_secret: "interop-secret",
        authorization_endpoint: "#{@realm_url}/protocol/openid-connect/auth",
        token_endpoint: "#{@realm_url}/protocol/openid-connect/token",
        jwks_uri: "#{@realm_url}/protocol/openid-connect/certs"
      })

    c
  end

  # The org's SAML connection, trust-anchored on Keycloak's own published
  # descriptor cert — nothing hardcoded, exactly how a real operator pastes
  # IdP metadata. The realm's /protocol/saml endpoint doubles as SSO and SLO.
  defp create_saml_connection(org) do
    {:ok, c} =
      Saml.create_connection(%{
        organization_id: org.id,
        idp_entity_id: @realm_url,
        idp_sso_url: "#{@realm_url}/protocol/saml",
        idp_slo_url: "#{@realm_url}/protocol/saml",
        idp_cert_pem: fetch_idp_cert!()
      })

    c
  end

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
