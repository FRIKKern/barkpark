defmodule Barkpark.Repo.Migrations.FixSearchIntelSurfaceIndexes do
  use Ecto.Migration

  @moduledoc """
  Phase 0: include `surface` in crystal/merge unique keys; add suggest + trgm indexes.
  """

  def up do
    drop_if_exists unique_index(
                     :search_intel_crystals,
                     [:scope, :period, :period_start, :query_normalized, :filter_fingerprint],
                     name: :media_search_crystals_unique_idx
                   )

    create unique_index(
             :search_intel_crystals,
             [:surface, :scope, :period, :period_start, :query_normalized, :filter_fingerprint],
             name: :search_intel_crystals_unique_idx
           )

    drop_if_exists unique_index(
                     :search_intel_merge_patterns,
                     [
                       :scope,
                       :period,
                       :period_start,
                       :from_fingerprint,
                       :to_fingerprint,
                       :pattern_type
                     ],
                     name: :media_search_merge_patterns_unique_idx
                   )

    create unique_index(
             :search_intel_merge_patterns,
             [
               :surface,
               :scope,
               :period,
               :period_start,
               :from_fingerprint,
               :to_fingerprint,
               :pattern_type
             ],
             name: :search_intel_merge_patterns_unique_idx
           )

    execute(
      """
      CREATE INDEX search_intel_events_suggest_recent_idx
      ON search_intel_events (surface, scope, actor_key, inserted_at DESC)
      WHERE quality = 'accepted'
      """,
      "DROP INDEX IF EXISTS search_intel_events_suggest_recent_idx"
    )

    execute(
      """
      CREATE INDEX search_intel_events_query_normalized_prefix_idx
      ON search_intel_events (query_normalized text_pattern_ops)
      """,
      "DROP INDEX IF EXISTS search_intel_events_query_normalized_prefix_idx"
    )

    execute(
      """
      CREATE INDEX search_intel_crystals_popular_idx
      ON search_intel_crystals (surface, scope, period, period_start)
      WHERE query_normalized <> '__quality__'
      """,
      "DROP INDEX IF EXISTS search_intel_crystals_popular_idx"
    )

    execute("DROP INDEX IF EXISTS media_search_events_query_trgm_idx", "")

    execute(
      """
      CREATE INDEX search_intel_events_query_normalized_trgm_idx
      ON search_intel_events USING gin (query_normalized gin_trgm_ops)
      """,
      "DROP INDEX IF EXISTS search_intel_events_query_normalized_trgm_idx"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS search_intel_events_query_normalized_trgm_idx", "")

    execute(
      """
      CREATE INDEX media_search_events_query_trgm_idx
      ON search_intel_events USING gin (query gin_trgm_ops)
      """,
      "DROP INDEX IF EXISTS media_search_events_query_trgm_idx"
    )

    drop_if_exists index(:search_intel_crystals, [:surface, :scope, :period, :period_start],
      name: :search_intel_crystals_popular_idx
    )

    execute("DROP INDEX IF EXISTS search_intel_events_query_normalized_prefix_idx", "")
    execute("DROP INDEX IF EXISTS search_intel_events_suggest_recent_idx", "")

    drop_if_exists unique_index(:search_intel_merge_patterns, [],
      name: :search_intel_merge_patterns_unique_idx
    )

    create unique_index(
             :search_intel_merge_patterns,
             [:scope, :period, :period_start, :from_fingerprint, :to_fingerprint, :pattern_type],
             name: :media_search_merge_patterns_unique_idx
           )

    drop_if_exists unique_index(:search_intel_crystals, [], name: :search_intel_crystals_unique_idx)

    create unique_index(
             :search_intel_crystals,
             [:scope, :period, :period_start, :query_normalized, :filter_fingerprint],
             name: :media_search_crystals_unique_idx
           )
  end
end
