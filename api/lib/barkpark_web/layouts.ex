defmodule BarkparkWeb.Layouts do
  use BarkparkWeb, :html
  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  embed_templates "layouts/*"

  @doc """
  The value for the `<html data-bp-theme=…>` attribute (ts-w4e), given the
  layout `assigns`.

  Theme identity is one of the two orthogonal theme switches (light/dark mode is
  the other, owned client-side by the `data-theme` pre-paint script — untouched).
  The server resolves the workspace theme and assigns it as `:bp_theme`; this
  helper maps it to the attribute value:

    * the DEFAULT theme (`evergreen`, the palette already baked into `:root`)
      → `nil`, so HEEx OMITS the attribute entirely. A default-theme page is
      therefore byte-identical to before this feature existed.
    * any other known theme id → the id string, so the stylesheet's
      `[data-bp-theme="…"]` skin (shipped by wave 5) wins.

  A surface that never assigns `:bp_theme` (a dead controller view) reads `nil`
  and likewise emits no attribute.
  """
  @spec bp_theme_attr(map()) :: String.t() | nil
  def bp_theme_attr(assigns) do
    default = Barkpark.Tenancy.default_theme()

    case assigns[:bp_theme] do
      theme when is_binary(theme) and theme != default -> theme
      _ -> nil
    end
  end

  # sobelow_skip ["XSS.Raw"]
  # SAFE: emits our OWN static PortableDoc stylesheet (server-authored CSS, no
  # user input) verbatim into the layout <style>. Hoisted out of root.html.heex
  # so the durable inline skip attaches here via combine_skips — an HEEx inline
  # comment is inert (XSS.get_template_vulns bypasses combine_skips), so the
  # template kept reddening the Sobelow gate on pure line-shift drift.
  @doc """
  The PortableDoc reader/editor stylesheet, marked safe for inline `<style>`
  emission from the root layout. This is the ONE raw() the layout needs; keeping
  it here (not in the template) is what lets Sobelow's inline skip stick.
  """
  @spec paper_stylesheet() :: Phoenix.HTML.safe()
  def paper_stylesheet do
    Phoenix.HTML.raw(Barkpark.PortableDoc.Render.Stylesheet.css())
  end
end
