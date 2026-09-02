defmodule Barkpark.Content.Revision do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "revisions" do
    belongs_to :document, Barkpark.Content.Document, type: :binary_id
    field :doc_id, :string
    field :type, :string
    field :dataset, :string, default: "production"
    field :title, :string
    field :status, :string
    field :content, :map
    field :action, :string

    # [rev-hash-has-no-read] The source document's OPAQUE rev at snapshot time —
    # the same string the envelope publishes as `"_rev"`. Without it a `_rev`
    # cited by an acceptance criterion resolved to nothing: this table is keyed
    # by its own UUID, so there was no path from the hash to the content it
    # names. NULLABLE — history written before the column existed never recorded
    # the hash and cannot be backfilled. Read via
    # `Content.Revisions.get_revision_by_rev/3`.
    field :rev, :string

    # WHO produced this revision — the actor threaded from the mutation's
    # `opts[:user_id]` (`ctx.user_id`). A plain string (an api-token / user id),
    # NULLABLE: system writes and pre-trail history have no actor. Turns version
    # history into a who-edited-what content trail.
    field :actor_user_id, :string

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    # W2 additive seam. `:dataset_entity` — the legacy `dataset` STRING field
    # still owns `:dataset` (dual presence). FK column is `dataset_id`.
    belongs_to :dataset_entity, Barkpark.Tenancy.Dataset,
      foreign_key: :dataset_id,
      type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :doc_id,
      :type,
      :dataset,
      :dataset_id,
      :title,
      :status,
      :content,
      :action,
      :rev,
      :actor_user_id,
      :document_id,
      :workspace_id,
      :project_id
    ])
    |> validate_required([:doc_id, :type, :action])
    # FK-abort containment (Felix W17, the changeset-FK-abort scar-class — the
    # sibling to Content.Document / MediaFile / bulldocs Event / SchemaDefinition).
    # `revisions.document_id/workspace_id/project_id/dataset_id` are ALL real
    # Postgres foreign keys: `workspace_id/project_id/dataset_id` from
    # `references(:workspaces/:projects/:datasets)` (migration
    # 20260527160000_cascade_content_on_scope_delete, columns from
    # 20260527110100 / 20260527131000), and `document_id` from
    # `references(:documents)` (migration 20260719010000, constraint recreated as
    # `revisions_document_id_fkey` by 20260719020200) — every one carries the
    # Ecto-default constraint name `revisions_<col>_fkey`.
    #
    # WHO RAISES: revisions are written by the NON-BANG `Broadcast.save_revision`
    # (broadcast.ex) from `Content.BlockOps.maybe_save_batch_revision` (Studio
    # paper editing / accept-baseline) and `Content.ValueWriteback`'s
    # `tap_provenance_revision`. `apply_paper_block_ops` is NOT
    # transaction-wrapped: the content `Repo.update` commits (scope columns
    # unchanged, so Postgres does not re-check the FK) and a SEPARATE
    # `Repo.insert` writes the revision. On a concurrently hard-deleted scope
    # (a TOCTOU race — per D87 a DB-resolved id gone stale counts like raw
    # input), that insert RAISES a raw `Ecto.ConstraintError` (a 500) that
    # bypasses both callers' `{:error, reason}` best-effort handlers.
    #
    # RED vs GREEN: without these calls a bad/stale scope (or document) ref
    # RAISES; with them Ecto translates the Postgres rejection into
    # `{:error, %Ecto.Changeset{}}` carrying `{"does not exist", _}` on the col,
    # so the existing best-effort handlers fail-soft as their authors intended.
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:dataset_id)
  end
end
