defmodule BarkparkWeb.Studio.Nav do
  @moduledoc """
  Single source of truth for Studio top-level navigation tabs.

  Each tab is `{id, label, path}` where `id` matches the `:nav_section`
  assign set by the corresponding LiveView in its `mount/3`. The layout
  (`app.html.heex`) loops this list and marks the matching tab active.
  """

  @type tab :: %{id: atom(), label: String.t(), path: String.t()}

  @spec tabs() :: [tab()]
  def tabs do
    [
      %{id: :structure, label: "Structure", path: "/studio"},
      %{id: :media, label: "Media", path: "/studio/media"},
      %{id: :api_tester, label: "API", path: "/studio/api-tester"}
    ]
  end

  @doc "Fallback nav section when a LiveView hasn't set one."
  @spec default() :: atom()
  def default, do: :structure
end
