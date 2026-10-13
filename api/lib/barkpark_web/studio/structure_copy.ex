defmodule BarkparkWeb.Studio.StructureCopy do
  @moduledoc """
  The structure pane's words in the viewer's Studio language
  (task-acb3765dea94de2e).

  `Barkpark.Structure` names its built-in groups ("Content", "Plugins",
  "…Rest", …) and carries plugin-owned type titles and desk labels ("Sheets",
  "Tasks", …) in English. The API and the TUI read the same tree, so it stays
  English there. Studio translates the tree it renders with `localize/1`.

  Only words Barkpark ships are translated: the built-in groups by node id,
  and the titles of plugin-owned types and plugin desk entries. A title the
  workspace authored is data and is never looked up. A plugin title with no
  translation reads as written.

  `markers/0` lists the plugin titles marked for extraction. The test that
  holds it pins every default-enabled plugin's owned type titles and desk
  labels, so a new one without a marker reds.
  """
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Structure

  @markers [
    gettext_noop("Papers"),
    gettext_noop("Form responses"),
    gettext_noop("Session"),
    gettext_noop("Paper masters"),
    gettext_noop("Facts"),
    gettext_noop("Media Asset"),
    gettext_noop("Media Collection"),
    gettext_noop("Quiz"),
    gettext_noop("Quizzes"),
    gettext_noop("Commands"),
    gettext_noop("Sheets"),
    gettext_noop("Task"),
    gettext_noop("Listener"),
    gettext_noop("Tasks"),
    gettext_noop("Projects"),
    gettext_noop("Fleet"),
    gettext_noop("Ticket"),
    gettext_noop("Tickets"),
    gettext_noop("Form submissions"),
    gettext_noop("Form endpoints")
  ]

  @doc "The plugin titles marked for translation, in English."
  @spec markers() :: [String.t()]
  def markers, do: @markers

  @doc """
  The tree with Barkpark's own words in the viewer's language. Ids, types,
  filters and every other field are untouched.
  """
  @spec localize(struct() | map()) :: struct() | map()
  def localize(tree) do
    owned = Structure.owned_schema_types_map() |> Map.values() |> List.flatten() |> MapSet.new()
    walk(tree, owned)
  end

  defp walk(%{} = node, owned) do
    node
    |> Map.put(:title, title(node, owned))
    |> Map.update(:items, nil, fn
      items when is_list(items) -> Enum.map(items, &walk(&1, owned))
      other -> other
    end)
  end

  defp walk(other, _owned), do: other

  defp title(%{id: "content-types"}, _owned), do: gettext("Content")
  defp title(%{id: "plugins"}, _owned), do: gettext("Plugins")
  defp title(%{id: "rest"}, _owned), do: gettext("…Rest")
  defp title(%{id: "settings"}, _owned), do: gettext("Settings")
  defp title(%{id: "media-desk"}, _owned), do: gettext("Media")
  defp title(%{id: "media-library"}, _owned), do: gettext("Media Library")

  # "All <type>" heads an owned or authored type's list; only the frame is ours.
  defp title(%{type: :document_type_list, title: "All " <> type_title} = node, owned) do
    gettext("All %{type}", type: type_title(type_title, node, owned))
  end

  defp title(%{type: kind, title: title}, _owned)
       when kind in [:plugin_document_list, :plugin_link] and is_binary(title),
       do: translate(title)

  defp title(%{title: title} = node, owned) when is_binary(title),
    do: type_title(title, node, owned)

  defp title(node, _owned), do: Map.get(node, :title)

  defp type_title(title, %{type_name: type_name}, owned) when is_binary(type_name) do
    if MapSet.member?(owned, type_name), do: translate(title), else: title
  end

  defp type_title(title, _node, _owned), do: title

  defp translate(text), do: Gettext.gettext(BarkparkWeb.Gettext, text)
end
