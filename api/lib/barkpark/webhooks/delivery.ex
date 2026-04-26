defmodule Barkpark.Webhooks.Delivery do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending ok failed_giveup)

  schema "webhook_deliveries" do
    field :endpoint_id, Ecto.UUID
    field :event_id, :integer
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_status_code, :integer
    field :last_error_text, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :endpoint_id,
      :event_id,
      :status,
      :attempts,
      :last_status_code,
      :last_error_text
    ])
    |> validate_required([:endpoint_id, :event_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:endpoint_id, :event_id])
  end
end
