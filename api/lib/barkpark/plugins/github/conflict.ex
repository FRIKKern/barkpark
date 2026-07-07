defmodule Barkpark.Plugins.Github.Conflict do
  @moduledoc """
  One row in the GitHub sync quarantine (`github_sync_conflicts`, epic D7).

  A conflict is out-of-band bookkeeping — the record that the ledger and a
  mirrored issue disagreed. It is NOT a document and NOT a task mutation, so
  writing one can never re-trigger sync. See `Barkpark.Plugins.Github.Conflicts`
  for the recorder that owns the dedup/list/resolve operations.

  `kind` is one of #{inspect(~w(out_of_band_edit detached dedup_refused))};
  `doc_id` is nullable (a `dedup_refused` intake never produced a task);
  a row is "open" until `resolved_at` is set.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds ~w(out_of_band_edit detached dedup_refused)

  @doc "The valid `kind` values."
  def kinds, do: @kinds

  schema "github_sync_conflicts" do
    field :repo, :string
    field :issue, :integer
    field :doc_id, :string
    field :dataset, :string
    field :kind, :string
    field :detail, :map, default: %{}
    field :resolved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:repo, :issue, :doc_id, :dataset, :kind, :detail, :resolved_at]

  @doc "Name of the partial unique index enforcing one OPEN row per dedup key."
  def open_key_constraint, do: :github_sync_conflicts_open_key

  @doc """
  Cast + validate a conflict. `repo`, `issue`, `dataset` and `kind` are
  required; `kind` must be one of the three drift kinds; `detail` defaults to
  an empty map (never null). The `open_key` unique constraint converts a lost
  insert race (two concurrent first-records for one key) into a matchable
  `{:error, changeset}` rather than a raised `Ecto.ConstraintError`, so the
  recorder can catch it and converge in place.
  """
  def changeset(conflict, attrs) do
    conflict
    |> cast(attrs, @fields)
    |> validate_required([:repo, :issue, :dataset, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> put_detail_default()
    |> unique_constraint([:repo, :issue, :kind], name: open_key_constraint())
  end

  # detail is null:false default %{} at the DB level; keep the changeset honest
  # so an explicit nil never trips the NOT NULL constraint at insert time.
  defp put_detail_default(changeset) do
    case get_field(changeset, :detail) do
      nil -> put_change(changeset, :detail, %{})
      _ -> changeset
    end
  end
end
