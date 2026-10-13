defmodule BarkparkWeb.Studio.DocTitle do
  @moduledoc """
  The stored title a Studio surface may show as-is.

  The old new-document handler seeded the literal English `"Untitled"` into
  the title column (task-79e28148d9925097 stopped it; tasks still seed it by
  design). That word is a display fallback, not a title: shown raw it reads
  English in every Studio language. `shown/1` returns `nil` for a blank or a
  literal "Untitled" title, so each surface falls through to its own derived
  or `gettext("Untitled")` fallback (task-75c3d1234335d10f). The list pane
  applies the same rule in `PaneBuilder.row_title/2`.
  """

  @spec shown(term()) :: String.t() | nil
  def shown(title) when is_binary(title) do
    case String.trim(title) do
      "" -> nil
      "Untitled" -> nil
      _ -> title
    end
  end

  def shown(_), do: nil
end
