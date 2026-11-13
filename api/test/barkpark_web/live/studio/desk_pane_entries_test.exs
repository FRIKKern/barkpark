defmodule BarkparkWeb.Studio.DeskPaneEntriesTest do
  @moduledoc """
  Which of a desk node's dividers the pane draws (rig run n, B13). The
  TanStack Studio draws only declared dividers, so the desk drops the
  positional ones `Barkpark.Structure` makes up between its groups
  (`div-<n>`), except the one that closes a titled section: Sanity's
  Settings is its title, its singletons, then a plain line (row to row 9 px).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.Desk.PaneComponent

  defp row(id), do: %Node{id: id, type: :document_type_list, title: id, type_name: id}
  defp divider(id, title \\ nil), do: %Node{id: id, type: :divider, title: title}

  defp shape(entries) do
    Enum.map(entries, fn
      :divider -> :line
      {:divider, title} -> {:titled, title}
      %{title: title} -> title
    end)
  end

  test "the plain line that closes a titled section stays; the ones between plain groups go" do
    root = %Node{
      id: "root",
      type: :list,
      title: "Structure",
      items: [
        row("Papers"),
        divider("div-1"),
        row("Sheets"),
        divider("div-2", "Settings"),
        row("Site settings"),
        divider("div-3"),
        row("Tasks")
      ]
    }

    assert shape(PaneComponent.node_entries(root)) ==
             ["Papers", "Sheets", {:titled, "Settings"}, "Site settings", :line, "Tasks"]
  end

  test "a declared plain divider is always drawn" do
    root = %Node{
      id: "root",
      type: :list,
      title: "Structure",
      items: [row("Posts"), divider("my-divider"), row("Pages")]
    }

    assert shape(PaneComponent.node_entries(root)) == ["Posts", :line, "Pages"]
  end
end
