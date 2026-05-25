defmodule Barkpark.Repo.Migrations.AddTenancyColumns do
  use Ecto.Migration

  # Rollout-safe: every tenancy FK column is NULLABLE here. NOT NULL is
  # deferred to a later wave (after backfill + token-binding land). The
  # `references` give us the FK constraint + a btree index for scoped reads.
  # schema_definitions is project-scoped per the locked decision but still
  # carries workspace_id for denormalized query scoping.
  @ws_and_project ~w(
    documents
    revisions
    mutation_events
    media_files
    schema_definitions
    webhooks
    search_intel_events
    search_intel_crystals
    search_intel_merge_patterns
    search_synonyms
  )a

  def change do
    for table_name <- @ws_and_project do
      alter table(table_name) do
        add :workspace_id,
            references(:workspaces, type: :binary_id, on_delete: :nilify_all)

        add :project_id,
            references(:projects, type: :binary_id, on_delete: :nilify_all)
      end

      create index(table_name, [:workspace_id])
      create index(table_name, [:project_id])
    end

    alter table(:api_tokens) do
      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:api_tokens, [:workspace_id])
  end
end
