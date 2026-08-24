defmodule Barkpark.Content.Document do
  @moduledoc """
  The Ecto schema for the `documents` table — the single physical home for every
  content type in Barkpark (posts, papers, tasks, sheets, …), discriminated by
  the `type` field. Carries tenant scope (workspace / project / dataset), the
  draft/published `status`, the freeform `content` map, and a content `rev`. Row
  identity is `(doc_id, type, dataset_id)`. `search_vector` and `task_edges` are
  virtual (never persisted) — the latter hydrated for the Tasks edge projector.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "documents" do
    field :doc_id, :string
    field :type, :string
    field :dataset, :string, default: "production"
    field :title, :string
    field :status, :string, default: "draft"
    field :content, :map, default: %{}
    field :rev, :string

    # DB-GENERATED STORED scalars mirrored out of `content` for the search path
    # (search-latency slice b, migration 20260718090000). Reading these narrow
    # text columns avoids detoasting the ~88KB `content` jsonb per candidate row
    # in the slug-ILIKE match arm + the author/category facet GROUP BYs. They are
    # `GENERATED ALWAYS AS (...) STORED` in Postgres — write-only-by-the-DB — so
    # they are intentionally ABSENT from `changeset/2`'s cast list; the write path
    # never sets them, and any attempt would be rejected by Postgres. Loaded on
    # every read; populated for existing rows by the migration's table rewrite.
    field :slug_text, :string, read_after_writes: true
    field :author_text, :string, read_after_writes: true
    field :category_text, :string, read_after_writes: true

    # DB-GENERATED STORED jsonb mirroring the doc's `content.tags` array for the
    # ranking ORDER BY's weighted-tag boost (search-latency slice d, migration
    # 20260718100000). It is the VERBATIM `CASE WHEN jsonb_typeof(content->'tags')
    # = 'array' THEN content->'tags' ELSE '[]'::jsonb END` the boost subquery used
    # to evaluate inline — materializing it lets the per-candidate boost read a
    # KB-sized array instead of DETOASTing the ~8.5KB–88KB `content` per matched
    # row (prod: 2,126 → 0 SubPlan buffers, 47 → 1.6 ms).
    #
    # `virtual: true` — like `search_vector` (also GENERATED STORED), it is a real
    # DB column that Ecto NEVER SELECTs into the struct: it is read ONLY through
    # the ORDER BY `fragment("?.tags_meta", d)`. So it ships zero payload bytes and
    # cannot trip the struct-equality parity that forced `read_after_writes` on the
    # scalar facet columns above.
    field :tags_meta, :any, virtual: true

    # Row/ownership ACL (Phase 4, core-auth). The user who owns this row on an
    # `owner_scoped: true` type. NULL = unowned (visible to everyone). Stamped on
    # the write path ONLY for owner_scoped types from the acting user's id; a
    # non-owner_scoped write leaves it NULL, so the ownership filter is a no-op
    # there. Read enforcement lives in `Barkpark.Content.Scope.scope_to_owner/2`.
    field :owner_id, :binary_id

    field :search_vector, :any, virtual: true

    # Carries a task doc's hydrated `task_edges` rows (resolved PK→doc_id) so
    # the PURE `Barkpark.Plugins.Tasks.extract_edges/2` callback can project the
    # authoritative dependency graph WITHOUT a DB call. Populated only by
    # `Barkpark.Plugins.Tasks.hydrate_edges/1` in the EdgeProjector worker;
    # never persisted. See that module's docstring for the purity rationale.
    field :task_edges, :any, virtual: true

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id
    belongs_to :current_revision, Barkpark.Content.Revision, type: :binary_id
    belongs_to :released_revision, Barkpark.Content.Revision, type: :binary_id

    # W2 additive seam. Association is `:dataset_entity` because the legacy
    # `dataset` STRING field still owns the `:dataset` name (dual presence).
    belongs_to :dataset_entity, Barkpark.Tenancy.Dataset,
      foreign_key: :dataset_id,
      type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  # The lifecycle statuses the `status` column accepts. Exposed as a function
  # because `Content.Writer` needs the SAME list to tell an envelope lifecycle
  # value apart from a user field that merely happens to be named `status` —
  # see `refuse_colliding_status/1` there. Duplicating the literal would drift:
  # adding a status here without updating the writer would make the writer
  # refuse a value this changeset accepts.
  @statuses ~w(draft published archived active planning completed)

  def statuses, do: @statuses

  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :doc_id,
      :type,
      :dataset,
      :title,
      :status,
      :content,
      :rev,
      :workspace_id,
      :project_id,
      :dataset_id,
      :owner_id
    ])
    |> validate_required([:doc_id, :type])
    # varchar(255) COLUMNS NEED A CHANGESET LENGTH GATE, OR POSTGRES ANSWERS 500.
    # `doc_id`, `type`, `dataset` and `title` are all Ecto `:string` in migration
    # 20260412090737_create_initial_tables — i.e. `character varying(255)`. With
    # no `validate_length/3` a longer value reaches the insert and Postgres
    # raises `Postgrex.Error ERROR 22001 (string_data_right_truncation)`, which
    # the API returns as HTTP 500. The write is handled correctly (the
    # transaction rolls back and nothing persists); the CLASSIFICATION is the
    # defect. A 500 tells the caller to retry, which fails identically forever,
    # and it books a client mistake against the server's error rate.
    #
    # All four are caller-supplied on the public write path: `_id` → doc_id,
    # `_type` → type, the `:dataset` path segment, and `title`. `status` needs no
    # length gate — `validate_inclusion` below already bounds it to six words —
    # and `rev` is server-generated (32 hex chars).
    #
    # RED vs GREEN: document_varchar_length_test.exs drops each gate in turn and
    # watches the matching arm red, and pins the raw-struct insert that PROVES
    # the column limit is 255 and that an unguarded value raises rather than
    # returning a changeset.
    |> validate_length(:doc_id, max: 255)
    |> validate_length(:type, max: 255)
    |> validate_length(:dataset, max: 255)
    |> validate_length(:title, max: 255)
    |> validate_inclusion(:status, @statuses)
    # W2 uniqueness flip: the row's identity leaf is now (doc_id, type,
    # dataset_id). The `dataset` STRING constraint is dropped at the DB level
    # (see migration 20260527134000); naming the flipped index here keeps the
    # changeset error mapped to the right constraint.
    |> unique_constraint([:doc_id, :type, :dataset_id],
      name: :documents_doc_id_type_dataset_id_index
    )
    # FK-abort containment (Felix W17). `workspace_id`, `project_id`, and
    # `dataset_id` are real Postgres foreign keys —
    # `references(:workspaces/:projects/:datasets, on_delete: :nilify_all)` from
    # migrations 20260527110100_add_tenancy_columns and
    # 20260527131000_add_dataset_id_columns, with Ecto-default constraint names
    # `documents_<col>_fkey`. `owner_id` is NOT this class — it is a plain
    # `:binary_id` column with no `references()` (migration
    # 20260629150300_add_owner_id_to_documents) — so it earns no constraint.
    #
    # WHO RAISES: both public write routes — POST /v1/data/mutate/:dataset
    # (MutateController) and POST /api/documents/:type (LegacyController) — flow
    # through `Content.Writer.upsert_document`/`create_document`, which build this
    # changeset and call the NON-BANG `Repo.insert()`. On a concurrently-deleted
    # scope (an admin deletes the workspace/project/dataset between write-token
    # scope resolution and the insert — a TOCTOU race; per D87 a DB-resolved id
    # gone stale counts like raw input) the insert raises a raw
    # `Ecto.ConstraintError` (a 500) instead of returning `{:error, changeset}`.
    #
    # RED vs GREEN: without these calls a bad/stale scope ref RAISES out of the
    # writer (500); with them Ecto translates the Postgres rejection into
    # `{:error, %Ecto.Changeset{}}` carrying `{"does not exist", _}` on the col.
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:dataset_id)
  end
end
