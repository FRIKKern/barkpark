defmodule BarkparkWeb.OidcControllerTest do
  @moduledoc "OIDC RP HTTP surface — start redirect + callback session mint (era-w3-oidc-rp)."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Tenancy}
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

    :ok
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
end
