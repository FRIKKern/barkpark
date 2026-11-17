defmodule BarkparkWeb.LoginReturnToTicketTest do
  @moduledoc """
  task-1757bffde0f4c254: a sign-in through "Log in with Barkpark Cloud" (the
  ticket) or the emailed magic link lands on the page `/login?return_to=`
  named, not on `/studio`. Both come back on a new request with no form, so
  `GET /login` keeps the path in the session (`BarkparkWeb.LoginReturn`).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias BarkparkWeb.LoginReturn

  @admin_token "return-to-admin-token-abcdef"
  @panel "/w/default/p/default/studio/ecosystem-panel"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "return-to admin", "production", ["read", "write", "admin"])

    :ok
  end

  defp ticket!(email \\ "cloud-owner@return.example") do
    {:ok, ticket} = Auth.mint_login_ticket(@admin_token, user_email: email)
    ticket
  end

  defp login_page(conn \\ scoped_conn(), return_to) do
    get(conn, "/login?" <> URI.encode_query(%{"return_to" => return_to}))
  end

  defp then_get(conn, path), do: conn |> recycle_scoped() |> get(path)

  test "a Cloud ticket after /login?return_to= lands on that page" do
    conn = login_page(@panel) |> then_get("/login/ticket/#{ticket!()}")

    assert redirected_to(conn) == @panel
    assert is_binary(get_session(conn, "user_session"))
    refute get_session(conn, LoginReturn.session_key())
  end

  test "an emailed magic link after /login?return_to= lands on that page" do
    {:ok, _} =
      Accounts.register_user(%{email: "magic@return.example", password: "return-to-pass-123456"})

    {:ok, token, _} = Accounts.build_login_token("magic@return.example")

    conn =
      login_page(@panel)
      |> then_get("/login/magic")
      |> then_get("/auth/magic/#{token}")

    assert redirected_to(conn) == @panel
    assert is_binary(get_session(conn, "user_session"))
  end

  test "an unsafe or sign-in return_to lands on /studio" do
    for bad <- [
          "//evil.example",
          "/\\evil.example",
          "/%2F%2Fevil.example",
          "/%5Cevil.example",
          "/%09/evil.example",
          "https://evil.example",
          "javascript:alert(1)",
          "/logout",
          "/login",
          "/login?return_to=/studio",
          "/login/ticket/bplt_x",
          "/auth/magic/x",
          "/%2e%2e/login",
          "/LOGIN",
          "/Login/ticket/x",
          "/login;x",
          "/login.html"
        ] do
      conn = login_page(bad) |> then_get("/login/ticket/#{ticket!()}")
      assert redirected_to(conn) == "/studio", "return_to #{inspect(bad)}"
    end
  end

  test "the path is used once; a ticket with no /login first lands on /studio" do
    first = login_page(@panel) |> then_get("/login/ticket/#{ticket!()}")
    assert redirected_to(first) == @panel

    second = then_get(first, "/login/ticket/#{ticket!("second@return.example")}")
    assert redirected_to(second) == "/studio"

    fresh = scoped_conn() |> get("/login/ticket/#{ticket!("third@return.example")}")
    assert redirected_to(fresh) == "/studio"
  end

  test "a later /login without return_to forgets the path" do
    conn =
      login_page(@panel)
      |> then_get("/login")
      |> then_get("/login/ticket/#{ticket!()}")

    assert redirected_to(conn) == "/studio"
  end

  test "a path stored longer ago than the TTL lands on /studio" do
    stale = System.system_time(:second) - LoginReturn.ttl_seconds() - 1

    conn =
      scoped_conn()
      |> init_test_session(%{LoginReturn.session_key() => %{"path" => @panel, "at" => stale}})
      |> get("/login/ticket/#{ticket!()}")

    assert redirected_to(conn) == "/studio"
  end

  test "a return_to too long for the session cookie is not stored; /login still renders" do
    for n <- [3000, 8000] do
      long = "/w/default/p/default/studio/" <> String.duplicate("a", n)
      page = login_page(long)

      assert html_response(page, 200)
      refute get_session(page, LoginReturn.session_key())
    end
  end

  test "a JSON password sign-in (the passkey door's issuer) spends the path" do
    {:ok, _} =
      Accounts.register_user(%{email: "json@return.example", password: "return-to-pass-123456"})

    signed_in =
      login_page(@panel)
      |> recycle_scoped()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/auth/login",
        Jason.encode!(%{email: "json@return.example", password: "return-to-pass-123456"})
      )

    assert signed_in.status == 201
    refute get_session(signed_in, LoginReturn.session_key())

    later = then_get(signed_in, "/login/ticket/#{ticket!("other@return.example")}")
    assert redirected_to(later) == "/studio"
  end

  # Every door that mints a browser session must spend the stored path, or it
  # survives one person's sign-in into the next. OIDC, SAML and social need an
  # IdP to drive end to end, so this holds the line on the source instead.
  test "every file that puts a user_session also forgets the stored path" do
    minting =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(&(File.read!(&1) =~ ~s|put_session("user_session"|))

    assert "lib/barkpark_web/session_issuer.ex" in minting
    assert length(minting) >= 5

    for file <- minting do
      assert File.read!(file) =~ "LoginReturn.forget(",
             "#{file} mints a session without forgetting"
    end
  end

  test "a used ticket sends the browser back to /login with the path kept" do
    ticket = ticket!()
    _used = scoped_conn() |> get("/login/ticket/#{ticket}")

    conn = login_page(@panel) |> then_get("/login/ticket/#{ticket}")

    assert redirected_to(conn) == "/login?" <> URI.encode_query(%{"return_to" => @panel})
  end
end
