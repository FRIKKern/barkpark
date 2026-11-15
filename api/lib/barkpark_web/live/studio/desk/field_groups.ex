defmodule BarkparkWeb.Studio.Desk.FieldGroups do
  @moduledoc """
  Which field-group tabs the desk's editor draws.

  A group gets a tab only while one of its fields shows, as the TanStack
  Studio and Sanity do (`visibleGroups`): a group whose fields are all hidden
  by `visibleWhen` has no tab until one of them shows.

  Only the tab bar and the choice of fields to draw change here. A field that
  is not drawn is not posted, and the save keeps its stored value.
  """

  alias BarkparkWeb.Components.Fields.Visibility
  alias BarkparkWeb.StudioComponents

  @doc "The schema's groups that have a shown field, in schema order."
  @spec shown(map() | nil, map() | nil) :: [map()]
  def shown(schema, form) do
    fields = fields(schema)
    form = form || %{}

    Enum.filter(StudioComponents.schema_groups(schema), fn group ->
      Enum.any?(fields, &(in_group?(&1, group["name"]) and Visibility.visible?(&1, form)))
    end)
  end

  @doc """
  The group the editor shows: `nav_group` while its tab is there, else `nil`
  (All fields), so a tab that went away never leaves an empty form behind.
  """
  @spec current(map() | nil, String.t() | nil, map() | nil) :: String.t() | nil
  def current(_schema, nil, _form), do: nil

  def current(schema, nav_group, form) do
    if Enum.any?(shown(schema, form), &(&1["name"] == nav_group)), do: nav_group
  end

  defp fields(%{fields: fields}) when is_list(fields), do: fields
  defp fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp fields(_schema), do: []

  defp in_group?(%{"group" => group}, name) when is_binary(group), do: group == name
  defp in_group?(%{"group" => groups}, name) when is_list(groups), do: name in groups
  defp in_group?(_field, _name), do: false
end
