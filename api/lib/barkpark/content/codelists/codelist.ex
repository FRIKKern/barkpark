defmodule Barkpark.Content.Codelists.Codelist do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Barkpark.Content.Codelists.Value

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "codelists" do
    field :plugin_name, :string
    field :list_id, :string
    field :issue, :string
    field :name, :string
    field :description, :string

    has_many :values, Value, foreign_key: :codelist_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(codelist, attrs) do
    codelist
    |> cast(attrs, [:plugin_name, :list_id, :issue, :name, :description])
    |> validate_required([:plugin_name, :list_id, :issue])
    |> unique_constraint([:plugin_name, :list_id, :issue],
      name: :codelists_plugin_name_list_id_issue_index
    )
  end
end
