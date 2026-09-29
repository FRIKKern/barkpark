defmodule BarkparkWeb.PaperReaderStyle do
  @moduledoc """
  The web reader's page-chrome decision for a published paper — ONE predicate
  shared by every Phoenix surface that wraps a paper body in the `.bp-paper-shell`
  (`BulldocsLive` at `/papers/:slug`, the `/s/:token` static fallback in
  `ShareLinkController`, and the routing-retired `ScopedPaperController`).

  WEB ONLY. Email delivery (`BulldocsEmailController`) never asks this module:
  it passes `style: :email` itself and renders its own inline envelope.

  The rule (onb-residue-onb16-body-html-render-default, main's ruling
  2026-09-23): a paper reads as an ARTICLE unless it names a style that is not
  one. So:

    * `"article"` / `"article-wide"` → article chrome (unchanged).
    * NO style (key absent, `nil`, or `""`) → article chrome. This is the
      change: the block HTML for this population has been `:article` since
      #16037 (stored `body_html`) and task-c46967eb3dc49e77 (live per-block
      render), but the chrome still keyed on the explicit marker, so a
      style-less paper got `<main data-paper-palette="legacy" class="bp-paper-shell ">`
      — classed `:article` markup outside the `.bp-paper-surface` scope written
      to paint it.
    * any OTHER explicit string (e.g. `"email"`) → legacy chrome, byte-identical
      to before. `Labels.paper_style/2` never persists such a marker, so only a
      raw documents write or an older producer can leave one; it is an explicit
      choice and it is kept.
  """

  @article_styles ["article", "article-wide"]

  @doc "True when the paper's reader page wears the article chrome."
  @spec article?(term()) :: boolean()
  def article?(%{content: content}), do: content |> style() |> article_style?()
  def article?(_), do: false

  @doc "True when the paper opens the shell to the evidence band (`article-wide`)."
  @spec wide?(term()) :: boolean()
  def wide?(%{content: content}), do: style(content) == "article-wide"
  def wide?(_), do: false

  defp style(content) when is_map(content), do: Map.get(content, "style")
  defp style(_), do: nil

  defp article_style?(style) when style in [nil, ""], do: true
  defp article_style?(style), do: style in @article_styles
end
