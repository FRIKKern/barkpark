defmodule BarkparkWeb.OrgSsoControllerTest do
  @moduledoc """
  `/v1/admin/orgs` (task-25386fa77a664587): an operator sets up an organization
  and its OIDC sign-in over REST, each change writes an audit event, and the
  client secret never comes back.

  async: false: the operator allowlist, the mock IdP and the DNS resolver are
  Application env.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Auth, Repo, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Sso.{Domains, Oidc, OidcConnection}

  @issuer "https://login.example.com/tenant-1/v2.0"
  @client_id "bp-client"

  defmodule MockIdP do
    @behaviour Barkpark.Sso.Oidc.HTTP
    @issuer "https://login.example.com/tenant-1/v2.0"

    @impl true
    def get_json(@issuer <> "/.well-known/openid-configuration") do
      {:ok,
       %{
         "issuer" => @issuer,
         "authorization_endpoint" => @issuer <> "/authorize",
         "token_endpoint" => @issuer <> "/token",
         "jwks_uri" => @issuer <> "/keys"
       }}
    end

    def get_json(_jwks), do: {:ok, %{"keys" => [fixture(:jwk)]}}

    @impl true
    def post_form(_url, _params, _headers), do: {:ok, %{"id_token" => fixture(:id_token)}}

    defp fixture(k), do: Application.get_env(:barkpark, :oidc_test)[k]
  end

  defmodule MockResolver do
    @behaviour Barkpark.Sso.Domains.Resolver
    @impl true
    def txt_records(_domain), do: Application.get_env(:barkpark, :dns_test, [])
  end

  setup do
    for {key, value} <- [
          oidc_http: MockIdP,
          dns_resolver: MockResolver,
          operator_emails: [],
          operator_token_ids: []
        ] do
      prev = Application.fetch_env(:barkpark, key)
      Application.put_env(:barkpark, key, value)

      on_exit(fn ->
        case prev do
          {:ok, v} -> Application.put_env(:barkpark, key, v)
          :error -> Application.delete_env(:barkpark, key)
        end
      end)
    end

    on_exit(fn ->
      Application.delete_env(:barkpark, :oidc_test)
      Application.delete_env(:barkpark, :dns_test)
    end)

    {:ok, ws} = Tenancy.create_workspace(%{slug: uniq("sso-ws"), name: "SSO"})
    raw = uniq("op")
    {:ok, token} = Auth.create_token(raw, uniq("lbl"), "production", ~w(read write admin), ws.id)
    %{ws: ws, bearer: raw, token: token}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp req(bearer, method, path, body \\ %{}) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  defp audit_actions(org_slug) do
    Repo.all(
      from e in Event,
        where: e.category == "auth" and fragment("?->>'org_slug' = ?", e.metadata, ^org_slug),
        order_by: [asc: e.id],
        select: e.action
    )
  end

  defp setup_org(%{bearer: b, ws: ws}, mappings \\ %{}) do
    slug = uniq("org")

    assert %{"slug" => ^slug} =
             req(b, :post, "/v1/admin/orgs", %{slug: slug}) |> json_response(201)

    assert req(b, :put, "/v1/admin/orgs/#{slug}/workspaces/#{ws.slug}") |> json_response(200)

    body =
      req(b, :post, "/v1/admin/orgs/#{slug}/oidc", %{
        issuer: @issuer,
        client_id: @client_id,
        client_secret: "first-secret",
        group_role_mappings: mappings
      })
      |> json_response(201)

    {slug, body}
  end

  describe "OIDC connection lifecycle" do
    test "create reads the discovery document; rotate and delete are audited", ctx do
      {slug, created} = setup_org(ctx)

      assert created["token_endpoint"] == @issuer <> "/token"
      assert created["jwks_uri"] == @issuer <> "/keys"
      assert created["client_secret_set"] == true
      refute inspect(created) =~ "first-secret"

      rotated =
        req(ctx.bearer, :put, "/v1/admin/orgs/#{slug}/oidc/client-secret", %{
          client_secret: "second-secret"
        })
        |> json_response(200)

      refute inspect(rotated) =~ "second-secret"
      assert Oidc.connection_for_org_slug(slug).client_secret == "second-secret"

      assert req(ctx.bearer, :delete, "/v1/admin/orgs/#{slug}/oidc") |> json_response(200)
      assert Oidc.connection_for_org_slug(slug) == nil

      assert audit_actions(slug) == [
               "organization_created",
               "workspace_organization_changed",
               "oidc_connection_created",
               "oidc_client_secret_rotated",
               "oidc_connection_deleted"
             ]

      refute Repo.all(from e in Event, select: e.metadata) |> inspect() =~ "-secret"
    end

    test "a discovery document naming another issuer is refused", ctx do
      slug = uniq("org")
      req(ctx.bearer, :post, "/v1/admin/orgs", %{slug: slug}) |> json_response(201)

      conn =
        req(ctx.bearer, :post, "/v1/admin/orgs/#{slug}/oidc", %{
          issuer: "https://login.example.com/other",
          client_id: @client_id,
          client_secret: "s"
        })

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
      assert Repo.aggregate(OidcConnection, :count) == 0
    end

    test "an armed allowlist refuses a non-operator admin", ctx do
      Application.put_env(:barkpark, :operator_token_ids, ["not-this-token"])

      conn = req(ctx.bearer, :post, "/v1/admin/orgs", %{slug: uniq("org")})
      assert %{"error" => %{"required" => "platform_operator"}} = json_response(conn, 403)
    end
  end

  describe "group mappings" do
    defp sign_in(slug, groups) do
      jwk = JOSE.JWK.generate_key({:rsa, 2048})
      pub = jwk |> JOSE.JWK.to_public_map() |> elem(1) |> Map.put("kid", "k1")

      claims = %{
        "iss" => @issuer,
        "aud" => @client_id,
        "exp" => System.system_time(:second) + 300,
        "nonce" => "n",
        "email" => "editor@#{slug}.example",
        "groups" => groups
      }

      {_, id_token} =
        jwk
        |> JOSE.JWS.sign(Jason.encode!(claims), %{"alg" => "RS256", "kid" => "k1"})
        |> JOSE.JWS.compact()

      Application.put_env(:barkpark, :oidc_test, %{id_token: id_token, jwk: pub})

      {:ok, user, _} =
        Oidc.handle_callback(Oidc.connection_for_org_slug(slug), "code",
          redirect_uri: "https://bp/cb",
          code_verifier: "v",
          nonce: "n"
        )

      user
    end

    defp role(ws, user) do
      Repo.one(
        from m in Tenancy.Membership,
          where:
            m.workspace_id == ^ws.id and m.principal_type == "user" and
              m.principal_id == ^user.id,
          select: m.role
      )
    end

    test "the next sign-in applies a mapping edited through the API", ctx do
      {slug, _} = setup_org(ctx, %{"editors" => "member"})

      user = sign_in(slug, ["editors"])
      assert role(ctx.ws, user) == "member"

      assert req(ctx.bearer, :patch, "/v1/admin/orgs/#{slug}/oidc", %{
               group_role_mappings: %{"editors" => "admin"}
             })
             |> json_response(200)

      assert sign_in(slug, ["editors"]).id == user.id
      assert role(ctx.ws, user) == "admin"
      assert "oidc_connection_updated" in audit_actions(slug)
    end

    test "a mapping to an unknown role is refused", ctx do
      {slug, _} = setup_org(ctx)

      conn =
        req(ctx.bearer, :patch, "/v1/admin/orgs/#{slug}/oidc", %{
          group_role_mappings: %{"g" => "superadmin"}
        })

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end
  end

  describe "domains and sign-in methods" do
    test "a domain routes sign-ins only after its TXT record verifies", ctx do
      slug = uniq("org")
      req(ctx.bearer, :post, "/v1/admin/orgs", %{slug: slug}) |> json_response(201)
      domain = "#{slug}.example"

      %{"dns_txt_record" => txt, "verified" => false} =
        req(ctx.bearer, :post, "/v1/admin/orgs/#{slug}/domains", %{domain: domain})
        |> json_response(201)

      assert Domains.route_for_email("a@#{domain}") == nil

      conn = req(ctx.bearer, :post, "/v1/admin/orgs/#{slug}/domains/#{domain}/verify")
      assert json_response(conn, 422)
      assert Domains.route_for_email("a@#{domain}") == nil

      Application.put_env(:barkpark, :dns_test, [txt])

      assert %{"verified" => true} =
               req(ctx.bearer, :post, "/v1/admin/orgs/#{slug}/domains/#{domain}/verify")
               |> json_response(200)

      assert Domains.route_for_email("a@#{domain}").slug == slug

      assert audit_actions(slug) == [
               "organization_created",
               "org_domain_requested",
               "org_domain_verified"
             ]
    end

    test "allowed sign-in methods are set, cleared only explicitly, and audited", ctx do
      slug = uniq("org")
      req(ctx.bearer, :post, "/v1/admin/orgs", %{slug: slug}) |> json_response(201)
      path = "/v1/admin/orgs/#{slug}/auth-methods"

      assert %{"allowed_auth_methods" => ["sso"]} =
               req(ctx.bearer, :put, path, %{methods: "sso"}) |> json_response(200)

      assert json_response(req(ctx.bearer, :put, path, %{}), 422)
      assert json_response(req(ctx.bearer, :put, path, %{methods: "pasword"}), 422)

      assert %{"allowed_auth_methods" => nil} =
               req(ctx.bearer, :put, path, %{methods: nil}) |> json_response(200)

      assert Enum.count(audit_actions(slug), &(&1 == "allowed_auth_methods_changed")) == 2
    end
  end
end
