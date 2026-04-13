defmodule Barkpark.Content.Revision do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "revisions" do
    field :doc_id, :string
    field :type, :string
    field :dataset, :string, default: "production"
    field :title, :string
    field :status, :string
    field :content, :map
    field :action, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:doc_id, :type, :dataset, :title, :status, :content, :action])
    |> validate_required([:doc_id, :type, :action])
  end
end
