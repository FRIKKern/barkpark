defmodule Barkpark.Repo.Migrations.AddSearchIntelEventTags do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE search_intel_events ADD COLUMN IF NOT EXISTS tags text[] NOT NULL DEFAULT '{}'",
      "ALTER TABLE search_intel_events DROP COLUMN IF EXISTS tags"
    )
  end
end
