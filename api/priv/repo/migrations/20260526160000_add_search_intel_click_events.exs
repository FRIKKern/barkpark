defmodule Barkpark.Repo.Migrations.AddSearchIntelClickEvents do
  use Ecto.Migration

  @moduledoc """
  Phase 2: click/select interaction events linked to search events; CTR on crystals.
  """

  def change do
    alter table(:search_intel_events) do
      add :event_type, :text, null: false, default: "search"
      add :object_id, :text
      add :position, :integer
      add :query_event_id, references(:search_intel_events, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:search_intel_events, [:query_event_id])
    create index(:search_intel_events, [:surface, :scope, :event_type, :inserted_at])

    alter table(:search_intel_crystals) do
      add :click_count, :integer, null: false, default: 0
      add :ctr, :float, null: false, default: 0.0
    end
  end
end
