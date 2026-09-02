defmodule Barkpark.Sharing.ShareLink do
  @moduledoc """
  One ITEM share link (P7) — a direct, revocable `/s/<token>` link to a single
  document or media file. See `Barkpark.Sharing.Links` for the operations.

  BOTH forms of the token are persisted: `token_hash` (the SHA256 digest the
  resolve query matches on, mirroring `Barkpark.Auth.ApiToken`) AND the
  PLAINTEXT `token` itself, which P7's stable re-copyable link needs so a later
  `GET /v1/shares/links` can re-emit `/s/<token>`. That makes a ShareLink row a
  LIVE CREDENTIAL at rest: any read path that serialises a row (see
  `BarkparkWeb.ShareLinkController.link_json/1`, which emits `url:`) hands out
  working access to the bound item, so every such path must be authorised
  BEFORE it serialises. Revocation/expiry are enforced in the resolve query, so
  a dead link is indistinguishable from a missing one.

  EVERY ROW IS BOUND TO A TENANT SCOPE — `workspace_id` AND `project_id` are
  `validate_required` (`task-2da739b78e938be0`). Both columns are NULLABLE in
  the table and the changeset used to require NEITHER, so a row bound to no
  project was persistable. Such a row is not a sibling-scope survivor: it
  matches NO `(workspace_id, project_id, dataset)` triple, so
  `Barkpark.Sharing.Links.revoke_scope/3` — the cascade `Sharing.remove_share/3`
  fires when an operator withdraws a section share — CANNOT reach it, and it
  outlives every revocation an operator can perform on the scope it appears to
  belong to. The rule lives HERE, at the one changeset both mint doors cross,
  rather than at either door: the HTTP mint (`ShareLinkController.mint/2`)
  resolves a `%Tenancy.Project{}` before it builds attrs and so never produced
  one, while the Studio mint builds `project_id` as
  `socket.assigns[:current_project] && …` and had nothing pinning it non-nil.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  @kinds ~w(doc media)
  @accesses ~w(read edit)

  schema "share_links" do
    field :token_hash, :string
    # P7 UX: the raw token, stored so the link is stable + re-copyable (see the
    # add_token_to_share_links migration for the tradeoff). NOT a secret beyond
    # the content it already grants in a self-hosted/LAN context.
    field :token, :string
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
    :token,
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
    |> validate_required([
      :token_hash,
      :workspace_id,
      :project_id,
      :dataset,
      :kind,
      :ref_id,
      :access
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:access, @accesses)
    |> unique_constraint(:token_hash)
  end

  @doc "Legal item kinds."
  def kinds, do: @kinds

  @doc "Legal access levels."
  def accesses, do: @accesses
end
