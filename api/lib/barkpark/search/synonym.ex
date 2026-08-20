defmodule Barkpark.Search.Synonym do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @castable ~w(surface scope from_query to_query kind source enabled workspace_id project_id dataset_id)a
  @required ~w(surface scope from_query to_query kind)a

  schema "search_synonyms" do
    field :surface, :string
    field :scope, :string
    field :from_query, :string
    field :to_query, :string
    field :kind, :string, default: "one_way"
    field :source, :string, default: "manual"
    field :enabled, :boolean, default: true

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id
    belongs_to :dataset, Barkpark.Tenancy.Dataset, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for a synonym write.

  Carries `unique_constraint`s for BOTH partial unique indexes introduced by
  `20260715120000_search_synonyms_workspace_unique_index` so a same-tuple
  duplicate — in either the per-workspace arm (`workspace_id IS NOT NULL`) or
  the legacy/global arm (`workspace_id IS NULL`) — is mapped to
  `{:error, changeset}` (→ HTTP 422) instead of surfacing as a raw
  `Ecto.ConstraintError` (→ HTTP 500). Before this changeset existed the write
  path used a bare `Ecto.Changeset.change/2` + `Repo.insert/1`, so a constraint
  hit had no `unique_constraint` to catch it and escaped as a 500 — the live
  cross-tenant collision this slice closes.
  """
  def changeset(synonym, attrs) do
    synonym
    |> cast(attrs, @castable)
    |> validate_required(@required)
    |> unique_constraint(:from_query,
      name: :search_synonyms_workspace_unique_idx,
      message: "synonym already exists"
    )
    |> unique_constraint(:from_query,
      name: :search_synonyms_null_ws_unique_idx,
      message: "synonym already exists"
    )
  end
end
