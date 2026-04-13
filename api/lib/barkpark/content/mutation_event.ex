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
    field :inserted_at, :utc_datetime_usec
  end
end
