defmodule Barkpark.Audit.Event do
  @moduledoc """
  A single row in the append-only audit log. There is deliberately NO update
  changeset — the table is immutable at the DB layer (see the create migration)
  and rows are only ever inserted, via `Barkpark.Audit.emit/1`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # High-level bucket; the per-category action vocabulary is validated at the
  # emit call site so a new subsystem never has to fight a global enum.
  @categories ~w(content_mutation auth membership secret plugin_settings token)

  @type t :: %__MODULE__{}

  schema "audit_events" do
    field :category, :string
    field :action, :string
    field :subject, :string
    field :actor_type, :string
    field :actor_id, :string
    field :workspace_id, Ecto.UUID
    field :project_id, Ecto.UUID
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec
    field :prev_hash, :string
    field :hash, :string
  end

  @doc "Insert-only changeset. No update counterpart exists by design."
  @spec insert_changeset(map()) :: Ecto.Changeset.t()
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :category,
      :action,
      :subject,
      :actor_type,
      :actor_id,
      :workspace_id,
      :project_id,
      :metadata,
      :occurred_at,
      :prev_hash,
      :hash
    ])
    |> validate_required([:category, :action, :occurred_at, :hash])
    |> validate_inclusion(:category, @categories)
  end

  @doc "The valid category buckets."
  @spec categories() :: [String.t()]
  def categories, do: @categories
end
