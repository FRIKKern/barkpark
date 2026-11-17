defmodule Barkpark.Tenancy.AccessRequest do
  @moduledoc """
  A signed-in user's request for a seat in a workspace (task-1b99ba8512bb758e).

  Like `Barkpark.Tenancy.Invitation`, deliberately NOT a
  `workspace_memberships` row: every authorization reader treats a membership
  row as a seat. Approving creates the seat through
  `Barkpark.Tenancy.Members.add_user_member/4`; this row only records the ask
  and its outcome.

  `workspace_slug` is the slug the user sent. `workspace_id` is nil when no
  workspace has it: the row is kept anyway so the asker's answer and list are
  the same whether the workspace exists or not, and no admin can see it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending approved denied)
  @note_max 500
  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/

  schema "workspace_access_requests" do
    field :user_id, :binary_id
    field :workspace_slug, :string
    field :note, :string
    field :status, :string, default: "pending"
    field :role, :string
    field :decided_by, :string
    field :decided_at, :utc_datetime_usec

    belongs_to :workspace, Barkpark.Tenancy.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The longest note a request may carry, in characters."
  def note_max, do: @note_max

  @doc "A new pending request. The slug is checked for shape only, never for existence."
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:user_id, :workspace_slug, :workspace_id, :note])
    |> validate_required([:user_id, :workspace_slug])
    |> validate_length(:workspace_slug, min: 1, max: 63)
    |> validate_format(:workspace_slug, @slug_format)
    |> validate_length(:note, max: @note_max)
    |> unique_constraint([:user_id, :workspace_slug],
      name: :workspace_access_requests_one_pending_idx
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:workspace_id)
  end

  @doc "Record an admin's decision on a pending request."
  def decide_changeset(%__MODULE__{} = request, attrs) do
    request
    |> cast(attrs, [:status, :role, :decided_by, :decided_at])
    |> validate_required([:status, :decided_at])
    |> validate_inclusion(:status, @statuses)
  end
end
