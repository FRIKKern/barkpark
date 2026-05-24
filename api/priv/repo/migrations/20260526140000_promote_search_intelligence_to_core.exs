defmodule Barkpark.Repo.Migrations.PromoteSearchIntelligenceToCore do
  use Ecto.Migration

  @moduledoc """
  Promote media-specific search analytics tables to Barkpark core `search_intel_*`.

  Adds `surface` (e.g. media, documents) and renames `dataset` → `scope` so any
  product surface can plug into `Barkpark.Search.Intelligence`.
  """

  def change do
    rename table(:media_search_events), to: table(:search_intel_events)
    rename table(:media_search_crystals), to: table(:search_intel_crystals)
    rename table(:media_search_merge_patterns), to: table(:search_intel_merge_patterns)

    alter table(:search_intel_events) do
      add :surface, :text, null: false, default: "media"
    end

    alter table(:search_intel_crystals) do
      add :surface, :text, null: false, default: "media"
    end

    alter table(:search_intel_merge_patterns) do
      add :surface, :text, null: false, default: "media"
    end

    rename table(:search_intel_events), :dataset, to: :scope
    rename table(:search_intel_crystals), :dataset, to: :scope
    rename table(:search_intel_merge_patterns), :dataset, to: :scope

    create index(:search_intel_events, [:surface, :scope, :inserted_at])
    create index(:search_intel_crystals, [:surface, :scope, :period, :period_start])
    create index(:search_intel_merge_patterns, [:surface, :scope, :period, :period_start])
  end
end
