defmodule BarkparkWeb.PaperReaderCspIntegrationTest do
  @moduledoc """
  End-to-end lock for the layer-2 paper-reader CSP: proves the `:paper_reader_csp`
  pipeline is actually wired onto the reader scopes (not just that the plug works
  in isolation), and that the reader's wasm script-src self-gates OFF the shared
  `:public_root` bucket siblings + the /email sub-route (which ride the browser
  CSP instead).

  Headless tests CANNOT execute the wasm/mermaid/asciinema paths — a real browser
  smoke still owns final sign-off (see the PR body). What this DOES prove:

    * the CSP header reaches a live `GET /papers/:slug` dead-render with a nonce,
    * the dead-render HTML stamps that nonce on its inline scripts and carries NO
      inline `onclick=` (the refactor that makes an enforcing script-src viable),
    * `GET /sheets/:slug` and `GET /papers/:slug/email` (siblings on the same
      `:browser` bucket) self-gate OFF the reader's wasm script-src and instead
      ride the `:browser` BrowserCsp policy (defense-in-depth), which is safe on
      them (email is script-less; the sheets reader's inline boot is nonced).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @slug "csp-backstop-proof"

  setup do
    Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          body_html: ~s(<section id="block-1"><h1>CSP proof</h1></section>),
          event_type: "plan-written"
        })
      )

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
    # scoped to script-src: style-src legitimately carries 'unsafe-inline'.
    refute policy =~ ~r/script-src[^;]*'unsafe-inline'/

    body = html_response(conn, 200)
    # the inline scripts carry the per-request nonce...
    assert body =~ ~s(nonce="#{conn.assigns.csp_nonce}")
    # ...and the view-toggle buttons no longer use an inline onclick handler.
    refute body =~ "onclick="
    assert body =~ ~s|addEventListener("click", window.__bpToggleTui)|
  end

  test "GET /papers/:slug/email keeps the BROWSER CSP, not the reader's (self-gate OFF)",
       %{conn: conn} do
    conn = get(conn, "/papers/#{@slug}/email")

    # The email byte-stream renders (its own layout, no inline scripts). PaperReaderCsp
    # self-gates OFF the sub-route, so its wasm-reader script-src is NOT applied;
    # the :browser BrowserCsp policy (defense-in-depth, carries 'unsafe-hashes')
    # covers it instead — harmless on the script-less email HTML (task-0fc9d55c).
    policy = csp_of(conn)
    assert policy =~ "'unsafe-hashes'"
    refute policy =~ "'unsafe-inline'"
  end

  test "GET /sheets/:slug (shared-bucket sibling) rides the BROWSER CSP, script nonced",
       %{conn: conn} do
    # A REAL published sheet on the same `:public_root` bucket. PaperReaderCsp
    # self-gates OFF it (no reader wasm policy); the :browser BrowserCsp policy
    # covers it, and the sheets reader layout's inline liveSocket boot carries the
    # per-request nonce so the enforcing script-src does NOT dead-click it.
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
    policy = csp_of(conn)
    assert policy =~ "'unsafe-hashes'"
    refute policy =~ "'unsafe-inline'"
    # the reader layout's inline liveSocket boot is nonced → not blocked.
    assert html_response(conn, 200) =~ ~s(nonce="#{conn.assigns.csp_nonce}")
  end

  @rich_slug "csp-floor-rich-paper"

  describe "the non-script floor against a REAL rendered paper" do
    setup do
      # A representative paper: an image block with a REMOTE https src, a table,
      # a video block, and a link — i.e. every node kind whose fetch the new
      # img-src / media-src / frame-src / default-src floor could plausibly
      # break. If the floor were mis-scoped, this render is where it shows.
      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => @rich_slug,
            "event_type" => "plan-written",
            "blocks" => [
              %{
                "id" => "b1",
                "type" => "heading",
                "level" => 1,
                "content" => [%{"type" => "text", "value" => "Rich CSP paper"}]
              },
              %{
                "id" => "b2",
                "type" => "paragraph",
                "content" => [
                  %{
                    "type" => "text",
                    "value" => "prose long enough to clear the hollow-body gate for this reader"
                  }
                ]
              },
              %{
                "id" => "b3",
                "type" => "image",
                "src" => "https://images.example.com/remote.png",
                "alt" => "a remote image"
              },
              %{
                "id" => "b4",
                "type" => "table",
                "rows" => [["h1", "h2"], ["a", "b"]]
              },
              %{
                "id" => "b5",
                "type" => "video",
                "src" => "https://media.example.com/clip.mp4"
              }
            ]
          })
        )

      :ok
    end

    test "header carries the floor AND the render holds nothing the floor blocks",
         %{conn: conn} do
      conn = get(conn, "/papers/#{@rich_slug}")
      assert conn.status == 200
      policy = csp_of(conn)
      body = html_response(conn, 200)

      # (a) the new directives actually reach a live reader response.
      for directive <- [
            "default-src 'self'",
            "form-action 'self'",
            "frame-src 'self'",
            "font-src 'self' data:"
          ] do
        assert policy =~ directive, "missing #{directive} in: #{policy}"
      end

      # (b) HTML-SHAPE proof, the arm a headless test can actually carry: the
      # rendered page contains no element the two TIGHT directives would block.
      #
      # form-action 'self' — the reader emits no <form> at all, so nothing can
      # be re-pointed off-site.
      refute body =~ "<form"

      # frame-src 'self' — the only frame is #bp-mail-frame, which the layout
      # ships with an EMPTY src and fills from location.pathname (same origin).
      # Any src= on an iframe in the served HTML would be a floor violation.
      frames = Regex.scan(~r/<iframe[^>]*>/, body) |> List.flatten()
      assert length(frames) >= 1, "expected the mail-view iframe in the reader shell"
      for f <- frames, do: refute(f =~ ~r/src\s*=\s*"https?:/)

      # (c) the permissive arms are permissive ON PURPOSE — the remote image and
      # video DID render with their off-site URLs intact, which is exactly why
      # img-src/media-src cannot be pinned to 'self'.
      assert body =~ "https://images.example.com/remote.png"
      assert body =~ "https://media.example.com/clip.mp4"

      # (d) the DOCUMENTED-UNSAFE arm, asserted rather than asserted-away: the
      # renderer really does stamp inline style attributes, so style-src cannot
      # drop 'unsafe-inline'. If this ever stops being true, tighten style-src.
      assert body =~ ~r/<[a-z]+[^>]*\sstyle="/
      assert policy =~ "style-src 'self' 'unsafe-inline'"
    end
  end

  # Fold the header list to a single string ("" when absent) so an assertion can
  # test for the presence/absence of a directive without indexing.
  defp csp_of(conn) do
    conn |> Plug.Conn.get_resp_header("content-security-policy") |> Enum.join(" ")
  end
end
