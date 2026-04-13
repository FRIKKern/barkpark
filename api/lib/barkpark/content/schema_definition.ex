defmodule Barkpark.Content.SchemaDefinition do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "schema_definitions" do
    field :name, :string
    field :title, :string
    field :icon, :string
    field :visibility, :string, default: "public"
    field :fields, {:array, :map}, default: []
    field :dataset, :string, default: "production"

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schema_def, attrs) do
    schema_def
    |> cast(attrs, [:name, :title, :icon, :visibility, :fields, :dataset])
    |> validate_required([:name, :title])
    |> validate_inclusion(:visibility, ~w(public private))
    |> unique_constraint([:name, :dataset])
  end
end
