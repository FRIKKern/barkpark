defmodule Barkpark.ChatHosts.ExecutionLease do
  @moduledoc "Epoch-fenced lease for one registered-host runtime command stream."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @providers ~w(claude codex)
  @statuses ~w(leased running disconnected completed cancelled)

  schema "chat_execution_leases" do
    belongs_to :host, Barkpark.ChatHosts.RegisteredHost
    belongs_to :workspace, Barkpark.Tenancy.Workspace
    belongs_to :session, Barkpark.StudioChat.Session
    field :provider, :string
    field :epoch, :integer, default: 1
    field :command_key, :string
    field :last_cursor, :integer, default: 0
    field :status, :string, default: "leased"
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    # Server-written only, never cast: the first poll that handed this lease
    # to a host (`ChatHosts.next_commands/1`).
    field :handed_out_at, :utc_datetime_usec
    # An approval answer's lease only: the approval it answers and the lease
    # that asked it (`AskingLease`), so a host's refusal names one ask
    # (task-746c02d760f26ce7). NULL on every other lease.
    field :approval_id, :string
    field :asked_lease_id, :binary_id
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :host_id,
      :workspace_id,
      :session_id,
      :provider,
      :epoch,
      :command_key,
      :last_cursor,
      :status,
      :expires_at,
      :revoked_at,
      :approval_id,
      :asked_lease_id
    ])
    |> validate_required([
      :host_id,
      :workspace_id,
      :session_id,
      :provider,
      :command_key,
      :expires_at
    ])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:epoch, greater_than: 0)
    |> validate_number(:last_cursor, greater_than_or_equal_to: 0)
    |> unique_constraint([:host_id, :command_key])
  end
end
