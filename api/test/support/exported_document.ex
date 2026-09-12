defmodule Barkpark.Test.ExportedDocument do
  @moduledoc """
  Region helpers for ABSENCE assertions over a standalone export document.

  `Barkpark.Plugins.Sheets.Html.export/2` inlines the whole canonical
  paper-surface stylesheet into `<head>` as a `<style>` element holding `Stylesheet.css/0`
  (`plugins/sheets/html.ex`), and `PortableDoc.Render`'s `:article` document
  wrapper does the same. A `refute document =~ "<h2"` over the WHOLE string is
  therefore an assertion about tens of kilobytes of CSS as much as about the
  export's own markup: any tag-open literal that ever lands in the stylesheet —
  a `content:` string, an attribute selector, a selector fragment — reds a test
  that governs none of it, and the natural remediation for that red is to edit
  the CSS, which is the wrong file entirely.

  Both regions below are DERIVED FROM THE DOCUMENT, structurally. Neither
  enumerates permitted literals: an allowlist grows, and the eighth entry gets
  waved through by the seven above it.

  Pick the region by what the refute is actually about:

    * `body/1` — the export's rendered markup. The default.
    * `outside_stylesheet/1` — the whole document minus the stylesheet's TEXT,
      for the few refutes that must still see `<head>` (an external `<link>` or
      `<script src>` lives there, and so does `<title>`).
  """

  @doc """
  The document's body region: everything after `</head>`.

  Derived from the document — the markup that follows the inlined stylesheet —
  not a hand-written string. Raises when the document has no `</head>`, so a
  malformed (or restructured) export can never silently degrade this into an
  empty region that no refute could ever fail against.
  """
  @spec body(String.t()) :: String.t()
  def body(document) when is_binary(document) do
    case String.split(document, "</head>", parts: 2) do
      [_head, body] ->
        body

      _ ->
        raise ArgumentError,
              "expected a standalone export document with a </head>; got #{inspect(String.slice(document, 0, 120))}"
    end
  end

  @doc """
  The whole document with every `<style>` element's CONTENT removed.

  The `<style>` tags themselves are kept, so the document's structure is
  unchanged and `<head>` stays in scope — only the CSS bytes leave. Use this,
  not `body/1`, when the refute is genuinely about the whole document (the
  self-containment contract: no `<link>`, no `<script>`, anywhere).

  Raises when the document carries no `<style>` element at all: this helper
  exists to exclude the inlined stylesheet, and an export that stopped inlining
  it must be looked at rather than silently passed through.
  """
  @spec outside_stylesheet(String.t()) :: String.t()
  def outside_stylesheet(document) when is_binary(document) do
    unless String.contains?(document, "<style") do
      raise ArgumentError,
            "expected a standalone export document with an inlined <style>; got none"
    end

    Regex.replace(~r{(<style[^>]*>).*?(</style>)}s, document, "\\1\\2")
  end
end
