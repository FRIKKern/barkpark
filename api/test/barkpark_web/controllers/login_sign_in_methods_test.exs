defmodule BarkparkWeb.LoginSignInMethodsTest do
  @moduledoc """
  The /login page sends each user to the right sign-in method
  (task-9963609c3ef5276f, FRIKKern/barkpark#24201).

  An instance with no SSO connection, no verified domain and no passkey keeps
  today's page. One connected org gets a button per connection. An SSO-only
  org leads with SSO and keeps password sign-in one click away. An email on a
  verified domain goes to its org's OIDC or SAML start URL. Every SSO link
  keeps the page's return_to.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts.WebauthnCredential
  alias Barkpark.Repo
  alias Barkpark.Sso.{Domains, Oidc, Saml}
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Organization

  @tenant "8c9532bc-4cba-49a8-a7fd-58fcada85c0a"
  @entra "https://login.microsoftonline.com/#{@tenant}"

  defmodule MockResolver do
    @behaviour Barkpark.Sso.Domains.Resolver
    @impl true
    def txt_records(_d), do: Application.get_env(:barkpark, :dns_test, [])
  end

  setup do
    Application.put_env(:barkpark, :dns_resolver, MockResolver)

    on_exit(fn ->
      Application.delete_env(:barkpark, :dns_resolver)
      Application.delete_env(:barkpark, :dns_test)
    end)

    :ok
  end

  defp org(slug, methods \\ nil) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: String.capitalize(slug)})

    if methods,
      do: org |> Organization.changeset(%{allowed_auth_methods: methods}) |> Repo.update!(),
      else: org
  end

  defp entra(org, attrs \\ %{}) do
    {:ok, c} =
      Oidc.create_connection(
        Map.merge(
          %{
            organization_id: org.id,
            issuer: @entra <> "/v2.0",
            client_id: "56de97bb-358d-44da-b877-4d700a3e718b",
            client_secret: "s",
            authorization_endpoint: @entra <> "/oauth2/v2.0/authorize",
            token_endpoint: @entra <> "/oauth2/v2.0/token",
            jwks_uri: @entra <> "/discovery/v2.0/keys"
          },
          attrs
        )
      )

    c
  end

  defp saml(org) do
    key = X509.PrivateKey.new_rsa(2048)
    cert = X509.Certificate.self_signed(key, "/CN=Test IdP")

    {:ok, c} =
      Saml.create_connection(%{
        organization_id: org.id,
        idp_entity_id: "https://idp.example.com/entity",
        idp_sso_url: "https://idp.example.com/sso",
        idp_cert_pem: X509.Certificate.to_pem(cert)
      })

    c
  end

  defp verify_domain(org, domain) do
    {:ok, rec} = Domains.request_verification(org, domain)
    Application.put_env(:barkpark, :dns_test, [rec.dns_token])
    {:ok, _} = Domains.verify(domain)
  end

  defp login_page(conn, query \\ ""), do: conn |> get("/login" <> query) |> html_response(200)

  defp sso_hrefs(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("a[data-sso-button]")
    |> LazyHTML.attribute("href")
  end

  defp route(conn, email) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/sso/route", Jason.encode!(%{email: email}))
    |> json_response(200)
  end

  describe "an instance with no SSO connection" do
    test "keeps today's page: no SSO button, no routing, no passkey, the old hint",
         %{conn: conn} do
      html = login_page(conn)

      assert sso_hrefs(html) == []
      refute html =~ "/v1/auth/sso/route"
      refute html =~ "data-passkey"
      refute html =~ "data-password-signin"
      assert html =~ "/v1/auth/oidc/&lt;org&gt;/start"
      assert html =~ ~s(action="/login/account")

      password =
        html |> LazyHTML.from_document() |> LazyHTML.query("#account_password")

      assert LazyHTML.attribute(password, "required") == [""]
    end

    test "a verified domain whose org has no connection does not route", %{conn: conn} do
      o = org("nosso")
      verify_domain(o, "nosso.example")

      assert route(conn, "ann@nosso.example") == %{"sso" => false}
      refute login_page(build_conn()) =~ "/v1/auth/sso/route"
    end

    test "an email with no password still needs both fields", %{conn: conn} do
      html =
        conn
        |> post("/login/account", %{"email" => "ann@nowhere.example", "password" => ""})
        |> html_response(200)

      assert html =~ "Email and password are required."
    end
  end

  describe "an instance with one Entra org" do
    setup do
      o = org("pensum")
      entra(o)
      {:ok, org: o}
    end

    test "shows Sign in with Microsoft, linked to the org's OIDC start", %{conn: conn} do
      html = login_page(conn)

      assert sso_hrefs(html) == ["/v1/auth/oidc/pensum/start"]
      assert html =~ "Sign in with Microsoft"
      # Password sign-in stays on the page, below the button.
      assert html =~ "or sign in with email"
      assert html =~ ~s(id="account_password")
      refute html =~ "data-password-signin"
      refute html =~ "/v1/auth/oidc/&lt;org&gt;/start"
    end

    test "renders in Norwegian as Logg inn med Microsoft", %{conn: conn} do
      html = conn |> put_req_header("accept-language", "nb-NO,nb;q=0.9") |> login_page()

      assert html =~ "Logg inn med Microsoft"
      assert html =~ "eller logg inn med e-post"
    end

    test "the button starts the Entra flow at login.microsoftonline.com", %{conn: conn} do
      [href] = conn |> login_page() |> sso_hrefs()
      location = build_conn() |> get(href) |> redirected_to(302)

      assert String.starts_with?(location, @entra <> "/oauth2/v2.0/authorize?")
    end

    test "an inactive connection shows no button", %{conn: conn, org: o} do
      {:ok, _} = Oidc.update_connection(Oidc.connection_for_org_slug(o.slug), %{active: false})

      assert conn |> login_page() |> sso_hrefs() == []
    end

    test "a second connected org hides every button, so no org name is listed",
         %{conn: conn} do
      entra(org("other-customer"))
      html = login_page(conn)

      assert sso_hrefs(html) == []
      refute html =~ "pensum"
      refute html =~ "other-customer"
    end
  end

  describe "return_to is kept" do
    setup do
      entra(org("pensum"))
      :ok
    end

    test "the SSO button carries the page's return_to", %{conn: conn} do
      html = login_page(conn, "?return_to=%2Fw%2Fpensum%2Fstudio%2Fbooks")

      assert sso_hrefs(html) == [
               "/v1/auth/oidc/pensum/start?return_to=%2Fw%2Fpensum%2Fstudio%2Fbooks"
             ]
    end

    test "an off-site return_to is dropped, not forwarded", %{conn: conn} do
      html = login_page(conn, "?return_to=%2F%2Fevil.example")

      assert sso_hrefs(html) == ["/v1/auth/oidc/pensum/start"]
    end

    test "an email routed to SSO keeps return_to on its redirect", %{conn: conn} do
      o = Tenancy.get_organization_by_slug("pensum")
      verify_domain(o, "pensum.example")

      to =
        conn
        |> post("/login/account", %{
          "email" => "editor@pensum.example",
          "return_to" => "/w/pensum/studio"
        })
        |> redirected_to(302)

      assert to == "/v1/auth/oidc/pensum/start?return_to=%2Fw%2Fpensum%2Fstudio"
    end
  end

  describe "an SSO-only org" do
    setup do
      o = org("pensum", ["sso"])
      entra(o)
      {:ok, org: o}
    end

    test "leads with the SSO button and folds password sign-in away", %{conn: conn} do
      html = login_page(conn)
      doc = LazyHTML.from_document(html)

      assert sso_hrefs(html) == ["/v1/auth/oidc/pensum/start"]
      refute html =~ "or sign in with email"

      # Password sign-in is still reachable for break-glass accounts, inside a
      # closed <details>.
      folded = LazyHTML.query(doc, "details[data-password-signin]")
      assert LazyHTML.attribute(folded, "open") == []
      assert folded |> LazyHTML.query("#account_password") |> Enum.count() == 1
      assert folded |> LazyHTML.query(~s(form[action="/login/account"])) |> Enum.count() == 1
      assert html =~ "Sign in with a password (break-glass accounts)"
    end

    test "the route answer marks the domain SSO-only", %{conn: conn, org: o} do
      verify_domain(o, "pensum.example")

      assert %{"sso" => true, "protocol" => "oidc", "sso_only" => true} =
               route(conn, "editor@pensum.example")
    end
  end

  describe "email-domain routing" do
    test "an email on a verified SAML org's domain redirects to its SAML start URL",
         %{conn: conn} do
      o = org("samlco")
      saml(o)
      verify_domain(o, "samlco.example")

      assert route(conn, "ann@samlco.example") == %{
               "sso" => true,
               "organization" => "samlco",
               "protocol" => "saml",
               "start_url" => "/v1/auth/saml/samlco/start",
               "sso_only" => false
             }

      to =
        build_conn()
        |> post("/login/account", %{"email" => "ann@samlco.example", "password" => ""})
        |> redirected_to(302)

      assert to == "/v1/auth/saml/samlco/start"
      assert build_conn() |> get(to) |> redirected_to(302) =~ "https://idp.example.com/sso?"
    end

    test "with two connected orgs, routing works and names neither on the page",
         %{conn: conn} do
      a = org("alpha")
      entra(a)
      verify_domain(a, "alpha.example")
      b = org("bravo", ["sso"])
      saml(b)
      verify_domain(b, "bravo.example")

      html = login_page(conn)
      assert sso_hrefs(html) == []
      assert html =~ "/v1/auth/sso/route"
      assert html =~ "data-sso-routing-hint"
      refute html =~ "alpha"
      refute html =~ "bravo"

      # The password field is not required, so an email alone can be submitted.
      password = html |> LazyHTML.from_document() |> LazyHTML.query("#account_password")
      assert LazyHTML.attribute(password, "required") == []

      assert %{"start_url" => "/v1/auth/saml/bravo/start", "sso_only" => true} =
               route(build_conn(), "x@bravo.example")

      assert %{"start_url" => "/v1/auth/oidc/alpha/start", "sso_only" => false} =
               route(build_conn(), "x@alpha.example")
    end

    test "a password still signs in through the password door", %{conn: conn} do
      o = org("pwco")
      entra(o)
      verify_domain(o, "pwco.example")

      html =
        conn
        |> post("/login/account", %{"email" => "nobody@pwco.example", "password" => "wrong-pass"})
        |> html_response(200)

      assert html =~ "Email or password is incorrect."
    end
  end

  describe "passkeys" do
    test "no registered passkey shows no passkey button", %{conn: conn} do
      refute login_page(conn) =~ "data-passkey"
    end

    test "a registered passkey adds the button, hidden until the browser supports it",
         %{conn: conn} do
      user = Barkpark.AccountsFixtures.register_user("passkey-owner@example.com")

      Repo.insert!(%WebauthnCredential{
        user_id: user.id,
        credential_id: :crypto.strong_rand_bytes(16),
        cose_key: :erlang.term_to_binary(%{-2 => "x", -3 => "y"}),
        nickname: "laptop"
      })

      html = login_page(conn, "?return_to=%2Fw%2Fpensum%2Fstudio")
      box = html |> LazyHTML.from_document() |> LazyHTML.query("[data-passkey]")

      assert LazyHTML.attribute(box, "hidden") == [""]
      assert html =~ "Sign in with a passkey"
      assert html =~ ~s(data-return-to="/w/pensum/studio")
      assert html =~ "window.PublicKeyCredential"
      assert html =~ "/v1/auth/webauthn/login/challenge"
    end
  end

  describe "GET /login/account" do
    test "redirects to /login", %{conn: conn} do
      assert conn |> get("/login/account") |> redirected_to(302) == "/login"
    end

    test "keeps a same-origin return_to and drops any other", %{conn: conn} do
      assert conn |> get("/login/account?return_to=%2Fw%2Fpensum") |> redirected_to(302) ==
               "/login?return_to=%2Fw%2Fpensum"

      assert build_conn()
             |> get("/login/account?return_to=https%3A%2F%2Fevil.example")
             |> redirected_to(302) == "/login"
    end
  end
end
