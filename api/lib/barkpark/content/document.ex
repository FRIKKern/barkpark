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
    field :search_vector, :any, virtual: true

    # Carries a task doc's hydrated `task_edges` rows (resolved PK→doc_id) so
    # the PURE `Barkpark.Plugins.Tasks.extract_edges/2` callback can project the
    # authoritative dependency graph WITHOUT a DB call. Populated only by
    # `Barkpark.Plugins.Tasks.hydrate_edges/1` in the EdgeProjector worker;
    # never persisted. See that module's docstring for the purity rationale.
    field :task_edges, :any, virtual: true

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    # W2 additive seam. Association is `:dataset_entity` because the legacy
    # `dataset` STRING field still owns the `:dataset` name (dual presence).
    belongs_to :dataset_entity, Barkpark.Tenancy.Dataset,
      foreign_key: :dataset_id,
      type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

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
      :dataset_id
    ])
    |> validate_required([:doc_id, :type])
    |> validate_inclusion(:status, ~w(draft published archived active planning completed))
    # W2 uniqueness flip: the row's identity leaf is now (doc_id, type,
    # dataset_id). The `dataset` STRING constraint is dropped at the DB level
    # (see migration 20260527134000); naming the flipped index here keeps the
    # changeset error mapped to the right constraint.
    |> unique_constraint([:doc_id, :type, :dataset_id],
      name: :documents_doc_id_type_dataset_id_index
    )
  end
end
