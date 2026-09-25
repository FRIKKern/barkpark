defmodule BarkparkWeb.Studio.AccountLiveTest do
  @moduledoc """
  era-bl-gdpr-selfserve-ui — the Studio "Your data" page
  (`/w/:ws/p/:proj/d/:dataset/studio/_account`, `BarkparkWeb.Studio.AccountLive`).

  Every refusal arm asserts the account is still intact afterwards (the email is
  unchanged and the session still verifies), so a refusal that erased anyway
  cannot pass. The success arm asserts the erasure itself, not only the redirect.
  """
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]

  require Logger

  alias Barkpark.Accounts
  alias Barkpark.Audit.Event
  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.AccountLive

  import Ecto.Query

  # The fixture password (`AccountsFixtures`' default).
  @password "correct-horse-battery"

  setup %{conn: conn} do
    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: "gdpr-ui-#{System.unique_integer([:positive])}",
        name: "GDPR UI"
      })

    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    email = "gdpr-ui-#{System.unique_integer([:positive])}@example.test"
    user = register_user(email)
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)

    %{
      conn: conn,
      ws: ws,
      user: user,
      email: email,
      raw: raw,
      path: "/w/#{ws.slug}/p/default/d/production/studio/_account"
    }
  end

  defp as_user(conn, raw), do: init_test_session(conn, %{"user_session" => raw})

  defp mount!(ctx) do
    {:ok, view, html} = live(as_user(ctx.conn, ctx.raw), ctx.path)
    {view, html}
  end

  defp submit(view, params), do: view |> form("#erase-form", params) |> render_submit()

  # The account survived: same email, and the session this test holds still
  # verifies. Every refusal arm calls this.
  defp assert_intact!(ctx) do
    assert Repo.get!(Accounts.User, ctx.user.id).email == ctx.email
    assert {%Accounts.User{}, _} = Accounts.verify_user_session(ctx.raw)
  end

  defp erase_events(user_id) do
    Repo.aggregate(
      from(e in Event, where: e.action == "subject_erased" and e.subject == ^user_id),
      :count
    )
  end

  describe "export" do
    test "the signed-in page links GET /v1/auth/export with a fixed, anonymous filename", ctx do
      {view, _html} = mount!(ctx)

      link = element(view, "a[data-test-id=account-export]")
      html = render(link)

      assert html =~ ~s(href="/v1/auth/export")
      assert html =~ ~s(download="barkpark-data-export.json")

      # Privacy-safe: the filename names no one.
      filename = AccountLive.export_filename()
      refute filename =~ ctx.email
      refute filename =~ ctx.user.id
      refute filename =~ "@"
    end

    test "the link's target serves the bundle to the browser's own cookie session", ctx do
      # The same request the anchor produces: a same-origin GET carrying the
      # user_session cookie and a browser navigation Accept header, no bearer.
      body =
        ctx.conn
        |> as_user(ctx.raw)
        |> put_req_header(
          "accept",
          "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        )
        |> get("/v1/auth/export")
        |> json_response(200)

      assert body["account"]["email"] == ctx.email
      assert body["account"]["id"] == ctx.user.id

      # The bundle carries no credential material.
      encoded = Jason.encode!(body)
      refute encoded =~ ctx.raw
      refute encoded =~ "hashed_password"
      refute encoded =~ "totp_secret"
    end
  end

  describe "who sees the controls" do
    test "a token-only session is told why, and gets neither control", ctx do
      raw_token = "gdpr-ui-token-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_token, "GDPR UI", "production", ["read"], ctx.ws.id)

      {:ok, view, html} = live(init_test_session(ctx.conn, %{"api_token" => raw_token}), ctx.path)

      assert has_element?(view, "[data-test-id=account-token-only]")
      assert html =~ "signed in with an API token, which is not an account"
      refute has_element?(view, "#erase-form")
      refute has_element?(view, "a[data-test-id=account-export]")
    end

    test "an anonymous visitor is asked to sign in", ctx do
      # The test posture keeps the public demo on; mount the Default workspace,
      # which anonymous visitors may open, so the page itself decides.
      Barkpark.TenancyFixtures.default_workspace_id!()
      {:ok, view, _html} = live(ctx.conn, "/w/default/p/default/d/production/studio/_account")

      assert has_element?(view, "[data-test-id=account-signed-out]")
      refute has_element?(view, "#erase-form")
    end

    test "a signed-in user sees the consequences before the erase control", ctx do
      {view, _html} = mount!(ctx)
      consequences = view |> element("[data-test-id=erase-consequences]") |> render()

      assert consequences =~ "anonymous placeholder"
      assert consequences =~ "Every sign-in session is revoked"
      assert consequences =~ "pseudonymised, not deleted"

      assert consequences =~
               "Personal access tokens you own are revoked, and your passkeys and social sign-in links"

      assert consequences =~
               "Machine tokens you created as a workspace admin stay with that workspace."

      # The pre-#20324 sentence, false since erasure revokes owned tokens.
      refute consequences =~ "not revoked"
      assert has_element?(view, "#erase-form input[type=password][name=password]")
      assert has_element?(view, "#erase-form input[type=checkbox][name=acknowledge]")
    end
  end

  describe "erase refusals" do
    test "without the acknowledgement nothing is erased", ctx do
      {view, _} = mount!(ctx)
      html = submit(view, %{"password" => @password})

      assert html =~ "Tick the box to confirm"
      assert_intact!(ctx)
      assert erase_events(ctx.user.id) == 0
    end

    test "a missing password is refused inline (the 400 arm)", ctx do
      {view, _} = mount!(ctx)
      html = submit(view, %{"acknowledge" => "true", "password" => ""})

      assert html =~ "Enter your current password"
      assert_intact!(ctx)
      assert erase_events(ctx.user.id) == 0
    end

    test "a wrong password is refused inline (the 403 arm)", ctx do
      {view, _} = mount!(ctx)
      html = submit(view, %{"acknowledge" => "true", "password" => "not-the-password"})

      assert html =~ "That password is not correct. Nothing was erased."
      assert_intact!(ctx)
      assert erase_events(ctx.user.id) == 0
    end

    test "password guessing is capped per user, even for the right password", ctx do
      {view, _} = mount!(ctx)

      for n <- 1..5 do
        html = submit(view, %{"acknowledge" => "true", "password" => "guess-#{n}"})
        assert html =~ "That password is not correct"
      end

      html = submit(view, %{"acknowledge" => "true", "password" => @password})
      assert html =~ "Too many password attempts"
      assert_intact!(ctx)
      assert erase_events(ctx.user.id) == 0
    end
  end

  describe "erase success" do
    test "erases, revokes every session and leaves the authenticated surface", ctx do
      {:ok, other_raw} = Accounts.create_user_session_token(ctx.user)
      {view, _} = mount!(ctx)

      submit(view, %{"acknowledge" => "true", "password" => @password})
      flash = assert_redirect(view, "/login")

      assert flash["info"] =~ "Your account was erased"

      erased = Repo.get!(Accounts.User, ctx.user.id)
      assert erased.email == "erased-#{ctx.user.id}@erased.invalid"
      refute Accounts.User.valid_password?(erased, @password)
      assert erase_events(ctx.user.id) == 1

      # Every session, not just this one.
      assert Accounts.verify_user_session(ctx.raw) == nil
      assert Accounts.verify_user_session(other_raw) == nil
    end

    test "a personal access token the user owns answers 401 once erased through the page",
         ctx do
      {:ok, {pat, _token}} =
        Auth.create_personal_access_token("gdpr-ui-pat", ["read"],
          owner_user_id: ctx.user.id,
          created_by: ctx.email
        )

      mine = fn ->
        ctx.conn |> put_req_header("authorization", "Bearer #{pat}") |> get("/v1/access/mine")
      end

      # Control: before erasure the token authenticates as the user.
      assert mine.().status == 200

      {view, _} = mount!(ctx)
      submit(view, %{"acknowledge" => "true", "password" => @password})
      assert_redirect(view, "/login")

      assert mine.().status == 401
    end

    test "the old cookie is dead afterwards: no page controls, export 401s", ctx do
      {view, _} = mount!(ctx)
      submit(view, %{"acknowledge" => "true", "password" => @password})

      # The erased user's workspace no longer admits the cookie at all...
      dead = ctx.conn |> as_user(ctx.raw) |> get(ctx.path)
      assert dead.status == 403
      refute dead.resp_body =~ "erase-form"

      # ...and where anonymous visitors may look, it reads as signed out.
      {:ok, view2, _} =
        live(as_user(ctx.conn, ctx.raw), "/w/default/p/default/d/production/studio/_account")

      refute has_element?(view2, "#erase-form")
      assert has_element?(view2, "[data-test-id=account-signed-out]")

      assert ctx.conn |> as_user(ctx.raw) |> get("/v1/auth/export") |> json_response(401)
    end

    test "a repeat submission from a second tab does not erase twice", ctx do
      {tab_a, _} = mount!(ctx)
      {tab_b, _} = mount!(ctx)

      submit(tab_a, %{"acknowledge" => "true", "password" => @password})
      assert_redirect(tab_a, "/login")

      # Tab B still shows the form from before the erasure. Its submit carries
      # the right (old) password, but the session behind it is gone.
      submit(tab_b, %{"acknowledge" => "true", "password" => @password})
      flash = assert_redirect(tab_b, "/login")

      assert flash["error"] =~ "Your session has ended"
      assert erase_events(ctx.user.id) == 1
    end
  end

  describe "CSRF" do
    test "the page has no HTTP write door a cross-site form could post to", ctx do
      # The router has no POST route for the page (erasure runs only over the
      # LiveView socket, whose connect is bound to the page's CSRF token).
      assert Phoenix.Router.route_info(BarkparkWeb.Router, "POST", ctx.path, "localhost") ==
               :error

      conn =
        ctx.conn
        |> as_user(ctx.raw)
        |> post(ctx.path, %{"acknowledge" => "true", "password" => @password})

      assert conn.status == 404
      assert_intact!(ctx)
    end

    test "the cookie session cannot drive the HTTP erase without the CSRF header", ctx do
      # The export link rides the cookie session; the same cookie posted
      # cross-site to the erase endpoint (no x-requested-with) is refused.
      conn =
        ctx.conn
        |> as_user(ctx.raw)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/auth/erase", Jason.encode!(%{password: @password}))

      assert json_response(conn, 403)["error"]["code"] == "csrf_required"
      assert_intact!(ctx)
    end
  end

  describe "secret redaction" do
    test "the password is not rendered, assigned or logged", ctx do
      secret = "s3cret-#{System.unique_integer([:positive])}-never-echo"
      {view, _} = mount!(ctx)

      previous = Logger.level()
      Logger.configure(level: :debug)

      {html, log} =
        try do
          with_log([level: :debug], fn ->
            submit(view, %{"acknowledge" => "true", "password" => secret})
          end)
        after
          Logger.configure(level: previous)
        end

      assert html =~ "That password is not correct"

      # Rendered: not in the page, and the password input is empty.
      refute html =~ secret
      refute render(view) =~ secret
      assert view |> element("#erase-form input[type=password]") |> render() =~ ~s(value="")

      # Assigned: nowhere in the LiveView's state.
      state = :sys.get_state(view.pid)
      refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ secret

      # Logged: not at any level. The control proves the capture saw the
      # event's own debug line (LiveView logs submit params, filtered), so the
      # refute below is not vacuous.
      assert log =~ ~s(HANDLE EVENT "erase")
      assert log =~ ~s("password" => "[FILTERED]")
      refute log =~ secret
    end
  end

  describe "entry point" do
    test "the Studio profile dialog links to the page", ctx do
      {:ok, view, _} =
        live(as_user(ctx.conn, ctx.raw), "/w/#{ctx.ws.slug}/p/default/d/production/studio")

      render_click(view, "show-profile", %{})

      assert view |> element("a[data-test-id=profile-account-link]") |> render() =~
               ~s(href="/w/#{ctx.ws.slug}/p/default/d/production/studio/_account")
    end
  end
end
