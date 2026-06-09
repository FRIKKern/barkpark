defmodule Barkpark.Sharing.ShareLink do
  @moduledoc """
  One ITEM share link (P7) — a direct, revocable `/s/<token>` link to a single
  document or media file. See `Barkpark.Sharing.Links` for the operations.

  The raw token is never stored — only its SHA256 (`token_hash`), mirroring
  `Barkpark.Auth.ApiToken`. Revocation/expiry are enforced in the resolve query,
  so a dead link is indistinguishable from a missing one.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  @kinds ~w(doc media)
  @accesses ~w(read edit)

  schema "share_links" do
    field :token_hash, :string
    field :dataset, :string, default: "production"
    field :kind, :string
    field :ref_type, :string
    field :ref_id, :string
    field :access, :string, default: "read"
    field :label, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :token_hash,
    :workspace_id,
    :project_id,
    :dataset,
    :kind,
    :ref_type,
    :ref_id,
    :access,
    :label,
    :expires_at,
    :revoked_at
  ]

  def changeset(link, attrs) do
    link
    |> cast(attrs, @fields)
    |> validate_required([:token_hash, :dataset, :kind, :ref_id, :access])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:access, @accesses)
    |> unique_constraint(:token_hash)
  end

  @doc "Legal item kinds."
  def kinds, do: @kinds

  @doc "Legal access levels."
  def accesses, do: @accesses
end
