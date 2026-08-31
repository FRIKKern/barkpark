defmodule Barkpark.Tasks.Edge do
  @moduledoc """
  W7a step 2 — a single typed dependency edge between two `documents` rows.

  See `Barkpark.Tasks` (the parent module) for the dep-graph CRUD that wraps
  this schema. The migration that creates the table is
  `priv/repo/migrations/20260528110000_w7a_task_edges.exs`; its moduledoc
  carries the indexes/cascade/tenancy rationale.

  ## Direction

  `from_id` = the dependent (it BLOCKS ON something).
  `to_id`   = the blocker (it is depended upon).

  The ready query (W7-03) scans outbound edges from a candidate
  (`from_id = candidate.id`) to find its
  blockers (`to_id`).

  ## Kinds

  Two named kinds today (`blocks`, `discovered-from`); the column is
  `:string` so a future masterplan addition can land without a migration.
  Application boundary validation lives in `Barkpark.Tasks.add_dep/3`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Barkpark.Content.Document

  @kinds ~w(blocks discovered-from)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "task_edges" do
    belongs_to :from, Document, foreign_key: :from_id, type: :binary_id
    belongs_to :to, Document, foreign_key: :to_id, type: :binary_id
    field :kind, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The known edge kinds. Extending is a one-line edit; no migration."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Changeset for inserting a new edge. Validates `from_id`/`to_id`/`kind`
  presence and that `kind` is one of the known values; rejects self-edges.
  The FK + uniqueness constraints in the migration are surfaced as
  changeset errors for friendlier callers.
  """
  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:from_id, :to_id, :kind])
    |> validate_required([:from_id, :to_id, :kind])
    |> validate_inclusion(:kind, @kinds, message: "must be one of #{inspect(@kinds)}")
    |> validate_not_self_edge()
    |> foreign_key_constraint(:from_id)
    |> foreign_key_constraint(:to_id)
    |> unique_constraint([:from_id, :to_id, :kind],
      name: :task_edges_from_to_kind_uniq
    )
  end

  defp validate_not_self_edge(changeset) do
    from_id = get_field(changeset, :from_id)
    to_id = get_field(changeset, :to_id)

    if from_id && to_id && from_id == to_id do
      add_error(changeset, :to_id, "edge cannot reference the same document on both sides")
    else
      changeset
    end
  end
end
