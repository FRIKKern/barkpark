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

  @doc """
  The name a document's editor header and browser tab give it: the stored
  title, else the schema's derived preview title (a titleless author is its
  name), else a singleton's schema title, else "Untitled". The desk names a
  document pane by this rule from its first frame (a row's
  `data-desk-title`, a read-only pane's title), so the header never changes
  its words when the editor arrives (task-32a5956065c81200). A list row
  keeps its own name (`PaneBuilder.display_title/2`), which tells unnamed
  documents apart.
  """
  @spec header(map(), map() | nil) :: String.t()
  def header(doc, schema) do
    shown(Map.get(doc, :title)) ||
      Barkpark.Content.TitleDerivation.preview_title(doc, schema) ||
      (schema && Map.get(schema, :singleton) == true && Map.get(schema, :title)) ||
      Gettext.gettext(BarkparkWeb.Gettext, "Untitled")
  end

  @doc """
  A desk list row (`PaneBuilder`'s doc item) with its document's `header/2`
  name as `:header_title`. `Desk.Rows` carries it to the row's
  `data-desk-title`, which names the frame `bp-desk.js` draws at the click.
  """
  @spec with_header(map(), map() | nil, map()) :: map()
  def with_header(doc, schema, item), do: Map.put(item, :header_title, header(doc, schema))
end
