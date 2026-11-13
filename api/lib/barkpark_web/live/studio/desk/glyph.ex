defmodule BarkparkWeb.Studio.Desk.Glyph do
  @moduledoc """
  A Sanity icon from `Barkpark.DeskIcons` (its 25-unit box), drawn at 21 px
  in the current colour, as the TanStack Studio draws its pane header
  buttons and list search (`app/src/components/icons.tsx`): Add, Ellipsis,
  Search. `BarkparkWeb.Icons.desk_icon/1` prefers the Studio's lucide glyph
  of the same name; the desk's chrome wants TanStack's.
  """

  use Phoenix.Component

  attr :name, :string, required: true

  def glyph(assigns) do
    assigns = assign(assigns, :body, Barkpark.DeskIcons.body(assigns.name) || "")

    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width="21"
      height="21"
      viewBox="0 0 25 25"
      fill="none"
      aria-hidden="true"
      data-desk-glyph={@name}
    >{Phoenix.HTML.raw(@body)}</svg>
    """
  end
end
