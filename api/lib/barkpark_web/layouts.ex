defmodule BarkparkWeb.Layouts do
  use BarkparkWeb, :html
  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  # Every layout but `root` compiles straight from its file. `root` compiles
  # from `BarkparkWeb.RootAssets.root_source/0`: the same template with its
  # inline stylesheets and body scripts cut out into cached files
  # (task-cca3c6d48e57097e). The guard below fails the compile when a layout
  # file is added and not listed here.
  embed_templates "layouts/{app,bulldocs,quiz,sheets,studio,swatch}*"

  @layout_files Path.wildcard(Path.join(__DIR__, "layouts/*.html.heex"))
  for file <- @layout_files, do: @external_resource(file)

  for file <- @layout_files,
      name = file |> Path.basename(".html.heex") |> String.to_atom(),
      name != :root,
      not Module.defines?(__MODULE__, {name, 1}) do
    raise CompileError,
      description: "BarkparkWeb.Layouts: #{file} is not compiled; list it in embed_templates"
  end

  require BarkparkWeb.RootAssets.Compiler

  @doc false
  def root(var!(assigns)) do
    _ = var!(assigns)
    BarkparkWeb.RootAssets.Compiler.compile_root()
  end

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
