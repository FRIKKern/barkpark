defmodule Barkpark.Repo.Migrations.SearchAnalyticsCrystals do
  use Ecto.Migration

  @moduledoc """
  Crystallized search analytics (day / week / month) and merge-pattern tracking.

  Extends raw events with quality gates, lineage, and session keys; rollups
  survive raw-event pruning for long-term search improvement signals.
  """

  def change do
    alter table(:media_search_events) do
      add :query_normalized, :text, null: false, default: ""
      add :quality, :text, null: false, default: "accepted"
      add :reject_reason, :text
      add :parent_event_id, :binary_id
      add :source, :text, null: false, default: "api"
      add :session_key, :text
    end

    create index(:media_search_events, [:dataset, :quality, :inserted_at])
    create index(:media_search_events, [:parent_event_id])
    create index(:media_search_events, [:dataset, :session_key, :inserted_at])

    create table(:media_search_crystals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :dataset, :text, null: false
      add :period, :text, null: false
      add :period_start, :date, null: false
      add :query_normalized, :text, null: false, default: ""
      add :filter_fingerprint, :text, null: false, default: ""
      add :search_count, :integer, null: false, default: 0
      add :zero_hit_count, :integer, null: false, default: 0
      add :success_count, :integer, null: false, default: 0
      add :unique_actors, :integer, null: false, default: 0
      add :avg_result_count, :float, null: false, default: 0.0
      add :avg_duration_ms, :float, null: false, default: 0.0
      add :rejected_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :media_search_crystals,
             [:dataset, :period, :period_start, :query_normalized, :filter_fingerprint],
             name: :media_search_crystals_unique_idx
           )

    create index(:media_search_crystals, [:dataset, :period, :period_start])

    create table(:media_search_merge_patterns, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :dataset, :text, null: false
      add :period, :text, null: false
      add :period_start, :date, null: false
      add :from_fingerprint, :text, null: false
      add :to_fingerprint, :text, null: false
      add :pattern_type, :text, null: false
      add :transition_count, :integer, null: false, default: 0
      add :success_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :media_search_merge_patterns,
             [
               :dataset,
               :period,
               :period_start,
               :from_fingerprint,
               :to_fingerprint,
               :pattern_type
             ],
             name: :media_search_merge_patterns_unique_idx
           )

    create index(:media_search_merge_patterns, [:dataset, :period, :period_start])
  end
end
