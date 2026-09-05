defmodule Barkpark.Content.PaperAccessLog do
  @moduledoc """
  One append-only row: somebody reached a paper, and what they did there.

  Written by `Barkpark.Content.PaperAccess.record/1` from two places only — the
  paper reader's connected mount ("view") and each accepted block op ("edit").
  Never updated, never read back into a write.

  See `Barkpark.Content.PaperAccess` for the contract and the retention rule,
  and the migration `20260904120100_create_paper_access_log.exs` for why
  `workspace_id` is not a foreign key.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @actions ~w(view edit)
  @actor_kinds ~w(user api_token share anonymous)

  schema "paper_access_log" do
    field :workspace_id, Ecto.UUID
    field :dataset, :string
    field :slug, :string
    field :action, :string
    field :actor_kind, :string
    field :actor_id, :string
    field :actor_label, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The actions this log admits."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "The actor kinds this log admits."
  @spec actor_kinds() :: [String.t()]
  def actor_kinds, do: @actor_kinds

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :workspace_id,
      :dataset,
      :slug,
      :action,
      :actor_kind,
      :actor_id,
      :actor_label
    ])
    |> validate_required([:dataset, :slug, :action, :actor_kind])
    # The vocabulary is closed on purpose. A row with an action nobody queries
    # for is a row that silently does not exist, so a typo must red at the
    # write, not at the read months later.
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:actor_kind, @actor_kinds)
    # An anonymous visitor has no id, and recording one would defeat the whole
    # posture of the table. Enforced here rather than trusted to every caller.
    |> scrub_anonymous_identity()
  end

  defp scrub_anonymous_identity(changeset) do
    case get_field(changeset, :actor_kind) do
      "anonymous" ->
        changeset
        |> put_change(:actor_id, nil)
        |> put_change(:actor_label, nil)

      _ ->
        changeset
    end
  end
end
