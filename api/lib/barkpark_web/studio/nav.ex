defmodule BarkparkWeb.Studio.Nav do
  @moduledoc """
  Single source of truth for Studio top-level navigation tabs.

  Tabs are dataset-aware: `tabs/1` takes the current dataset and returns
  a list of `%{id, label, path}` maps with `/d/:dataset/studio`-shaped
  paths (callers prepend the `/w/:ws/p/:proj` scope prefix).
  """

  @type tab :: %{id: atom(), label: String.t(), path: String.t()}

  @spec tabs(String.t()) :: [tab()]
  def tabs(dataset) when is_binary(dataset) do
    ds = URI.encode(dataset)

    [
      %{id: :structure, label: "Structure", path: "/d/#{ds}/studio"},
      %{id: :media, label: "Media", path: "/d/#{ds}/studio/media"},
      %{id: :api_tester, label: "API", path: "/d/#{ds}/studio/api-tester"}
    ]
  end

  @doc "Fallback nav section when a LiveView hasn't set one."
  @spec default() :: atom()
  def default, do: :structure
end
