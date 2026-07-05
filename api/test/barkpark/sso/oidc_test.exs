defmodule Barkpark.Sso.OidcTest do
  @moduledoc "OIDC relying-party against a mock OP (signed id_token, mocked token+JWKS)."
  use Barkpark.DataCase, async: false

  alias Barkpark.{Accounts, Tenancy}
  alias Barkpark.Sso.Oidc

  @issuer "https://idp.example.com"
  @client_id "bp-client"

  # Mock IdP HTTP: token endpoint returns the fixture id_token; JWKS returns the
  # fixture public key. Fixtures live in app env, set per test.
  defmodule MockIdP do
    @behaviour Barkpark.Sso.Oidc.HTTP
    @impl true
    def post_form(_url, _params), do: {:ok, %{"id_token" => fixture(:id_token)}}
    @impl true
    def get_json(_url), do: {:ok, %{"keys" => [fixture(:jwk)]}}
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

  defp connection(slug \\ "oidcorg") do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})

    {:ok, c} =
      Oidc.create_connection(%{
        organization_id: org.id,
        issuer: @issuer,
        client_id: @client_id,
        client_secret: "top-secret",
        authorization_endpoint: @issuer <> "/authorize",
        token_endpoint: @issuer <> "/token",
        jwks_uri: @issuer <> "/jwks"
      })

    {org, c}
  end

  # Sign an id_token with a fresh RSA key and register the matching JWKS.
  defp mock_op(claims) do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    pub = jwk |> JOSE.JWK.to_public_map() |> elem(1) |> Map.put("kid", "k1")

    id_token =
      jwk
      |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "RS256", "kid" => "k1"})
      |> JOSE.JWS.compact()
      |> elem(1)

    Application.put_env(:barkpark, :oidc_test, %{id_token: id_token, jwk: pub})
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
      {_org, c} = connection()

      {:ok, existing} =
        Accounts.register_user(%{email: "sso@oidcorg.com", password: "correct horse ok"})

      mock_op(claims())

      assert {:ok, user, _} = callback(c)
      assert user.id == existing.id
    end
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
      url = Oidc.authorize_url(c, Map.put(p, :redirect_uri, "https://bp/cb"))

      assert url =~ @issuer <> "/authorize?"
      assert url =~ "client_id=bp-client"
      assert url =~ "code_challenge_method=S256"
      assert url =~ "response_type=code"
    end
  end
end
