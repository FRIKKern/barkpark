defmodule Barkpark.Sharing.StoredShare do
  @moduledoc """
  The durable twin of a `Barkpark.Sharing.Share` — one row in the `shares`
  table (P4). Where `Sharing.Share` is the in-memory value object parsed from
  `BARKPARK_SHARES`, a `StoredShare` is a share that survives a restart and can
  be managed at runtime by `bp share add/rm` and the Studio.

  Surfaces and access are stored as plain strings (the same tokens the env
  parser accepts: `"papers"|"docs"|"media"`, `"read"|"edit"`). They are NOT
  trusted on read — `Barkpark.Sharing.list_stored/0` rebuilds each row through
  the SAME `parse/1` validation as an env share, so a malformed or stale row can
  never widen access; it is simply dropped.

  A scope (workspace / project / dataset) has at most one row — the unique
  `:shares_scope_index` makes "add a share for this scope" an upsert that
  replaces the prior surfaces/access.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "shares" do
    field :workspace_slug, :string
    field :project_slug, :string
    field :dataset, :string
    field :surfaces, {:array, :string}
    field :access, :string

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:workspace_slug, :project_slug, :dataset, :surfaces, :access]

  @doc """
  Changeset for a stored share. Requires every field and at least one surface.
  This is a STRUCTURAL guard only — the surface/access TOKENS are revalidated on
  read by `Sharing.list_stored/0` (through `Sharing.parse/1`), so the source of
  truth for "is this a legal grant" stays the one parser.
  """
  def changeset(stored_share, attrs) do
    stored_share
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_length(:surfaces, min: 1)
    |> unique_constraint([:workspace_slug, :project_slug, :dataset],
      name: :shares_scope_index
    )
  end
end
