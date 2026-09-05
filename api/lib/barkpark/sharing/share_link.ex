defmodule Barkpark.Sharing.ShareLink do
  @moduledoc """
  One ITEM share link (P7) — a direct, revocable `/s/<token>` link to a single
  document or media file. See `Barkpark.Sharing.Links` for the operations.

  ONLY THE DIGEST IS PERSISTED — `token_hash` (SHA256, mirroring
  `Barkpark.Auth.ApiToken`), which is what `Links.resolve/1` matches on. THE
  PLAINTEXT TOKEN IS NOT A FIELD OF THIS SCHEMA and there is no column behind
  it (`20260904020000_drop_token_from_share_links.exs`). A ShareLink row is
  therefore NOT a credential at rest: no read path that serialises one can hand
  out working access, because the row does not contain the secret.

  THE TRADEOFF, RE-ARGUED AND RECORDED HERE so the next auditor finds the
  reasoning instead of re-opening it (`arpss-w8-bl-share-link-raw-token-at-rest`,
  RULED by team-lead 2026-09-02: "RETIRE the plaintext token column"). The
  column existed for a real P7 feature — a STABLE, RE-COPYABLE `/s/<token>`
  URL the Studio popover showed every time, Google-Docs-style. Its migration
  (`20260609150000_add_token_to_share_links.exs`) justified plaintext at rest
  from "a self-hosted/LAN context — anyone who can read this column can already
  read the shared content directly". THAT PREMISE IS VOID ON A MULTI-TENANT
  INSTALL: the column's readers are not the shared content's readers, so a
  serialising read path was handing a stranger a live credential rather than
  metadata (which is exactly the hole arpss-w8 closed in
  `ShareLinkController.list/2`). Dropping the column closes that disclosure
  CLASS structurally rather than per-path, so a FUTURE tenancy regression on
  this surface cannot leak a live token. The cost is paid in the UX: a link can
  be listed, labelled and REVOKED, but its URL cannot be RE-DISPLAYED — the raw
  token is returned in ONE place, the mint 201, and an operator who loses it
  regenerates. Revocation/expiry are enforced in the resolve query, so a dead
  link is indistinguishable from a missing one.

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
