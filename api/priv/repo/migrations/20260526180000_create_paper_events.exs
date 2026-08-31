defmodule Barkpark.Repo.Migrations.CreatePaperEvents do
  use Ecto.Migration

  @moduledoc """
  Append-only store of paperflow lifecycle events (`plan-written`,
  `goal-snapshot`, `phase-advanced`, …) per goal/paper — the data spine for
  the native goal-path rail (P6.U2).

  Decoupled from W7: the web tier never shells out to an external task process. Rows are
  appended by `Barkpark.Content.upsert_paper/1` when an `event_type` is
  present. `branch` carries `alt-<n>` / `simplified-<n>` for the rail's
  gitGraph; `parent_event_id` threads the lineage chain.
  """

  def up do
    create table(:paper_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :goal_id, :string
      add :paper_slug, :string
      add :event_type, :string, null: false
      add :branch, :string, null: false, default: "main"
      add :parent_event_id, :binary_id
      add :payload_html, :text
      add :source_doc, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:paper_events, [:goal_id])
    create index(:paper_events, [:paper_slug])
    create index(:paper_events, [:goal_id, :inserted_at])
    create index(:paper_events, [:paper_slug, :inserted_at])
    create index(:paper_events, [:parent_event_id])
  end

  def down do
    drop index(:paper_events, [:parent_event_id])
    drop index(:paper_events, [:paper_slug, :inserted_at])
    drop index(:paper_events, [:goal_id, :inserted_at])
    drop index(:paper_events, [:paper_slug])
    drop index(:paper_events, [:goal_id])
    drop table(:paper_events)
  end
end
