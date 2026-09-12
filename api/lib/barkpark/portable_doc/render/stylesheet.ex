defmodule Barkpark.PortableDoc.Render.Stylesheet.Comments do
  @moduledoc false

  # Strips `/* … */` blocks from a stylesheet WITHOUT touching a `/*` that sits
  # inside a quoted CSS string (`content: "a/*b"`), which is not a comment. The
  # scan alternation matches a double-quoted string, a single-quoted string, or
  # a comment — strings are handed back verbatim, comments are dropped, so a
  # quoted `/*` can never open a comment and a quoted `*/` can never close one.
  @scan ~r{"[^"]*"|'[^']*'|/\*[\s\S]*?\*/}

  @doc false
  @spec strip(String.t()) :: String.t()
  def strip(css) do
    decommented =
      Regex.replace(@scan, css, fn match ->
        if String.starts_with?(match, "/*"), do: "", else: match
      end)

    # A comment that occupied whole lines leaves those lines behind; collapse the
    # blank runs (and the trailing spaces a mid-line comment leaves) so the served
    # bytes stay readable rather than becoming a field of empty lines.
    decommented
    |> String.replace(~r/[ \t]+$/m, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end
end

defmodule Barkpark.PortableDoc.Render.Stylesheet do
  @moduledoc """
  The ONE source for the canonical paper-surface stylesheet.

  `css/0` returns the CSS of `api/assets/paper-surface/paper-surface.css`
  (the `--paper-*` theme tokens, the `--bp-*` typography tokens, and the
  `.bp-paper-surface` element rules) as a compile-time-inlined string. Every
  sink embeds THIS output so View and Edit — Studio and the `/papers` reader
  and standalone exports — resolve the same selectors against the same tokens:
  parity by construction, not by hand-matched CSS mirrors that drift.

  ## Comments are stripped from the served bytes

  The source file is heavily commented — ~72KB of design rationale, roughly
  46% of its bytes — and every sink below INLINES this string into a `<style>`
  in `<head>`, so before `pbw-backlog-unsupported-grep-trap` that commentary
  shipped to every reader of every `/papers` page. Two consequences, both
  fixed by stripping comments here rather than by censoring the source:

    * **Payload.** Tens of kilobytes of developer prose on every Paper page.
    * **A permanent false positive.** One comment explains the
      `.bp-unknown-block` degrade and quotes the placeholder copy the walker
      emits for a forward-compat Pd-node kind. A smoke gate grepping the
      served page for that prose therefore matched on EVERY paper, including
      papers with no unknown block at all, and could never reach zero. The
      rendered signal is the element, not the prose: unknown blocks emit
      `<div class="bp-unknown-block">` (`render/walk.ex`), and that class is
      what a gate must count.

  Stripping happens at compile time, so the source file keeps its full
  rationale for developers and `css/0` is what readers receive. Whitespace
  inside rules is untouched — only comments, trailing spaces, and runs of
  blank lines go — so every byte-exact rule assertion still holds.

  Sinks:

    * `barkpark_web/layouts/root.html.heex` — Studio (via
      `Layouts.paper_stylesheet/0`; surface CHROME + editor interplay stay
      local, layered after).
    * `barkpark_web/layouts/bulldocs.html.heex` — the `/papers` reader (the
      parchment `--paper-*` reader skin layers its overrides AFTER this source).
    * `barkpark_web/layouts/quiz.html.heex` — the quiz surface.
    * `plugins/sheets/html.ex` — the standalone `.html` sheet export `<head>`, so
      the export is self-contained (load-bearing once sheet chrome goes class-based).
    * `portable_doc/render.ex` — the `:article` standalone `.html` export.

  It lives under `Render` (core), NOT under the web layer, because export paths
  outside `BarkparkWeb` need it too. The stylesheet is read via
  `@external_resource`, so editing the `.css` file recompiles this module (and
  its callers) — the CSS never has to be duplicated into Elixir.
  """

  alias Barkpark.PortableDoc.Render.Stylesheet.Comments

  # Resolved at compile time relative to this source file:
  #   lib/barkpark/portable_doc/render/  ->  ../../../../assets/paper-surface/…
  @css_path Path.expand(
              "../../../../assets/paper-surface/paper-surface.css",
              __DIR__
            )
  @external_resource @css_path
  @css Comments.strip(File.read!(@css_path))

  @doc """
  The canonical paper-surface CSS, comment-stripped (no `<style>` wrapper).

  Embed it inside a `<style>` element (or, in HEEx, `<%= raw(...) %>` inside an
  open `<style>`). These are the bytes a reader receives; the developer
  rationale stays in `api/assets/paper-surface/paper-surface.css`.
  """
  @spec css() :: String.t()
  def css, do: @css
end
