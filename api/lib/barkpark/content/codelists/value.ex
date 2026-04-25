defmodule Barkpark.Content.Codelists.Value do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Barkpark.Content.Codelists.{Codelist, Translation}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "codelist_values" do
    field :code, :string
    field :position, :integer
    field :metadata, :map

    belongs_to :codelist, Codelist
    belongs_to :parent, __MODULE__, foreign_key: :parent_id

    has_many :translations, Translation, foreign_key: :codelist_value_id
    has_many :children, __MODULE__, foreign_key: :parent_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [:codelist_id, :parent_id, :code, :position, :metadata])
    |> validate_required([:codelist_id, :code])
    |> unique_constraint([:codelist_id, :code],
      name: :codelist_values_codelist_id_code_index
    )
  end
end
