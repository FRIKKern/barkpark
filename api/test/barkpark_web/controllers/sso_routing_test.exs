defmodule BarkparkWeb.SsoRoutingTest do
  @moduledoc "SSO routing endpoint + JIT provisioning through the real OIDC callback."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Repo, Tenancy}
  alias Barkpark.Sso.{Domains, Oidc}
  alias Barkpark.Tenancy.Membership
  import Ecto.Query

  defmodule MockResolver do
    @behaviour Barkpark.Sso.Domains.Resolver
    @impl true
    def txt_records(_d), do: Application.get_env(:barkpark, :dns_test, [])
  end

  defmodule MockOidcHTTP do
    @behaviour Barkpark.Sso.Oidc.HTTP
    @impl true
    def post_form(_u, _p),
      do: {:ok, %{"id_token" => Application.get_env(:barkpark, :oidc_test)[:id_token]}}

    @impl true
    def get_json(_u), do: {:ok, %{"keys" => [Application.get_env(:barkpark, :oidc_test)[:jwk]]}}
  end

  setup do
    Application.put_env(:barkpark, :dns_resolver, MockResolver)

    on_exit(fn ->
      Application.delete_env(:barkpark, :dns_resolver)
      Application.delete_env(:barkpark, :dns_test)
      Application.delete_env(:barkpark, :oidc_http)
      Application.delete_env(:barkpark, :oidc_test)
    end)

    :ok
  end

  defp post_json(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  describe "POST /v1/auth/sso/route" do
    test "a verified domain returns its org SSO start URL", %{conn: conn} do
      {:ok, o} = Tenancy.create_organization(%{slug: "acme", name: "Acme"})
      {:ok, rec} = Domains.request_verification(o, "acme.com")
      Application.put_env(:barkpark, :dns_test, [rec.dns_token])
      {:ok, _} = Domains.verify("acme.com")

      body =
        post_json(conn, "/v1/auth/sso/route", %{email: "user@acme.com"}) |> json_response(200)

      assert body["sso"] == true
      assert body["start_url"] == "/v1/auth/oidc/acme/start"
    end

    test "an unverified / unknown domain returns sso:false", %{conn: conn} do
      body =
        post_json(conn, "/v1/auth/sso/route", %{email: "user@nowhere.com"}) |> json_response(200)

      assert body["sso"] == false
    end
  end

  describe "JIT provisioning fires through the OIDC callback" do
    test "first OIDC login provisions the user into the org's workspaces", %{conn: conn} do
      {:ok, org} = Tenancy.create_organization(%{slug: "jitorg", name: "JIT Org"})
      {:ok, ws} = Tenancy.create_workspace(%{slug: "jitorg-ws", name: "WS"})
      {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)

      {:ok, _c} =
        Oidc.create_connection(%{
          organization_id: org.id,
          issuer: "https://idp.example.com",
          client_id: "cid",
          client_secret: "s",
          authorization_endpoint: "https://idp.example.com/auth",
          token_endpoint: "https://idp.example.com/token",
          jwks_uri: "https://idp.example.com/jwks"
        })

      # mock OP: sign an id_token
      jwk = JOSE.JWK.generate_key({:rsa, 2048})
      pub = jwk |> JOSE.JWK.to_public_map() |> elem(1) |> Map.put("kid", "k1")

      claims = %{
        "iss" => "https://idp.example.com",
        "aud" => "cid",
        "exp" => System.system_time(:second) + 300,
        "nonce" => "n1",
        "email" => "newhire@jitorg.com"
      }

      token =
        jwk
        |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "RS256", "kid" => "k1"})
        |> JOSE.JWS.compact()
        |> elem(1)

      Application.put_env(:barkpark, :oidc_test, %{id_token: token, jwk: pub})
      Application.put_env(:barkpark, :oidc_http, MockOidcHTTP)

      conn
      |> init_test_session(%{oidc_state: "s1", oidc_nonce: "n1", oidc_verifier: "v1"})
      |> get("/v1/auth/oidc/jitorg/callback?code=abc&state=s1")
      |> json_response(201)

      user = Accounts.get_user_by_email("newhire@jitorg.com")
      assert user
      # JIT: the SSO login gained a membership in the org's workspace
      assert Repo.exists?(
               from m in Membership,
                 where:
                   m.principal_type == "user" and m.principal_id == ^user.id and
                     m.workspace_id == ^ws.id
             )
    end
  end
end
