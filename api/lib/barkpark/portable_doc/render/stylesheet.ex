defmodule Barkpark.PortableDoc.Render.Stylesheet do
  @moduledoc """
  The ONE source for the canonical paper-surface stylesheet.

  `css/0` returns the raw CSS of `api/assets/paper-surface/paper-surface.css`
  (the `--paper-*` theme tokens, the `--bp-*` typography tokens, and the
  `.bp-paper-surface` element rules) as a compile-time-inlined string. Every
  sink embeds THIS output so View and Edit — Studio and the `/papers` reader
  and standalone exports — resolve the same selectors against the same tokens:
  parity by construction, not by hand-matched CSS mirrors that drift.

  Sinks:

    * `barkpark_web/layouts/root.html.heex` — Studio (`<%= raw(css()) %>` inside
      its `<style>`; surface CHROME + editor interplay stay local, layered after).
    * `barkpark_web/layouts/bulldocs.html.heex` — the `/papers` reader (the
      parchment `--paper-*` reader skin layers its overrides AFTER this source).
    * `plugins/sheets/html.ex` — the standalone `.html` sheet export `<head>`, so
      the export is self-contained (load-bearing once sheet chrome goes class-based).

  It lives under `Render` (core), NOT under the web layer, because export paths
  outside `BarkparkWeb` need it too. The stylesheet is read via
  `@external_resource`, so editing the `.css` file recompiles this module (and
  its callers) — the CSS never has to be duplicated into Elixir.
  """

  # Resolved at compile time relative to this source file:
  #   lib/barkpark/portable_doc/render/  ->  ../../../../assets/paper-surface/…
  @css_path Path.expand(
              "../../../../assets/paper-surface/paper-surface.css",
              __DIR__
            )
  @external_resource @css_path
  @css File.read!(@css_path)

  @doc """
  The raw canonical paper-surface CSS (no `<style>` wrapper). Embed it inside a
  `<style>` element (or, in HEEx, `<%= raw(...) %>` inside an open `<style>`).
  """
  @spec css() :: String.t()
  def css, do: @css
end
