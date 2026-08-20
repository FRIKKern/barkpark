defmodule BarkparkWeb.BrowserCspIntegrationTest do
  @moduledoc """
  End-to-end completeness lock for the root-layout CSP (task-0fc9d55c). Renders
  a real `:browser` page (the login form — public, no auth) and proves the
  invariant that makes a nonce-based script-src SAFE: the response carries the
  tailored policy AND every executable inline `<script>` the page ships (the
  root.html.heex theme-boot / editor-no-inject / self-update / liveSocket boots
  + the login password-eye toggle) carries the SAME per-request nonce. A missed
  inline script would render nonce-less → be blocked → dead-click; this test is
  the guard that the sweep is complete for this surface.
  """
  use BarkparkWeb.ConnCase, async: false

  test "GET /login ships a real script-src and nonces EVERY inline <script>", %{conn: conn} do
    conn = get(conn, "/login")
    html = html_response(conn, 200)

    # The tailored policy is on the response (BrowserCsp).
    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "script-src 'self' 'nonce-"
    refute policy =~ "'unsafe-inline'"
    assert policy =~ "https://cdn.jsdelivr.net"

    # The one nonce, shared by header and scripts.
    assert [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)

    # Every executable inline <script> (no src=, not application/ld+json data)
    # must carry that nonce — else the tightened script-src dead-clicks it.
    inline_scripts =
      Regex.scan(~r/<script(?![^>]*\bsrc=)(?![^>]*application\/ld\+json)([^>]*)>/, html)
      |> Enum.map(fn [_full, attrs] -> attrs end)

    assert inline_scripts != [], "expected the page to ship inline <script> blocks"

    for attrs <- inline_scripts do
      assert attrs =~ ~s|nonce="#{nonce}"|,
             "an inline <script> is missing the CSP nonce (would be blocked): #{inspect(attrs)}"
    end
  end
end
