defmodule Barkpark.Content.CanonicalShapes do
  @moduledoc """
  Which document types Studio writes in the canonical value shapes (owner
  rulings #42 `{_ref}`, #43 `{current}`).

  THE WRITES ARE OFF BY DEFAULT. One instance flag,
  `config :barkpark, :canonical_shape_writes` (env
  `BARKPARK_CANONICAL_SHAPE_WRITES=true`), turns them on. Off, a Studio save
  keeps every field's stored shape and the convert tasks refuse `apply: true`.
  Sites already hold values in the old shapes (Gyldendal's frontpage stores
  references as bare ids), so the owner turns the flag on per box once that
  box's consumers read both shapes. Readers accept both shapes either way.

  Plugin-owned types are EXEMPT even with the flag on: they keep the shape they were stored in.
  Their documents are read by consumers outside Barkpark (the FRT Godot game
  reads `slug` as a machine id string and references as bare ids), and moving
  those consumers is an owner decision that has not been made. Every reader
  still accepts both shapes for every type.

  The exempt set is `exempt_types/0`: every type a registered plugin claims
  through `owned_schema_types/0`. Content never names the plugin Registry
  (kernel→feature, `tooling/concept-map/ci-boundary.mjs`), so the Registry
  PUBLISHES the set here (`publish_exempt_types/1`, the same pattern as
  `Barkpark.Content.PreWriteFences`). The convert tasks
  (`ShapeMigrations.FieldScan`) skip the same set.
  """

  @keep "__keep_stored_shape"
  @key {__MODULE__, :exempt_types}

  @doc """
  Replace the published set of plugin-owned types. Called by
  `Barkpark.Plugins.Registry` only; writes only when the value changes.
  """
  @spec publish_exempt_types([String.t()]) :: :ok
  def publish_exempt_types(types) when is_list(types) do
    value = types |> Enum.filter(&is_binary/1) |> MapSet.new()

    if :persistent_term.get(@key, :unset) != value do
      :persistent_term.put(@key, value)
    end

    :ok
  end

  @doc "The field key that tells `Content.Forms` to keep a value's stored shape."
  def keep_key, do: @keep

  @doc "Every plugin-owned type name: Studio keeps their stored value shapes."
  @spec exempt_types() :: MapSet.t(String.t())
  def exempt_types, do: :persistent_term.get(@key, MapSet.new())

  @doc "True when `type` is plugin-owned (exempt from canonical writes and the convert tasks)."
  @spec exempt?(String.t() | nil) :: boolean()
  def exempt?(type) when is_binary(type), do: MapSet.member?(exempt_types(), type)
  def exempt?(_type), do: false

  @doc "True when the instance flag `:canonical_shape_writes` is on (default off)."
  @spec writes_enabled?() :: boolean()
  def writes_enabled?, do: Application.get_env(:barkpark, :canonical_shape_writes, false) == true

  @doc """
  True when Studio writes the canonical shapes for `type`: the flag is on and
  the type is not plugin-owned.
  """
  @spec canonical_write?(String.t() | nil) :: boolean()
  def canonical_write?(type) when is_binary(type),
    do: writes_enabled?() and not exempt?(type)

  def canonical_write?(_type), do: writes_enabled?()

  @doc """
  `schema` with every field (recursively: composite subfields and `arrayOf`
  member descriptors) marked to keep its stored shape unless
  `canonical_write?/1` holds for `type` (or the schema's own name).
  """
  @spec for_type(map() | nil, String.t() | nil) :: map() | nil
  def for_type(nil, _type), do: nil

  def for_type(schema, type) when is_map(schema) do
    if canonical_write?(type || schema_name(schema)), do: schema, else: mark_schema(schema)
  end

  def for_type(schema, _type), do: schema

  defp schema_name(schema), do: Map.get(schema, :name) || Map.get(schema, "name")

  defp mark_schema(schema) do
    schema
    |> update_existing(:fields, &mark_fields/1)
    |> update_existing("fields", &mark_fields/1)
  end

  defp update_existing(map, key, fun) do
    if Map.has_key?(map, key), do: Map.update!(map, key, fun), else: map
  end

  defp mark_fields(fields) when is_list(fields), do: Enum.map(fields, &mark_field/1)
  defp mark_fields(other), do: other

  defp mark_field(%{} = f) do
    f
    |> Map.put(@keep, true)
    |> update_existing("of", &mark_of/1)
    |> update_existing("fields", &mark_fields/1)
  end

  defp mark_field(other), do: other

  defp mark_of(%{} = of), do: mark_field(of)
  defp mark_of(ofs) when is_list(ofs), do: Enum.map(ofs, &mark_field/1)
  defp mark_of(other), do: other
end
