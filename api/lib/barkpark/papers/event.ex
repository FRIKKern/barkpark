defmodule Barkpark.Papers.Event do
  @moduledoc """
  Ecto schema for `paper_events` — an append-only paperflow lifecycle event
  (`plan-written`, `goal-snapshot`, `phase-advanced`, …) scoped to a goal
  and/or paper. Backs the native goal-path rail (P6.U2).

  `branch` carries `alt-<n>` / `simplified-<n>` for the rail's gitGraph;
  `parent_event_id` threads the lineage chain. `payload_html` is the sidecar
  HTML the rail/diff surfaces show.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "paper_events" do
    field :goal_id, :string
    field :paper_slug, :string
    field :event_type, :string
    field :branch, :string, default: "main"
    field :parent_event_id, :binary_id
    field :payload_html, :string
    field :source_doc, :string

    # W1.5-C tenancy scope. A paper_event FOLLOWS its goal — its scope = the
    # goal's (and its paper's) workspace/project. NULLABLE: NULL = unscoped /
    # back-compat (paperflow ingest still sends FLAT). Stamped on create from
    # the resolved workspace/project (Default fallback); queries filter by
    # workspace_id only when a scope is provided (nil = unscoped read).
    field :workspace_id, :binary_id
    field :project_id, :binary_id

    # W2 additive seam: a paper_event follows its paper's dataset. NULLABLE,
    # dual-presence — `belongs_to` so the assoc + `dataset_id` field land. Not
    # cast in the changeset yet (string still authoritative; stamped by backfill).
    belongs_to :dataset, Barkpark.Tenancy.Dataset, type: :binary_id

    # P6.U6a (barkpark-jwai): NULL = pending intent; a timestamp = consumed by
    # the paperflow-side reader loop. Set on `Events.mark_processed/1`, never on
    # create — deliberately omitted from the changeset cast/validation.
    field :processed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset for a paper event. `event_type` is always required;
  at least one of `goal_id` / `paper_slug` must be present so the event is
  addressable on the rail.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :goal_id,
      :paper_slug,
      :event_type,
      :branch,
      :parent_event_id,
      :payload_html,
      :source_doc,
      :workspace_id,
      :project_id
    ])
    |> validate_required([:event_type])
    |> validate_goal_or_paper()
    |> maybe_default_branch()
  end

  defp validate_goal_or_paper(changeset) do
    goal_id = get_field(changeset, :goal_id)
    paper_slug = get_field(changeset, :paper_slug)

    if present?(goal_id) or present?(paper_slug) do
      changeset
    else
      add_error(changeset, :goal_id, "goal_id or paper_slug is required")
    end
  end

  defp maybe_default_branch(changeset) do
    case get_field(changeset, :branch) do
      nil -> put_change(changeset, :branch, "main")
      "" -> put_change(changeset, :branch, "main")
      _ -> changeset
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: true
  defp present?(_), do: false
end
