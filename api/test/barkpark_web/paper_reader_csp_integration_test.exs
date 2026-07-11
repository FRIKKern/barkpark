defmodule BarkparkWeb.PaperReaderCspIntegrationTest do
  @moduledoc """
  End-to-end lock for the layer-2 paper-reader CSP: proves the `:paper_reader_csp`
  pipeline is actually wired onto the reader scopes (not just that the plug works
  in isolation), and that the shared `:public_root` bucket siblings + the /email
  sub-route are untouched.

  Headless tests CANNOT execute the wasm/mermaid/asciinema paths — a real browser
  smoke still owns final sign-off (see the PR body). What this DOES prove:

    * the CSP header reaches a live `GET /papers/:slug` dead-render with a nonce,
    * the dead-render HTML stamps that nonce on its inline scripts and carries NO
      inline `onclick=` (the refactor that makes an enforcing script-src viable),
    * `GET /sheets/:slug` (a 404 sibling on the same bucket) and
      `GET /papers/:slug/email` (the excluded sub-route) get NO CSP header.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @slug "csp-backstop-proof"

  setup do
    Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok, _paper} =
      Content.upsert_paper(%{
        slug: @slug,
        body_html: ~s(<section id="block-1"><h1>CSP proof</h1></section>),
        event_type: "plan-written"
      })

    :ok
  end

  test "GET /papers/:slug carries the script-blocking CSP + a nonced, onclick-free layout",
       %{conn: conn} do
    conn = get(conn, "/papers/#{@slug}")

    assert conn.status == 200

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ ~r/script-src 'self' 'nonce-[^']+' 'wasm-unsafe-eval' 'unsafe-eval'/
    assert policy =~ "https://cdn.jsdelivr.net"
    assert policy =~ "object-src 'none'"
    refute policy =~ "'unsafe-inline'"

    body = html_response(conn, 200)
    # the inline scripts carry the per-request nonce...
    assert body =~ ~s(nonce="#{conn.assigns.csp_nonce}")
    # ...and the view-toggle buttons no longer use an inline onclick handler.
    refute body =~ "onclick="
    assert body =~ ~s|addEventListener("click", window.__bpToggleTui)|
  end

  test "GET /papers/:slug/email (excluded sub-route) does NOT get the script CSP",
       %{conn: conn} do
    conn = get(conn, "/papers/#{@slug}/email")

    # The email view renders (its own layout); it keeps only the Phoenix baseline
    # security-headers CSP (base-uri/frame-ancestors) — the reader's script-src
    # backstop is NOT applied to the sub-route.
    refute csp_of(conn) =~ "script-src"
  end

  test "GET /sheets/:slug (shared-bucket sibling) does NOT get the script CSP",
       %{conn: conn} do
    # A REAL published sheet on the same `:public_root` bucket. The reader CSP
    # must self-gate OFF it (or an enforcing script-src would break the sheets
    # reader's own layout/CDN needs).
    {:ok, _} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => "csp-sheet-sibling",
          "content" => %{"tabs" => [%{"name" => "Data", "cells" => %{"A1" => %{"v" => "hi"}}}]}
        },
        "production"
      )

    {:ok, _} = Content.publish_document("csp-sheet-sibling", "sheet", "production")

    conn = get(conn, "/sheets/csp-sheet-sibling")

    assert conn.status == 200
    refute csp_of(conn) =~ "script-src"
  end

  # Fold the header list to a single string ("" when absent) so an assertion can
  # test for the presence/absence of a directive without indexing.
  defp csp_of(conn) do
    conn |> Plug.Conn.get_resp_header("content-security-policy") |> Enum.join(" ")
  end
end
