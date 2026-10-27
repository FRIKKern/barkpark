defmodule Barkpark.Sso.OidcTest do
  @moduledoc "OIDC relying-party against a mock OP (signed id_token, mocked token+JWKS)."
  use Barkpark.DataCase, async: false

  alias Barkpark.{Accounts, Tenancy}
  alias Barkpark.Sso.Oidc

  @issuer "https://idp.example.com"
  @client_id "bp-client"

  # Mock IdP HTTP: token endpoint returns the fixture id_token; JWKS returns the
  # fixture public key; the discovery URL returns the fixture document. Each
  # call is also sent to the test process. Fixtures live in app env, set per test.
  defmodule MockIdP do
    @behaviour Barkpark.Sso.Oidc.HTTP
    @impl true
    def post_form(url, params, headers) do
      send(self(), {:token_request, url, params, headers})
      {:ok, %{"id_token" => fixture(:id_token)}}
    end

    @impl true
    def get_json(url) do
      send(self(), {:get_json, url})

      if String.ends_with?(url, "/.well-known/openid-configuration"),
        do: {:ok, fixture(:discovery)},
        else: {:ok, %{"keys" => [fixture(:jwk)]}}
    end

    defp fixture(k), do: Application.get_env(:barkpark, :oidc_test)[k]
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

    :ok
  end

  defp connection(slug \\ "oidcorg", extra \\ %{}) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})

    {:ok, c} =
      Oidc.create_connection(
        Map.merge(
          %{
            organization_id: org.id,
            issuer: @issuer,
            client_id: @client_id,
            client_secret: "top-secret",
            authorization_endpoint: @issuer <> "/authorize",
            token_endpoint: @issuer <> "/token",
            jwks_uri: @issuer <> "/jwks"
          },
          extra
        )
      )

    {org, c}
  end

  # Sign an id_token with a fresh RSA key and register the matching JWKS.
  defp mock_op(claims, kid \\ "k1") do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    sign_with(jwk, kid, claims)
  end

  defp sign_with(jwk, kid, claims) do
    pub = jwk |> JOSE.JWK.to_public_map() |> elem(1) |> Map.put("kid", kid)

    id_token =
      jwk
      |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "RS256", "kid" => kid})
      |> JOSE.JWS.compact()
      |> elem(1)

    fixtures = Application.get_env(:barkpark, :oidc_test, %{})

    Application.put_env(
      :barkpark,
      :oidc_test,
      Map.merge(fixtures, %{id_token: id_token, jwk: pub})
    )

    id_token
  end

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => @issuer,
        "aud" => @client_id,
        "exp" => System.system_time(:second) + 300,
        "nonce" => "nonce-1",
        "email" => "sso@oidcorg.com"
      },
      overrides
    )
  end

  defp callback(c, opts \\ []) do
    Oidc.handle_callback(
      c,
      "auth-code-123",
      Keyword.merge(
        [redirect_uri: "https://bp/cb", code_verifier: "verifier", nonce: "nonce-1"],
        opts
      )
    )
  end

  describe "handle_callback — the happy path" do
    test "verifies a signed id_token and find-or-creates the authenticated user" do
      {_org, c} = connection()
      mock_op(claims())

      assert {:ok, user, got} = callback(c)
      assert user.email == "sso@oidcorg.com"
      assert got["email"] == "sso@oidcorg.com"
      # user is created + confirmed (the IdP vouched)
      assert Accounts.get_user_by_email("sso@oidcorg.com")
      refute is_nil(Accounts.get_user(user.id).confirmed_at)
    end

    test "an existing user logs in without duplication" do
      {org, c} = connection()
      verify_domain!(org, "oidcorg.com")

      {:ok, existing} =
        Accounts.register_user(%{email: "sso@oidcorg.com", password: "correct horse ok"})

      mock_op(claims())

      assert {:ok, user, _} = callback(c)
      assert user.id == existing.id
    end
  end

  # task-6f7cd94ab61cc688: the org's IdP is tenant-controlled and may assert
  # ANY email. An existing account is adopted only when the org can vouch for
  # it: a seat in one of the org's workspaces, or a verified org domain.
  describe "handle_callback — an existing account the org cannot vouch for" do
    test "another org's user (unverified domain, no seat) is refused, no session subject" do
      {_org, c} = connection()

      {:ok, _victim} =
        Accounts.register_user(%{email: "sso@oidcorg.com", password: "correct horse ok"})

      mock_op(claims())

      assert {:error, :email_not_owned_by_org} = callback(c)
    end

    test "an existing user already seated in the org's workspace is adopted" do
      {org, c} = connection()
      {:ok, ws} = Tenancy.create_workspace(%{slug: "oidcorg-ws", name: "WS"})
      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)

      {:ok, existing} =
        Accounts.register_user(%{email: "sso@oidcorg.com", password: "correct horse ok"})

      {:ok, _} = Tenancy.Auth.create_membership(ws.id, existing.id, "member", "user")
      mock_op(claims())

      assert {:ok, user, _} = callback(c)
      assert user.id == existing.id
    end
  end

  defp verify_domain!(org, domain) do
    {:ok, d} = Barkpark.Sso.Domains.request_verification(org, domain)

    d
    |> Barkpark.Sso.OrgDomain.changeset(%{verified_at: DateTime.utc_now()})
    |> Barkpark.Repo.update!()
  end

  describe "handle_callback — security validations reject bad tokens" do
    test "issuer mismatch → error" do
      {_org, c} = connection()
      mock_op(claims(%{"iss" => "https://evil.example.com"}))
      assert {:error, :issuer_mismatch} = callback(c)
    end

    test "audience mismatch → error" do
      {_org, c} = connection()
      mock_op(claims(%{"aud" => "someone-else"}))
      assert {:error, :audience_mismatch} = callback(c)
    end

    test "expired token → error" do
      {_org, c} = connection()
      mock_op(claims(%{"exp" => System.system_time(:second) - 10}))
      assert {:error, :expired} = callback(c)
    end

    test "nonce mismatch → error" do
      {_org, c} = connection()
      mock_op(claims(%{"nonce" => "different"}))
      assert {:error, :nonce_mismatch} = callback(c)
    end

    test "a token signed by the WRONG key is rejected (JWKS verification)" do
      {_org, c} = connection()
      # sign with key A but publish key B in the JWKS → signature fails
      _real = mock_op(claims())

      wrong =
        JOSE.JWK.generate_key({:rsa, 2048})
        |> JOSE.JWK.to_public_map()
        |> elem(1)
        |> Map.put("kid", "k1")

      current = Application.get_env(:barkpark, :oidc_test)
      Application.put_env(:barkpark, :oidc_test, %{current | jwk: wrong})

      assert {:error, :invalid_id_token} = callback(c)
    end
  end

  describe "authorize_url" do
    test "carries client_id, PKCE challenge, state and nonce" do
      {_org, c} = connection()
      p = Oidc.new_auth_params()
      {:ok, url} = Oidc.authorize_url(c, Map.put(p, :redirect_uri, "https://bp/cb"))

      assert url =~ @issuer <> "/authorize?"
      assert url =~ "client_id=bp-client"
      assert url =~ "code_challenge_method=S256"
      assert url =~ "response_type=code"
      assert URI.decode_query(URI.parse(url).query)["scope"] == "openid email"
    end

    test "carries the connection's configured scopes" do
      {_org, c} = connection("scoped", %{scopes: "openid profile email"})
      p = Map.put(Oidc.new_auth_params(), :redirect_uri, "https://bp/cb")
      {:ok, url} = Oidc.authorize_url(c, p)

      assert URI.decode_query(URI.parse(url).query)["scope"] == "openid profile email"
    end

    test "an Entra connection that trusts IdP MFA requests amr mfa as an essential claim" do
      {_org, c} = connection("mfareq", %{trust_idp_mfa: true, tenant_id: "tid-1"})
      p = Map.put(Oidc.new_auth_params(), :redirect_uri, "https://bp/cb")
      {:ok, url} = Oidc.authorize_url(c, p)

      assert Jason.decode!(URI.decode_query(URI.parse(url).query)["claims"]) == %{
               "id_token" => %{"amr" => %{"essential" => true, "values" => ["mfa"]}}
             }
    end

    test "no claims parameter without trust_idp_mfa or without a tenant id" do
      p = Map.put(Oidc.new_auth_params(), :redirect_uri, "https://bp/cb")

      for {slug, extra} <- [{"nomfa", %{tenant_id: "tid-1"}}, {"notid", %{trust_idp_mfa: true}}] do
        {_org, c} = connection(slug, extra)
        {:ok, url} = Oidc.authorize_url(c, p)
        refute Map.has_key?(URI.decode_query(URI.parse(url).query), "claims")
      end
    end
  end

  describe "strict validation" do
    defp strict(extra \\ %{}), do: connection("strict", Map.put(extra, :strict_validation, true))

    test "a token without exp is refused" do
      {_org, c} = strict()
      mock_op(Map.delete(claims(), "exp"))
      assert {:error, :missing_exp} = callback(c)
    end

    test "a token whose nbf is in the future is refused" do
      {_org, c} = strict()
      mock_op(claims(%{"nbf" => System.system_time(:second) + 600}))
      assert {:error, :not_yet_valid} = callback(c)
    end

    test "a token issued in the future is refused" do
      {_org, c} = strict()
      mock_op(claims(%{"iat" => System.system_time(:second) + 600}))
      assert {:error, :issued_in_future} = callback(c)
    end

    test "time claims within the clock skew are accepted" do
      {_org, c} = strict()
      now = System.system_time(:second)
      mock_op(claims(%{"nbf" => now + 30, "iat" => now + 30, "sub" => "s-1"}))
      assert {:ok, _user, _} = callback(c)
    end

    test "a token from another tenant is refused when the tenant is pinned" do
      {_org, c} = connection("pinned", %{tenant_id: "tenant-a"})
      mock_op(claims(%{"tid" => "tenant-b"}))
      assert {:error, :tenant_mismatch} = callback(c)

      mock_op(claims(%{"tid" => "tenant-a"}))
      assert {:ok, _user, _} = callback(c)
    end

    test "the instance setting turns strict validation on for every connection" do
      Application.put_env(:barkpark, :oidc_strict_validation, true)
      on_exit(fn -> Application.delete_env(:barkpark, :oidc_strict_validation) end)

      {_org, c} = connection()
      mock_op(Map.delete(claims(), "exp"))
      assert {:error, :missing_exp} = callback(c)
    end

    test "a changed email at the IdP signs in to the same account" do
      {_org, c} = strict()
      mock_op(claims(%{"sub" => "pairwise-1", "oid" => "object-1"}))
      assert {:ok, user, _} = callback(c)

      mock_op(
        claims(%{"sub" => "pairwise-1", "oid" => "object-1", "email" => "renamed@oidcorg.com"})
      )

      assert {:ok, again, _} = callback(c)
      assert again.id == user.id
      refute Accounts.get_user_by_email("renamed@oidcorg.com")
    end
  end

  describe "strict validation off" do
    test "an existing connection behaves as before: no exp, future nbf and iat, email matching" do
      {_org, c} = connection()
      future = System.system_time(:second) + 600

      mock_op(
        claims(%{"sub" => "pairwise-1", "nbf" => future, "iat" => future})
        |> Map.delete("exp")
      )

      assert {:ok, user, _} = callback(c)

      # Without strict validation the subject is not stored, so a new email is
      # a new account, as today.
      mock_op(claims(%{"sub" => "pairwise-1", "email" => "renamed@oidcorg.com"}))
      assert {:ok, other, _} = callback(c)
      refute other.id == user.id
      refute Barkpark.Repo.exists?(Barkpark.Sso.SocialIdentity)
    end
  end

  describe "JWKS cache and key rollover" do
    test "a known key is served from the cache; a new kid refetches the JWKS" do
      {org, c} = connection()
      verify_domain!(org, "oidcorg.com")
      key_a = JOSE.JWK.generate_key({:rsa, 2048})

      sign_with(key_a, "rollover-a", claims())
      assert {:ok, _, _} = callback(c)
      assert_received {:get_json, @issuer <> "/jwks"}

      sign_with(key_a, "rollover-a", claims())
      assert {:ok, _, _} = callback(c)
      refute_received {:get_json, _}

      # The IdP rotates to a new signing key.
      mock_op(claims(), "rollover-b")
      assert {:ok, _, _} = callback(c)
      assert_received {:get_json, @issuer <> "/jwks"}
    end
  end

  describe "discovery" do
    test "a connection without endpoints reads them from the issuer's discovery document" do
      issuer = "https://discovery.example.com"

      {_org, c} =
        connection("disco", %{
          issuer: issuer,
          authorization_endpoint: nil,
          token_endpoint: nil,
          jwks_uri: nil
        })

      Application.put_env(:barkpark, :oidc_test, %{
        discovery: %{
          "authorization_endpoint" => issuer <> "/oauth2/authorize",
          "token_endpoint" => issuer <> "/oauth2/token",
          "jwks_uri" => issuer <> "/keys"
        }
      })

      p = Map.put(Oidc.new_auth_params(), :redirect_uri, "https://bp/cb")
      assert {:ok, url} = Oidc.authorize_url(c, p)
      assert url =~ issuer <> "/oauth2/authorize?"

      mock_op(claims(%{"iss" => issuer}))
      assert {:ok, _, _} = callback(c)
      assert_received {:token_request, "https://discovery.example.com/oauth2/token", _, _}
      assert_received {:get_json, "https://discovery.example.com/keys"}
    end
  end

  describe "client authentication" do
    test "client_secret_post sends the secret in the body (the default)" do
      {_org, c} = connection()
      mock_op(claims())
      assert {:ok, _, _} = callback(c)
      assert_received {:token_request, _, %{"client_secret" => "top-secret"}, []}
    end

    test "client_secret_basic sends the secret in the Authorization header only" do
      {_org, c} = connection("basic", %{token_endpoint_auth_method: "client_secret_basic"})
      mock_op(claims())
      assert {:ok, _, _} = callback(c)

      assert_received {:token_request, _, params, [{"authorization", "Basic " <> basic}]}
      refute Map.has_key?(params, "client_secret")
      assert Base.decode64!(basic) == "bp-client:top-secret"
    end
  end

  describe "group-claims → role mapping (era-w7)" do
    # An org with one workspace + an OIDC connection carrying mappings.
    defp mapped_connection(mappings, extra \\ %{}) do
      {:ok, org} = Tenancy.create_organization(%{slug: "groupsorg", name: "Groups Org"})
      {:ok, ws} = Tenancy.create_workspace(%{slug: "groups-ws", name: "WS"})
      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)

      {:ok, c} =
        Oidc.create_connection(
          Map.merge(
            %{
              organization_id: org.id,
              issuer: @issuer,
              client_id: @client_id,
              client_secret: "top-secret",
              authorization_endpoint: @issuer <> "/authorize",
              token_endpoint: @issuer <> "/token",
              jwks_uri: @issuer <> "/jwks",
              group_role_mappings: mappings
            },
            extra
          )
        )

      {org, ws, c}
    end

    defp member_role(ws_id, user_id) do
      Barkpark.Repo.one(
        from m in Barkpark.Tenancy.Membership,
          where:
            m.workspace_id == ^ws_id and m.principal_type == "user" and
              m.principal_id == ^user_id,
          select: m.role
      )
    end

    test "a mapped group grants its role at JIT" do
      {_org, ws, c} = mapped_connection(%{"idp-admins" => "admin"})
      mock_op(claims(%{"groups" => ["idp-admins", "unrelated"]}))

      assert {:ok, user, _} = callback(c)
      assert member_role(ws.id, user.id) == "admin"
    end

    test "several mapped groups → the highest-ranked role wins" do
      {_org, ws, c} = mapped_connection(%{"idp-admins" => "admin", "idp-staff" => "member"})
      mock_op(claims(%{"groups" => ["idp-staff", "idp-admins"]}))

      assert {:ok, user, _} = callback(c)
      assert member_role(ws.id, user.id) == "admin"
    end

    test "the mapping is AUTHORITATIVE: changed groups downgrade on the next login" do
      {_org, ws, c} = mapped_connection(%{"idp-admins" => "admin", "idp-staff" => "member"})

      mock_op(claims(%{"groups" => ["idp-admins"]}))
      assert {:ok, user, _} = callback(c)
      assert member_role(ws.id, user.id) == "admin"

      # Next login: the IdP no longer lists the admin group.
      mock_op(claims(%{"groups" => ["idp-staff"]}))
      assert {:ok, ^user, _} = callback(c)
      assert member_role(ws.id, user.id) == "member"
    end

    test "an ABSENT groups claim leaves existing roles untouched (and JIT-defaults new users)" do
      {_org, ws, c} = mapped_connection(%{"idp-admins" => "admin"})

      mock_op(claims(%{"groups" => ["idp-admins"]}))
      assert {:ok, user, _} = callback(c)
      assert member_role(ws.id, user.id) == "admin"

      # Same user again, token WITHOUT the claim → role stays admin.
      mock_op(claims())
      assert {:ok, ^user, _} = callback(c)
      assert member_role(ws.id, user.id) == "admin"

      # A brand-new user without the claim → plain default JIT.
      mock_op(claims(%{"email" => "plain@groupsorg.com"}))
      assert {:ok, plain, _} = callback(c)
      assert member_role(ws.id, plain.id) == "member"
    end

    test "UNMAPPED groups grant nothing — no escalation path from token contents" do
      {_org, ws, c} = mapped_connection(%{"idp-admins" => "admin"})
      # The token claims a group that LOOKS privileged but is not mapped.
      mock_op(claims(%{"groups" => ["admin", "owner", "superuser"]}))

      assert {:ok, user, _} = callback(c)
      assert member_role(ws.id, user.id) == "member"
    end

    test "a custom groups_claim name is honoured" do
      {_org, ws, c} = mapped_connection(%{"eng" => "admin"}, %{groups_claim: "memberOf"})
      mock_op(claims(%{"memberOf" => ["eng"]}))

      assert {:ok, user, _} = callback(c)
      assert member_role(ws.id, user.id) == "admin"
    end

    test "a mapping to an UNKNOWN role is rejected at connection write" do
      {:ok, org} = Tenancy.create_organization(%{slug: "badmap", name: "Bad Map"})

      assert {:error, {:unknown_role, ["superadmin"]}} =
               Oidc.create_connection(%{
                 organization_id: org.id,
                 issuer: @issuer,
                 client_id: @client_id,
                 client_secret: "s",
                 authorization_endpoint: @issuer <> "/a",
                 token_endpoint: @issuer <> "/t",
                 jwks_uri: @issuer <> "/j",
                 group_role_mappings: %{"g" => "superadmin"}
               })
    end
  end

  describe "the bootstrap owner signs in through Entra" do
    setup do
      Barkpark.Repo.delete_all(Barkpark.Accounts.User)
      ws = Tenancy.establish_default_workspace!()
      {:ok, owner} = Barkpark.Accounts.BootstrapOwner.run("Owner@Contoso.example")
      {org, c} = connection("entraorg", %{tenant_id: "tid-1"})
      {:ok, _} = Tenancy.assign_workspace_to_organization(ws, org.id)
      on_exit(fn -> Application.delete_env(:barkpark, :oidc_email_from_upn) end)
      %{owner: owner, c: c}
    end

    test "the email claim matches the owner, ignoring case", %{owner: owner, c: c} do
      mock_op(claims(%{"tid" => "tid-1", "email" => "OWNER@contoso.example"}))

      assert {:ok, user, _} = callback(c)
      assert user.id == owner.id
    end

    test "with no email claim, the UPN matches the owner", %{owner: owner, c: c} do
      Application.put_env(:barkpark, :oidc_email_from_upn, true)

      mock_op(
        claims(%{"tid" => "tid-1", "preferred_username" => "owner@CONTOSO.example"})
        |> Map.delete("email")
      )

      assert {:ok, user, _} = callback(c)
      assert user.id == owner.id
    end

    test "with the setting off, a token with no email claim is refused as before", %{c: c} do
      mock_op(
        claims(%{"tid" => "tid-1", "preferred_username" => "owner@contoso.example"})
        |> Map.delete("email")
      )

      assert {:error, :no_email} = callback(c)
    end

    test "a UPN that is not an address is not used", %{c: c} do
      Application.put_env(:barkpark, :oidc_email_from_upn, true)
      mock_op(claims(%{"tid" => "tid-1", "preferred_username" => "owner"}) |> Map.delete("email"))

      assert {:error, :no_email} = callback(c)
    end
  end

  describe "IdP MFA claims" do
    import ExUnit.CaptureLog
    require Logger

    test "the MFA claims a trusting connection sees are logged at debug, without user claims" do
      c = %Barkpark.Sso.OidcConnection{trust_idp_mfa: true, mfa_acr: nil}
      claims = %{"amr" => ["pwd", "mfa"], "acr" => "1", "email" => "who@example.com"}

      Logger.put_module_level(Oidc, :debug)
      on_exit(fn -> Logger.delete_module_level(Oidc) end)
      prev = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: prev) end)

      log = capture_log([level: :debug], fn -> assert Oidc.idp_mfa?(c, claims) end)

      assert log =~ ~s(amr=["pwd", "mfa"])
      assert log =~ "counted=true"
      refute log =~ "who@example.com"
    end
  end

  describe "group mappings never leave an org with no owner" do
    setup do
      Application.put_env(:barkpark, :oidc_keep_owner, true)
      on_exit(fn -> Application.delete_env(:barkpark, :oidc_keep_owner) end)
    end

    defp owned_org do
      {:ok, org} = Tenancy.create_organization(%{slug: "ownedorg", name: "Owned"})
      {:ok, ws} = Tenancy.create_workspace(%{slug: "owned-ws", name: "WS"})
      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)

      {:ok, owner} =
        Accounts.register_user(%{email: "sso@oidcorg.com", password: "correct horse ok"})

      {:ok, _} = Tenancy.Auth.create_membership(ws.id, owner.id, "owner", "user")
      {org, ws, owner}
    end

    defp attrs(org, mappings) do
      %{
        organization_id: org.id,
        issuer: @issuer,
        client_id: @client_id,
        client_secret: "s",
        authorization_endpoint: @issuer <> "/authorize",
        token_endpoint: @issuer <> "/token",
        jwks_uri: @issuer <> "/jwks",
        group_role_mappings: mappings
      }
    end

    defp role_in(ws_id, user_id) do
      Barkpark.Repo.one(
        from m in Barkpark.Tenancy.Membership,
          where:
            m.workspace_id == ^ws_id and m.principal_type == "user" and
              m.principal_id == ^user_id,
          select: m.role
      )
    end

    test "a mapping with no owner group is refused when the org has an owner" do
      {org, _ws, _owner} = owned_org()

      assert {:error, :no_owner_mapping} =
               Oidc.create_connection(attrs(org, %{"editors" => "member"}))

      {:ok, c} = Oidc.create_connection(attrs(org, %{}))

      assert {:error, :no_owner_mapping} =
               Oidc.update_connection(c, %{group_role_mappings: %{"editors" => "admin"}})
    end

    test "a mapping that keeps an owner group is saved as before" do
      {org, _ws, _owner} = owned_org()
      mappings = %{"owners" => "owner", "editors" => "member"}

      assert {:ok, c} = Oidc.create_connection(attrs(org, mappings))
      assert c.group_role_mappings == mappings

      assert {:ok, c} = Oidc.update_connection(c, %{group_role_mappings: %{"owners" => "owner"}})
      assert c.group_role_mappings == %{"owners" => "owner"}
      assert {:ok, _} = Oidc.update_connection(c, %{group_role_mappings: %{}})
    end

    test "a sign-in never demotes the last owner" do
      {org, ws, owner} = owned_org()
      {:ok, c} = Oidc.create_connection(attrs(org, %{"owners" => "owner", "editors" => "member"}))
      verify_domain!(org, "oidcorg.com")

      mock_op(claims(%{"groups" => ["editors"]}))
      assert {:ok, user, _} = callback(c)
      assert user.id == owner.id
      assert role_in(ws.id, owner.id) == "owner"
    end

    test "with the setting off, mappings and sign-ins behave as before" do
      Application.delete_env(:barkpark, :oidc_keep_owner)
      {org, ws, owner} = owned_org()
      verify_domain!(org, "oidcorg.com")
      assert {:ok, c} = Oidc.create_connection(attrs(org, %{"editors" => "member"}))

      mock_op(claims(%{"groups" => ["editors"]}))
      assert {:ok, _, _} = callback(c)
      assert role_in(ws.id, owner.id) == "member"
    end

    test "a sign-in demotes an owner while another owner remains" do
      {org, ws, owner} = owned_org()
      {:ok, c} = Oidc.create_connection(attrs(org, %{"owners" => "owner", "editors" => "member"}))

      {:ok, other} =
        Accounts.register_user(%{email: "other@oidcorg.com", password: "correct horse ok"})

      {:ok, _} = Tenancy.Auth.create_membership(ws.id, other.id, "owner", "user")

      mock_op(claims(%{"groups" => ["editors"]}))
      assert {:ok, user, _} = callback(c)
      assert user.id == owner.id
      assert role_in(ws.id, owner.id) == "member"
      assert role_in(ws.id, other.id) == "owner"
    end
  end
end
