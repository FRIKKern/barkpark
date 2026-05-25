defmodule Barkpark.Search.Synonym do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "search_synonyms" do
    field :surface, :string
    field :scope, :string
    field :from_query, :string
    field :to_query, :string
    field :kind, :string, default: "one_way"
    field :source, :string, default: "manual"
    field :enabled, :boolean, default: true

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end
end
