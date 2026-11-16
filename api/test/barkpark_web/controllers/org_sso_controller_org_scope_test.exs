defmodule BarkparkWeb.OrgSsoControllerOrgScopeTest do
  @moduledoc """
  task-e04a14e5834fb086: with the operator allowlist unset, `/v1/admin/orgs`
  let any admin of one workspace change the sign-in setup of every
  organization and move workspaces between them. A caller who is not a listed
  operator now acts only on an organization they administer in full (admin in
  every one of its workspaces), and moves a workspace only out of such an
  organization. Every refusal is one 403 that writes nothing, the same for a
  missing organization.

  async: false: the operator allowlist, the mock IdP and the DNS resolver are
  Application env.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Auth, Repo, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Sso.{Domains, Oidc, OidcConnection, OrgDomain}
  alias Barkpark.Tenancy.{Organization, Workspace}

  @issuer "https://login.example.com/scope-tenant/v2.0"

  defmodule MockIdP do
    @behaviour Barkpark.Sso.Oidc.HTTP
    @issuer "https://login.example.com/scope-tenant/v2.0"

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

    def get_json(_jwks), do: {:ok, %{"keys" => []}}

    @impl true
    def post_form(_url, _params, _headers), do: {:error, :not_used}
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

    on_exit(fn -> Application.delete_env(:barkpark, :dns_test) end)

    n = System.unique_integer([:positive])
    ws_a = ws!("scope-a-#{n}")
    ws_b = ws!("scope-b-#{n}")
    # T is the caller's own organization (A only); S is foreign (B only).
    org_t = org!("scope-t-#{n}", [ws_a])
    org_s = org!("scope-s-#{n}", [ws_b])

    {:ok, _} =
      Oidc.create_connection(%{
        "organization_id" => org_s.id,
        "issuer" => @issuer,
        "client_id" => "s-client",
        "client_secret" => "s-secret",
        "authorization_endpoint" => @issuer <> "/authorize",
        "token_endpoint" => @issuer <> "/token",
        "jwks_uri" => @issuer <> "/keys"
      })

    {:ok, _} = Domains.request_verification(org_s, "s-#{n}.example")

    %{
      n: n,
      ws_a: ws_a,
      ws_b: ws_b,
      org_t: org_t,
      org_s: org_s,
      a: token!(ws_a),
      s_domain: "s-#{n}.example"
    }
  end

  defp ws!(slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    ws
  end

  defp org!(slug, workspaces) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    for ws <- workspaces, do: {:ok, _} = Tenancy.assign_workspace_to_organization(ws, org.id)
    org
  end

  # An admin token seated in `ws` (Auth.create_token seats it there).
  defp token!(ws) do
    raw = "scope-tok-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, raw, "production", ~w(read write admin), ws && ws.id)
    %{raw: raw, token: token}
  end

  defp req(%{raw: raw}, method, path, body \\ %{}) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  # Every route under /:org_slug, with a body that would succeed for its owner.
  defp routes(slug, ctx) do
    [
      {:put, "/v1/admin/orgs/#{slug}/workspaces/#{ctx.ws_a.slug}", %{}},
      {:put, "/v1/admin/orgs/#{slug}/auth-methods", %{methods: ["sso"]}},
      {:post, "/v1/admin/orgs/#{slug}/oidc",
       %{issuer: @issuer, client_id: "evil", client_secret: "evil-secret"}},
      {:patch, "/v1/admin/orgs/#{slug}/oidc", %{client_id: "evil"}},
      {:put, "/v1/admin/orgs/#{slug}/oidc/client-secret", %{client_secret: "evil-secret"}},
      {:delete, "/v1/admin/orgs/#{slug}/oidc", %{}},
      {:post, "/v1/admin/orgs/#{slug}/domains", %{domain: "evil-#{ctx.n}.example"}},
      {:post, "/v1/admin/orgs/#{slug}/domains/#{ctx.s_domain}/verify", %{}}
    ]
  end

  # Everything a route under /v1/admin/orgs can write.
  defp snapshot do
    %{
      orgs:
        Repo.all(
          from o in Organization,
            order_by: o.slug,
            select: {o.slug, o.allowed_auth_methods, o.updated_at}
        ),
      oidc:
        Repo.all(
          from c in OidcConnection,
            order_by: c.organization_id,
            select: {c.organization_id, c.client_id, c.client_secret, c.updated_at}
        ),
      domains:
        Repo.all(
          from d in OrgDomain,
            order_by: d.domain,
            select: {d.organization_id, d.domain, d.verified_at}
        ),
      workspaces:
        Repo.all(from w in Workspace, order_by: w.slug, select: {w.slug, w.organization_id}),
      audit: Repo.aggregate(from(e in Event, where: e.category == "auth"), :count)
    }
  end

  defp refusal(conn) do
    assert %{"error" => error} = json_response(conn, 403)
    assert error["code"] == "forbidden"
    assert error["message"] == "you do not administer this organization"
    Map.delete(error, "request_id")
  end

  describe "an admin of workspace A, allowlist unset, acting on org S (B only)" do
    for {route, i} <-
          Enum.with_index([
            "attach a workspace to",
            "set the sign-in methods of",
            "create the OIDC connection of",
            "update the OIDC connection of",
            "rotate the OIDC client secret of",
            "delete the OIDC connection of",
            "claim an SSO domain for",
            "verify an SSO domain of"
          ]) do
      test "an admin of workspace A cannot #{route} an organisation they do not administer",
           ctx do
        Application.put_env(:barkpark, :dns_test, [
          Repo.get_by!(OrgDomain, domain: ctx.s_domain).dns_token
        ])

        {method, path, body} = Enum.at(routes(ctx.org_s.slug, ctx), unquote(i))
        before = snapshot()

        refusal(req(ctx.a, method, path, body))
        assert snapshot() == before
      end
    end
  end

  describe "moving a workspace to become an organisation's admin" do
    test "A's admin cannot move A into S, which holds B they do not administer", ctx do
      before = snapshot()
      refusal(req(ctx.a, :put, "/v1/admin/orgs/#{ctx.org_s.slug}/workspaces/#{ctx.ws_a.slug}"))
      assert snapshot() == before
    end

    test "A's admin cannot move B out of S, even into their own org", ctx do
      before = snapshot()
      refusal(req(ctx.a, :put, "/v1/admin/orgs/#{ctx.org_t.slug}/workspaces/#{ctx.ws_b.slug}"))
      assert snapshot() == before
    end

    test "a workspace in no org joins only when the caller is its admin", ctx do
      loose = ws!("scope-loose-#{ctx.n}")
      path = "/v1/admin/orgs/#{ctx.org_t.slug}/workspaces/#{loose.slug}"
      before = snapshot()
      refusal(req(ctx.a, :put, path))
      assert snapshot() == before

      {:ok, _} =
        Tenancy.Auth.create_membership(loose.id, ctx.a.token.id, "admin", "api_token")

      assert %{"organization" => _} = req(ctx.a, :put, path) |> json_response(200)
      assert Repo.reload!(loose).organization_id == ctx.org_t.id
    end

    test "nobody but an operator attaches into an org with no workspace", ctx do
      {:ok, empty} = Tenancy.create_organization(%{slug: "scope-e-#{ctx.n}", name: "e"})
      loose = ws!("scope-loose2-#{ctx.n}")
      {:ok, _} = Tenancy.Auth.create_membership(loose.id, ctx.a.token.id, "admin", "api_token")
      before = snapshot()
      refusal(req(ctx.a, :put, "/v1/admin/orgs/#{empty.slug}/workspaces/#{loose.slug}"))
      assert snapshot() == before
    end
  end

  test "a missing, upper-case or garbage slug gets the same refusal as a foreign org", ctx do
    foreign = refusal(req(ctx.a, :put, "/v1/admin/orgs/#{ctx.org_s.slug}/auth-methods", %{}))

    for slug <- [
          "nope-#{ctx.n}",
          String.upcase(ctx.org_t.slug),
          URI.encode_www_form("x' OR 1=1 --"),
          URI.encode_www_form(ctx.org_t.id)
        ] do
      before = snapshot()

      assert refusal(req(ctx.a, :put, "/v1/admin/orgs/#{slug}/auth-methods", %{})) == foreign
      assert snapshot() == before
    end

    # A missing workspace in the caller's own org is refused the same way.
    assert refusal(req(ctx.a, :put, "/v1/admin/orgs/#{ctx.org_t.slug}/workspaces/nope-#{ctx.n}")) ==
             foreign
  end

  test "an admin of every workspace of their own org can still use every route", ctx do
    slug = ctx.org_t.slug
    domain = "t-#{ctx.n}.example"
    loose = ws!("scope-own-#{ctx.n}")
    {:ok, _} = Tenancy.Auth.create_membership(loose.id, ctx.a.token.id, "admin", "api_token")

    assert req(ctx.a, :put, "/v1/admin/orgs/#{slug}/workspaces/#{loose.slug}")
           |> json_response(200)

    assert %{"allowed_auth_methods" => ["sso"]} =
             req(ctx.a, :put, "/v1/admin/orgs/#{slug}/auth-methods", %{methods: ["sso"]})
             |> json_response(200)

    assert req(ctx.a, :post, "/v1/admin/orgs/#{slug}/oidc", %{
             issuer: @issuer,
             client_id: "t-client",
             client_secret: "t-secret"
           })
           |> json_response(201)

    assert %{"client_id" => "t2"} =
             req(ctx.a, :patch, "/v1/admin/orgs/#{slug}/oidc", %{client_id: "t2"})
             |> json_response(200)

    assert req(ctx.a, :put, "/v1/admin/orgs/#{slug}/oidc/client-secret", %{client_secret: "t3"})
           |> json_response(200)

    assert req(ctx.a, :delete, "/v1/admin/orgs/#{slug}/oidc") |> json_response(200)

    %{"dns_txt_record" => txt} =
      req(ctx.a, :post, "/v1/admin/orgs/#{slug}/domains", %{domain: domain})
      |> json_response(201)

    Application.put_env(:barkpark, :dns_test, [txt])

    assert %{"verified" => true} =
             req(ctx.a, :post, "/v1/admin/orgs/#{slug}/domains/#{domain}/verify")
             |> json_response(200)
  end

  test "a listed operator still uses every route on any org", ctx do
    op = token!(nil)
    Application.put_env(:barkpark, :operator_token_ids, [op.token.id])

    Application.put_env(:barkpark, :dns_test, [
      Repo.get_by!(OrgDomain, domain: ctx.s_domain).dns_token
    ])

    slug = ctx.org_s.slug

    assert req(op, :post, "/v1/admin/orgs", %{slug: "scope-op-#{ctx.n}"}) |> json_response(201)

    expected = [200, 200, 409, 200, 200, 200, 201, 200]

    for {{method, path, body}, status} <- Enum.zip(routes(slug, ctx), expected) do
      assert req(op, method, path, body).status == status, "#{method} #{path}"
    end

    assert Repo.reload!(ctx.ws_a).organization_id == ctx.org_s.id
    assert Oidc.connection_for_org_slug(slug) == nil
    # A missing org is still a 404 for an operator.
    assert req(op, :put, "/v1/admin/orgs/nope-#{ctx.n}/auth-methods", %{methods: nil}).status ==
             404
  end
end
