defmodule BarkparkWeb.Plugs.BrowserCspTest do
  @moduledoc """
  Unit locks for the root-layout browser CSP (task-0fc9d55c). Pure conn plumbing
  (no DB). The load-bearing invariant is `refute policy =~ "'unsafe-inline'"`:
  Sobelow credits a `content-security-policy` KEY regardless of value, so a
  permissive map is vacuous green — these tests prove the policy is a REAL
  script-blocking backstop (nonce for inline <script>, hashes for the enumerated
  inline handlers, NO 'unsafe-inline'), while keeping the pieces the surfaces
  actually need (cdn.jsdelivr.net for mermaid, wasm/eval).
  """
  use ExUnit.Case, async: true

  import Plug.Conn

  alias BarkparkWeb.CSP
  alias BarkparkWeb.Plugs.BrowserCsp

  defp run do
    BrowserCsp.call(%Plug.Conn{}, BrowserCsp.init([]))
  end

  defp csp(conn), do: get_resp_header(conn, "content-security-policy")

  describe "the plug sets a real, script-blocking CSP + a per-request nonce" do
    test "assigns a binary nonce and sets exactly one CSP header" do
      conn = run()
      assert is_binary(conn.assigns.csp_nonce)
      assert [policy] = csp(conn)
      assert policy == CSP.studio_policy(conn.assigns.csp_nonce)
    end

    test "script-src is present and the assigned nonce is in it" do
      conn = run()
      assert [policy] = csp(conn)
      assert policy =~ "script-src 'self' 'nonce-"
      assert policy =~ "'nonce-#{conn.assigns.csp_nonce}'"
    end

    test "NOT 'unsafe-inline' — the anti-vacuous-green lock" do
      [policy] = run() |> csp()
      refute policy =~ "'unsafe-inline'"
    end

    test "cdn.jsdelivr.net is retained (mermaid survives)" do
      [policy] = run() |> csp()
      assert policy =~ "https://cdn.jsdelivr.net"
    end

    test "the inline-handler + swatch hashes ride 'unsafe-hashes' (no dead-click)" do
      [policy] = run() |> csp()
      assert policy =~ "'unsafe-hashes'"

      for hash <- CSP.script_hashes() do
        assert policy =~ hash
      end
    end

    test "object-src/base-uri/frame-ancestors hardening is present" do
      [policy] = run() |> csp()
      assert policy =~ "object-src 'none'"
      assert policy =~ "base-uri 'self'"
      assert policy =~ "frame-ancestors 'self'"
    end

    test "the nonce is freshly generated per request (never reused)" do
      refute run().assigns.csp_nonce == run().assigns.csp_nonce
    end
  end

  describe "the hashed handler strings match the accessors the templates use (no drift)" do
    defp sha_source(s), do: "'sha256-" <> Base.encode64(:crypto.hash(:sha256, s)) <> "'"

    test "dataset-switcher onchange accessor is allow-listed" do
      assert sha_source(CSP.dataset_switch_onchange()) in CSP.script_hashes()
    end

    test "data-url copy onclick accessor is allow-listed" do
      assert sha_source(CSP.copy_data_url_onclick()) in CSP.script_hashes()
    end

    test "both swatch theme-boot variants are allow-listed" do
      assert sha_source(CSP.swatch_theme_script("light")) in CSP.script_hashes()
      assert sha_source(CSP.swatch_theme_script("dark")) in CSP.script_hashes()
    end
  end

  describe "sso_policy/1 (the SAML SLO surface)" do
    test "is a strict nonce-only script-src — no hashes, no CDN, no unsafe-inline" do
      policy = CSP.sso_policy("ABC123")
      assert policy =~ "script-src 'self' 'nonce-ABC123'"
      refute policy =~ "'unsafe-inline'"
      refute policy =~ "'unsafe-hashes'"
      refute policy =~ "cdn.jsdelivr.net"
      assert policy =~ "object-src 'none'"
    end
  end
end
