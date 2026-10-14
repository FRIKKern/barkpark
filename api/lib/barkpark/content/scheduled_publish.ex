defmodule Barkpark.Content.ScheduledPublish do
  @moduledoc """
  One scheduled publish of a document's draft (task-8e88b5539acafdae). The
  rules live in `Barkpark.Content.ScheduledPublishes`; this is the row.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(scheduled published cancelled refused failed missed)
  @principal_types ~w(user api_token)

  schema "scheduled_publishes" do
    field :workspace_id, :binary_id
    field :project_id, :binary_id
    field :dataset, :string
    field :type, :string
    field :doc_id, :string
    field :publish_at, :utc_datetime_usec
    field :draft_rev, :string
    field :principal_type, :string
    field :principal_id, :binary_id
    field :acting_user_id, :binary_id
    field :status, :string, default: "scheduled"
    field :reason, :string
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :workspace_id,
      :project_id,
      :dataset,
      :type,
      :doc_id,
      :publish_at,
      :draft_rev,
      :principal_type,
      :principal_id,
      :acting_user_id
    ])
    |> validate_required([:dataset, :type, :doc_id, :publish_at, :principal_type, :principal_id])
    |> validate_inclusion(:principal_type, @principal_types)
    |> unique_constraint([:workspace_id, :dataset, :type, :doc_id],
      name: :scheduled_publishes_one_pending_per_doc
    )
  end

  def finish_changeset(%__MODULE__{} = row, status, reason) when status in @statuses do
    change(row, status: status, reason: reason, completed_at: DateTime.utc_now())
  end
end
