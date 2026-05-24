defmodule Barkpark.Repo.Migrations.CreateMediaSearchEvents do
  use Ecto.Migration

  @moduledoc """
  Search analytics for Media Desk — recent queries, popular queries, zero-hit tracking.

  Inspired by Typesense `popular_queries` / Algolia Query Suggestions: every search
  (first page only) is logged; aggregates power autocomplete in the explorer UI.

  Optional `pg_trgm` enables faster prefix/fuzzy matching on query text when the
  extension is available (standard on Postgres, no ParadeDB required).
  """

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm", "")

    create table(:media_search_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :dataset, :text, null: false
      add :query, :text, null: false, default: ""
      add :filters, :map, null: false, default: %{}
      add :result_count, :integer, null: false, default: 0
      add :zero_hits, :boolean, null: false, default: false
      add :actor_key, :text, null: false, default: "anon"
      add :duration_ms, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:media_search_events, [:dataset, :inserted_at])
    create index(:media_search_events, [:dataset, :actor_key, :inserted_at])
    create index(:media_search_events, [:dataset, :zero_hits, :inserted_at])

    execute(
      """
      CREATE INDEX media_search_events_query_trgm_idx
      ON media_search_events USING gin (query gin_trgm_ops)
      """,
      "DROP INDEX IF EXISTS media_search_events_query_trgm_idx"
    )
  end

  def down do
    drop index(:media_search_events, [:dataset, :inserted_at])
    drop index(:media_search_events, [:dataset, :actor_key, :inserted_at])
    drop index(:media_search_events, [:dataset, :zero_hits, :inserted_at])
    execute("DROP INDEX IF EXISTS media_search_events_query_trgm_idx", "")
    drop table(:media_search_events)
  end
end
