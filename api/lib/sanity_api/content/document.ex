defmodule SanityApi.Content.Document do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "documents" do
    field :doc_id, :string
    field :type, :string
    field :dataset, :string, default: "production"
    field :title, :string
    field :status, :string, default: "draft"
    field :content, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [:doc_id, :type, :dataset, :title, :status, :content])
    |> validate_required([:doc_id, :type])
    |> validate_inclusion(:status, ~w(draft published archived active planning completed))
    |> unique_constraint([:doc_id, :type, :dataset])
  end
end
