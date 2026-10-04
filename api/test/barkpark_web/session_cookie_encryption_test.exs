defmodule BarkparkWeb.SessionCookieEncryptionTest do
  @moduledoc """
  Owner ruling #16 (task-2bf444a2bc350136): the Studio session cookie is
  encrypted, so it no longer carries a readable raw API token.

  The cookie used to be signed only. Its payload is base64 of the session
  term, and a token sign-in stores the raw token under `"api_token"`, so
  anyone who saw the cookie could lift a bearer token usable anywhere.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth

  @token "test-cookie-encryption-token-abcdef123456"

  setup do
    {:ok, _} = Auth.create_token(@token, "cookie-enc", "test", ["read", "admin"])
    :ok
  end

  defp session_cookie(conn) do
    %{value: value} = conn.resp_cookies["_barkpark_key"]
    value
  end

  # Every base64 segment of the cookie, decoded as far as it decodes. A
  # signed-only cookie's first segment is the readable session term.
  defp decoded_segments(cookie) do
    cookie
    |> String.split(".")
    |> Enum.flat_map(fn seg ->
      case Base.url_decode64(seg, padding: false) do
        {:ok, bin} -> [bin]
        :error -> []
      end
    end)
  end

  test "after a token sign-in the cookie holds no raw API token", %{conn: conn} do
    conn = post(conn, "/login", %{"token" => @token})
    assert redirected_to(conn) =~ "/"

    cookie = session_cookie(conn)
    refute cookie =~ @token

    for bin <- decoded_segments(cookie) do
      refute bin =~ @token, "the decoded cookie still carries the raw API token"
    end

    # Plug's encrypted cookie format (XChaCha20-Poly1305), not a signed one.
    assert String.starts_with?(cookie, "XCP.")
  end

  test "the encrypted cookie still signs the browser in", %{conn: conn} do
    signed_in = post(conn, "/login", %{"token" => @token})
    cookie = session_cookie(signed_in)

    conn =
      build_conn()
      |> put_req_cookie("_barkpark_key", cookie)
      |> get("/studio/styleguide")

    # The admin-gated Studio page renders for the signed-in browser.
    assert html_response(conn, 200)
  end

  test "a cookie minted before the change (signed only) reads as signed out", %{conn: conn} do
    opts =
      BarkparkWeb.Endpoint.session_options()
      |> Keyword.delete(:encryption_salt)
      |> Plug.Session.init()

    legacy =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Map.put(:secret_key_base, BarkparkWeb.Endpoint.config(:secret_key_base))
      |> Plug.Session.call(opts)
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_session("api_token", @token)
      |> Plug.Conn.send_resp(200, "")
      |> session_cookie()

    conn = build_conn() |> put_req_cookie("_barkpark_key", legacy) |> get("/studio/styleguide")

    # Turned away exactly like a browser with no cookie at all.
    bare = get(build_conn(), "/studio/styleguide")
    assert conn.status == 302
    assert redirected_to(conn) == redirected_to(bare)
  end
end
