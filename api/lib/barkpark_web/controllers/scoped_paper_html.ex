defmodule BarkparkWeb.ScopedPaperHTML do
  @moduledoc """
  HTML view for `BarkparkWeb.ScopedPaperController`.

  One template, `show.html.heex`, wraps the paper's cached `body_html` in the
  `.bp-paper-shell` reading column. The surrounding `<!DOCTYPE>` / `<head>` /
  styles come from the `:bulldocs` root layout the controller selects — this
  template only emits the `<main>` body, mirroring `BulldocsLive`'s static
  markup so the scoped reader and the public reader share one chrome.
  """

  use BarkparkWeb, :html

  embed_templates "scoped_paper_html/*"
end
