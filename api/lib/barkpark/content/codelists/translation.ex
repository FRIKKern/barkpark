defmodule Barkpark.Content.Codelists.Translation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Barkpark.Content.Codelists.Value

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "codelist_value_translations" do
    field :language, :string
    field :label, :string
    field :description, :string

    belongs_to :value, Value, foreign_key: :codelist_value_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(translation, attrs) do
    translation
    |> cast(attrs, [:codelist_value_id, :language, :label, :description])
    |> validate_required([:codelist_value_id, :language, :label])
    |> unique_constraint([:codelist_value_id, :language],
      name: :codelist_value_translations_codelist_value_id_language_index
    )
  end
end
