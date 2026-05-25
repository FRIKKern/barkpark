defmodule Barkpark.Content.MutationEvent do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "mutation_events" do
    field :dataset, :string
    field :type, :string
    field :doc_id, :string
    field :mutation, :string
    field :rev, :string
    field :previous_rev, :string
    field :document, :map

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    field :inserted_at, :utc_datetime_usec
  end
end
