defmodule Barkpark.Webhooks.Webhook do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "webhooks" do
    field :name, :string
    field :url, :string
    field :dataset, :string, default: "production"
    field :events, {:array, :string}, default: []
    field :types, {:array, :string}, default: []
    field :secret, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @valid_events ~w(create update publish unpublish delete discardDraft patch)

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:name, :url, :dataset, :events, :types, :secret, :active])
    |> validate_required([:name, :url])
    |> validate_format(:url, ~r/^https?:\/\//)
    |> validate_subset(:events, @valid_events)
  end
end
