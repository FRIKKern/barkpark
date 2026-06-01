defmodule Barkpark.Repo.Migrations.AddEngineToSearchSurfaceConfig do
  use Ecto.Migration

  def change do
    # Additive engine dimension for the pluggable-retriever SEAM. Existing rows
    # backfill to "postgres" (the only engine that exists today), so the default
    # search behavior is unchanged. A future engine (e.g. Indx) is selected by
    # writing a different value here — no schema change required.
    alter table(:search_surface_config) do
      add :engine, :string, default: "postgres", null: false
    end
  end
end
