defmodule BarkparkWeb.Studio.StudioLive.NavGroup do
  @moduledoc """
  Which group tab the editor shows when it (re)builds, moved out of
  `StudioLive.Shared`.

  The Studio opens a schema on its first group and keeps the chosen group
  while the schema stays. The desk opens it as the TanStack Studio and Sanity
  do: on the group marked `default: true`, else on All fields (`nil`), and
  keeps the choice, All fields included, while the schema stays.
  """

  alias BarkparkWeb.StudioComponents

  @doc "The group to show. `opts[:desk?]` picks the desk's rule."
  def resolve(current, old, new_schema, opts \\ [])
  def resolve(_current, _old, nil, _opts), do: nil

  def resolve(current, old, new_schema, opts) do
    same? = old != nil and schema_id(new_schema) == schema_id(old)

    cond do
      opts[:desk?] == true and same? -> current
      opts[:desk?] == true -> default_group_name(new_schema)
      same? and current != nil -> current
      true -> first_group_name(new_schema)
    end
  end

  defp schema_id(nil), do: nil
  defp schema_id(schema), do: Map.get(schema, :name) || Map.get(schema, "name")

  defp first_group_name(schema) do
    case StudioComponents.schema_groups(schema) do
      [%{"name" => name} | _] -> name
      _ -> nil
    end
  end

  defp default_group_name(schema) do
    Enum.find_value(StudioComponents.schema_groups(schema), fn
      %{"default" => true, "name" => name} -> name
      _ -> nil
    end)
  end
end
