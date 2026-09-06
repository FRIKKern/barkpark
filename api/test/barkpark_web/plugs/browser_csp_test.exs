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

    # ── The retired stop-propagation entry, proven dead in BOTH directions ──
    #
    # spd-w5-secondary-pane-reachability removed the only consumer of
    # `onclick="event.stopPropagation()"` (editor_fields.ex, charter D96), so
    # spd-csp-stop-propagation-allowlist-dead retired the constant. Direction A
    # asserts the hash is GONE; direction B asserts a still-live handler is
    # still hashed AND still emitted by a template — without B, A would pass
    # just as happily against a policy that emits no hashes at all.

    test "DIRECTION A: the retired stop-propagation handler is NOT allow-listed" do
      dead = sha_source("event.stopPropagation()")
      [policy] = run() |> csp()

      refute dead in CSP.script_hashes()
      refute policy =~ dead
    end

    test "DIRECTION B: a still-live handler is still hashed AND still emitted" do
      # `this.select()` is a dead-stable literal on the two share-url inputs in
      # modals.ex. Read the template source so the proof binds to the bytes the
      # browser receives, not to a constant in csp.ex quoting itself.
      modals = File.read!("lib/barkpark_web/components/studio_components/modals.ex")
      assert modals =~ ~s|onclick="this.select()"|

      live = sha_source("this.select()")
      [policy] = run() |> csp()

      assert live in CSP.script_hashes()
      assert policy =~ live
    end

    test "the emitted policy carries exactly the allow-listed hashes, no more" do
      [policy] = run() |> csp()

      emitted =
        ~r/'sha256-[A-Za-z0-9+\/=]+'/
        |> Regex.scan(policy)
        |> List.flatten()
        |> MapSet.new()

      assert emitted == MapSet.new(CSP.script_hashes())

      # 6 inline handlers + 2 swatch variants. Was 9 before the stop-propagation
      # entry was retired; the previous set minus exactly one.
      assert MapSet.size(emitted) == 8
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
