defmodule BarkparkCloud.Notifications.Delivery do
  @moduledoc """
  A durable record of one notification send — one row per recipient per event.
  Modeled on `Barkpark.Webhooks.Delivery` (api/): `status` / `attempts` /
  `last_error`. This is the observability surface Coolify lacks (it leans on
  Laravel's `failed_jobs`); the webhook precedent says a CMS wants a first-class,
  team-scoped delivery log.

  v1 sends synchronously and stamps `status` ("sent" | "failed") immediately. The
  `attempts` / `last_error` shape is the future retry seam: when cloud/ gains
  Oban a worker re-drives `status: "failed"` rows with backoff.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending sent failed)
  @kinds ~w(alert transactional)
  @channels ~w(email)

  schema "notification_deliveries" do
    field :recipient, :string
    field :event, :string
    field :channel, :string, default: "email"
    field :kind, :string, default: "alert"
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string

    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses
  def kinds, do: @kinds

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :team_id,
      :recipient,
      :event,
      :channel,
      :kind,
      :status,
      :attempts,
      :last_error
    ])
    |> validate_required([:team_id, :recipient, :event])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:channel, @channels)
    |> assoc_constraint(:team)
  end
end
