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

  `requested_role` is the role the asker named, if any (task-018e79d8734a1b08).
  `from_role` and `seat_change` are set only when a MEMBER asks for a higher
  role: the role they held and their seat's change stamp at ask time (both or
  neither, a CHECK constraint). A non-nil `from_role` marks the request as a
  role change. Fresh or stale: `Tenancy.AccessRequestStaleness`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending approved denied)
  @note_max 500
  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/
  # The `Tenancy.Role` name shape.
  @role_format ~r/^[a-z0-9][a-z0-9-]*$/

  schema "workspace_access_requests" do
    field :user_id, :binary_id
    field :workspace_slug, :string
    field :note, :string
    field :status, :string, default: "pending"
    field :role, :string
    field :requested_role, :string
    field :from_role, :string
    field :seat_change, Ecto.UUID
    field :decided_by, :string
    field :decided_at, :utc_datetime_usec

    belongs_to :workspace, Barkpark.Tenancy.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The longest note a request may carry, in characters."
  def note_max, do: @note_max

  @doc """
  A new pending request. The slug and the requested role are checked for shape
  only, never for existence: a seatless asker must learn nothing about the
  workspace, its custom roles included.
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:user_id, :workspace_slug, :workspace_id, :note, :requested_role, :from_role])
    |> validate_required([:user_id, :workspace_slug])
    |> validate_length(:workspace_slug, min: 1, max: 63)
    |> validate_format(:workspace_slug, @slug_format)
    |> validate_length(:note, max: @note_max)
    |> validate_length(:requested_role, min: 1, max: 63)
    |> validate_format(:requested_role, @role_format)
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
