defmodule BarkparkWeb.Layouts.ReaderMermaidSharedAssetTest do
  @moduledoc """
  task-e96ac3b80506cf32 — ONE Mermaid hook, ONE palette.

  The PaperMermaid hook and the evergreen mermaid palette existed TWICE: inline
  in `layouts/bulldocs.html.heex` (the papers reader, the original) and in
  `priv/static/assets/bp-paper-mermaid.js` (added for the Studio chat). Every
  engine fix or palette tweak had to be made in both places and could silently
  drift. The reader now consumes the shared asset.

  Two things must NOT be collateral damage, and each has a test below:

    * `runAsciicast` (asciinema) is READER-ONLY. It stays in the reader's own
      hook and is deliberately absent from the shared asset, so Studio chat is
      never made to carry a player it does not paint.
    * The reader's mode behaviour. Studio chat follows the raw OS
      `prefers-color-scheme`; the reader's dark/light pill stamps
      `html[data-theme]` pre-paint and that stamp WINS, with the OS query as
      the fallback. The reader keeps that by overriding the asset's documented
      `isDark` seam and driving re-render from its own `bp:mode` event.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @asset "priv/static/assets/bp-paper-mermaid.js"
  @layout "lib/barkpark_web/layouts/bulldocs.html.heex"

  @slug "reader-mermaid-shared-asset"

  defp asset, do: File.read!(@asset)
  defp layout, do: File.read!(@layout)

  defp seed_paper do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          body_html:
            ~s(<section id="b1"><pre class="mermaid">graph TD; A--&gt;B;</pre></section>),
          event_type: "plan-written"
        })
      )

    paper
  end

  describe "the rendered reader page points at the shared asset" do
    setup %{conn: conn} do
      seed_paper()
      conn = get(conn, "/papers/#{@slug}")
      {:ok, html: html_response(conn, 200)}
    end

    test "it loads /assets/bp-paper-mermaid.js — the same asset Studio chat loads",
         %{html: html} do
      assert html =~ ~s(src="/assets/bp-paper-mermaid.js"),
             "the reader must consume the shared Mermaid asset"
    end

    test "the engine is still loaded, and NOTHING mermaid blocks in <head>", %{html: html} do
      assert html =~ "mermaid.min.js", "the reader still needs the mermaid engine"

      # Golden Rule #4. The engine is `defer`; the hook asset is non-defer (so
      # window.BarkparkPaperMermaid exists before the LiveSocket registers
      # hooks) and therefore MUST live in the body, after </head>.
      assert html =~ ~s(<script defer src="https://cdn.jsdelivr.net/npm/mermaid@11)

      head_end = :binary.match(html, "</head>") |> elem(0)
      hook_at = :binary.match(html, ~s(src="/assets/bp-paper-mermaid.js")) |> elem(0)

      assert hook_at > head_end,
             "the non-defer hook asset must load in <body>, never blocking in <head>"

      engine_at = :binary.match(html, "mermaid.min.js") |> elem(0)
      assert engine_at > head_end, "the mermaid engine must not sit in <head> either"
    end

    test "the inline engine is GONE — no second initialize, no second palette",
         %{html: html} do
      refute html =~ "mermaid.initialize",
             "the reader re-grew its own engine init; /assets/bp-paper-mermaid.js owns it"

      refute html =~ "mermaidThemeVariables",
             "the reader re-grew its own palette function"

      refute html =~ "primaryBorderColor",
             "a mermaid palette literal is back in the reader layout"
    end

    test "the reader still loads the asciinema player it alone paints", %{html: html} do
      assert html =~ "asciinema-player@3.8.0"
      assert html =~ "runAsciicast"
    end
  end

  describe "the theme-variable source is SINGLE" do
    test "the palette literals live in the asset and NOWHERE under lib/barkpark_web" do
      assert asset() =~ "primaryBorderColor"

      offenders =
        Path.wildcard("lib/barkpark_web/**/*.{ex,heex}")
        |> Enum.filter(&(File.read!(&1) =~ "primaryBorderColor"))

      assert offenders == [],
             "mermaid themeVariables must exist only in #{@asset}, found also in: " <>
               inspect(offenders)
    end

    test "the reader configures the asset's seams instead of forking it" do
      l = layout()

      assert l =~ "window.BarkparkPaperMermaid.isDark",
             "the reader must override isDark, or its data-theme pill loses authority"

      assert l =~ "window.BarkparkPaperMermaid.autoScheme = false",
             "the reader drives re-render from bp:mode, not the raw scheme listener"

      assert l =~ "window.BarkparkPaperMermaid.rerenderAll()"
      assert l =~ ~s[window.addEventListener("bp:mode",]

      assert l =~ "window.BarkparkPaperMermaid.runMermaid.call(this)",
             "the reader's hook must delegate runMermaid to the shared asset"
    end
  end

  describe "reader mode behaviour is preserved (BOTH color schemes)" do
    test "the reader's isDark prefers the data-theme stamp and FALLS BACK to the OS query" do
      l = layout()

      assert l =~ "document.documentElement.dataset.theme"

      assert l =~ ~s[window.matchMedia("(prefers-color-scheme: dark)")],
             "prefers-color-scheme must remain the reader's no-stamp fallback"
    end

    test "the asset's DEFAULT isDark is the raw OS query — Studio chat is unchanged" do
      a = asset()

      assert a =~ "isDark: () => scheme.matches"
      assert a =~ ~s[const scheme = window.matchMedia("(prefers-color-scheme: dark)")]

      assert a =~ "autoScheme: true",
             "a surface with no mode control must still re-render on an OS flip"

      assert a =~ "if (api.autoScheme) rerenderAll()"
    end

    test "the dark and light palettes declare the SAME keys — neither scheme is half-skinned" do
      {dark, light} = palettes(asset())

      assert dark != []

      assert dark == light,
             "dark/light palette key sets diverge: #{inspect(dark -- light)} / " <>
               inspect(light -- dark)
    end

    test "the palette values are the reader's proven evergreen literals, unchanged by the dedup" do
      a = asset()

      # Dark branch — spot values carried over verbatim from the reader's
      # inline copy on origin/main.
      assert a =~ ~s(background: "#0e1614")
      assert a =~ ~s(primaryBorderColor: "#45b394")
      assert a =~ ~s(noteBkgColor: "#1c2620")

      # Light branch.
      assert a =~ ~s(background: "#f6faf9")
      assert a =~ ~s(primaryBorderColor: "#1e5347")
      assert a =~ ~s(noteBkgColor: "#e6f0eb")
    end
  end

  describe "runAsciicast stays reader-local" do
    test "it lives in the reader hook" do
      l = layout()
      assert l =~ "runAsciicast()"
      assert l =~ "window.AsciinemaPlayer.create"
      assert l =~ "this.runAsciicast()", "mounted/updated must still call it"
    end

    test "it is NOT in the shared asset — Studio chat is not made to carry it" do
      a = asset()

      # The file HEADER names runAsciicast to say why it is absent, so the
      # tripwire is on the implementation, not the word.
      refute a =~ "runAsciicast()",
             "the shared asset must not define runAsciicast — it is reader-only"

      refute a =~ "AsciinemaPlayer",
             "Studio chat must not be made to carry the asciinema player"
    end
  end

  # The two object literals inside `themeVariables(dark)`, as sorted key lists.
  defp palettes(js) do
    [_, rest] = String.split(js, "function themeVariables(dark) {", parts: 2)
    [_, after_if] = String.split(rest, "if (dark) {", parts: 2)
    [dark_body, tail] = String.split(after_if, "};", parts: 2)
    [_, light_start] = String.split(tail, "return {", parts: 2)
    [light_body, _] = String.split(light_start, "};", parts: 2)

    {keys(dark_body), keys(light_body)}
  end

  defp keys(body) do
    ~r/(\w+):/
    |> Regex.scan(body)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
