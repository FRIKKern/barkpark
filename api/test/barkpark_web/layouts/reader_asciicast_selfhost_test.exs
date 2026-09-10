defmodule BarkparkWeb.Layouts.ReaderAsciicastSelfhostTest do
  @moduledoc """
  pe-bl-asciicast-selfhost — the asciicast player is OURS, not a CDN's.

  The reader used to name `cdn.jsdelivr.net` twice for asciinema-player 3.8.0:
  the stylesheet in `<head>` and the engine (`defer`) at the bottom of
  `<body>`. Every paper page therefore opened a third-party connection for the
  CSS whether or not it held an asciicast, and every asciicast was dead behind
  a strict CSP, in an air-gapped reader, or with the CDN simply blocked.

  Both tags now point at `/assets/`, served by `Plug.Static` out of
  `priv/static/assets/` (`BarkparkWeb.static_paths/0` covers `assets`).

  What each test below pins, and why the set is what it is:

    * The rendered page names the local URLs — the assertion that would go red
      if someone re-pointed a tag at a CDN.
    * The rendered page names NO jsdelivr asciinema URL. Asserting the local
      URL alone is not enough: both tags could coexist, and the CDN one would
      still be fetched.
    * The engine keeps `defer` and stays BELOW `</head>` (golden rule 4).
    * The vendored bytes exist, are non-trivial, and — the load-bearing one —
      reference no external URL of their own. A self-hosted bundle that then
      fetched a font, a sourcemap or its WebAssembly off a CDN would move the
      third-party dependency without removing it, and the offline proof would
      be a lie. The `vt` WebAssembly is inlined as a base64 `data:` payload;
      the CSS has zero `url(...)` references.

  `cdn.jsdelivr.net` is deliberately NOT asserted absent from the page as a
  whole: mermaid still loads from it, and its CSP allowance
  (`plugs/paper_reader_csp.ex`) stays. This change stops the PLAYER needing
  the CDN — nothing more.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @layout "lib/barkpark_web/layouts/bulldocs.html.heex"
  @js "priv/static/assets/asciinema-player.min.js"
  @css "priv/static/assets/asciinema-player.css"
  @license "priv/static/assets/asciinema-player.LICENSE.txt"

  @slug "reader-asciicast-selfhost"

  defp seed_paper do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          body_html:
            ~s(<section id="b1"><p>A paper carrying a terminal recording, so the ) <>
              ~s(reader page emits the player tags this test reads.</p>) <>
              ~s(<div class="bp-asciicast" data-cast-src="/media/files/2026/09/demo.cast"></div></section>),
          event_type: "plan-written"
        })
      )

    paper
  end

  describe "the rendered reader page loads the player from our own origin" do
    setup %{conn: conn} do
      seed_paper()
      conn = get(conn, "/papers/#{@slug}")
      {:ok, html: html_response(conn, 200)}
    end

    test "the stylesheet is /assets/asciinema-player.css", %{html: html} do
      assert html =~ ~s(href="/assets/asciinema-player.css"),
             "the reader must load the vendored player stylesheet, not a CDN's"
    end

    test "the engine is /assets/asciinema-player.min.js, still deferred", %{html: html} do
      assert html =~ ~s(<script defer src="/assets/asciinema-player.min.js"></script>),
             "the engine must be local AND keep `defer` (golden rule 4)"
    end

    test "no jsdelivr URL names asciinema-player any more", %{html: html} do
      refute html =~ "cdn.jsdelivr.net/npm/asciinema-player",
             "a surviving CDN tag would still be fetched even with the local one present"
    end

    test "the engine tag sits below </head>, never inside it", %{html: html} do
      [head, body] = String.split(html, "</head>", parts: 2)

      refute head =~ "asciinema-player.min.js",
             "golden rule 4: no <script> for the player in <head>"

      assert body =~ "asciinema-player.min.js"
    end
  end

  describe "the vendored bundle" do
    test "both assets are present and non-trivial" do
      assert File.exists?(@js), "#{@js} must be committed — the page now 404s without it"
      assert File.exists?(@css)
      assert File.exists?(@license), "provenance + digests + re-vendor commands"

      assert File.stat!(@js).size > 100_000
      assert File.stat!(@css).size > 10_000
    end

    test "it still defines the window.AsciinemaPlayer global the reader hook waits on" do
      assert File.read!(@js) =~ "AsciinemaPlayer"
    end

    test "the engine references no external URL at all" do
      assert Regex.scan(~r{https?://[^\s"'()]+}, File.read!(@js)) == [],
             "#{@js} reaches off-origin — self-hosting it would relocate the CDN " <>
               "dependency, not remove it"
    end

    test "the stylesheet fetches nothing: no url(...), no @import" do
      # NOT an `https?://` scan like the engine's. The stylesheet carries six
      # http(s) URLs and every one is inside a `/* … */` theme attribution
      # (draculatheme.com, base16, nord, solarized ×2, Tango) — prose, not a
      # request. `url(...)` and `@import` are the two constructs that would
      # actually fetch, so those are what this asserts. Rewriting it as a
      # blanket URL scan would go red on a comment and teach the next reader to
      # delete the check.
      css = File.read!(@css)

      assert Regex.scan(~r/url\(/, css) == [],
             "a url(...) is a font/image fetch the offline proof would miss"

      assert Regex.scan(~r/@import/, css) == [],
             "an @import pulls a whole second stylesheet, possibly off-origin"
    end

    test "the WebAssembly ships inline, as a base64 data: payload" do
      assert File.read!(@js) =~ "AGFzbQ",
             "the vt wasm must be inlined; a separate .wasm fetch would 404 off /assets/"
    end
  end

  describe "the layout source" do
    test "names no jsdelivr asciinema URL" do
      refute File.read!(@layout) =~ "cdn.jsdelivr.net/npm/asciinema-player"
    end
  end
end
