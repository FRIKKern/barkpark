defmodule Barkpark.Sharing.PreviewLink do
  @moduledoc """
  One DRAFT-capable preview link (task-6812c3100d7aedbc) — a direct, revocable
  `/sp/<token>` link to ONE document, published OR unpublished. See
  `Barkpark.Sharing.PreviewLinks` for the operations.

  A SIBLING of `Barkpark.Sharing.ShareLink` (P7 item share links), not an
  extension of it: `Barkpark.Sharing.Links.create/1` unconditionally strips a
  `drafts.` prefix off `ref_id` before persisting
  (`arpss-w8-bl-share-link-drafts-ref-id`), so that table structurally cannot
  name a draft row. `doc_id` HERE is stored exactly as minted — a
  `drafts.`-prefixed id survives — because letting a reviewer preview the
  unpublished document is this feature's entire purpose.

  THE HASHED-AT-REST SHAPE IS REUSED FROM `ShareLink`: only `token_hash`
  (SHA256) is persisted, never the plaintext — see
  `Barkpark.Sharing.Links.hash_token/1`, which this schema's context calls
  directly rather than re-deriving. The raw token is returned exactly once,
  from the mint response.

  `workspace_id` and `project_id` are `validate_required`, mirroring the
  `share_links` bound-row invariant (`task-2da739b78e938be0`): a row bound to
  no project matches no `(workspace, project, dataset)` triple and so is
  unrevokable by any scope-keyed operation.

  `expires_at` is ALSO `validate_required` here — the one deliberate
  divergence from `ShareLink`, whose `ttl` is optional (a link can never
  expire). Previewing unpublished content is more sensitive, so every preview
  link carries a TTL; `PreviewLinks.create/1` defaults and caps it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "preview_links" do
    field :token_hash, :string
    field :dataset, :string, default: "production"
    field :doc_id, :string
    field :ref_type, :string
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
    :doc_id,
    :ref_type,
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
      :doc_id,
      :ref_type,
      :expires_at
    ])
    |> unique_constraint(:token_hash)
  end
end
