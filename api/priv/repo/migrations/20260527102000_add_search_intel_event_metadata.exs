defmodule Barkpark.Repo.Migrations.AddSearchIntelEventMetadata do
  use Ecto.Migration

  def change do
    alter table(:search_intel_events) do
      add :metadata, :map, null: false, default: %{}
    end
  end
end
