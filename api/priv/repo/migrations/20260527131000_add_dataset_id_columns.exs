defmodule Barkpark.Repo.Migrations.AddDatasetIdColumns do
  use Ecto.Migration

  @moduledoc """
  Wave-2 foundation (additive). Add a NULLABLE `dataset_id` FK to every
  content-bearing table that carries a dataset-equivalent string. The string
  column stays authoritative — `dataset_id` rides alongside (dual presence)
  and is backfilled by 20260527132000.

  Nullable + `on_delete: :nilify_all` mirrors the Wave-1 tenancy column
  rollout (20260527110100): NOT NULL is a later, riskier W2 step. Each table
  gets a btree index on `dataset_id` for scoped reads.

  Note on the dataset string per table:
    * documents/revisions/mutation_events/media_files/schema_definitions/
      webhooks/api_tokens carry a literal `dataset` column.
    * search_intel_events/search_intel_crystals/search_intel_merge_patterns/
      search_synonyms carry `scope` (renamed from `dataset` in 20260526140000).
    * paper_events carries neither — it follows its paper's scope. The FK is
      still added for the dual-presence seam; the backfill stamps it Default.
  All of them get the same `dataset_id` FK shape here regardless of the
  string column's name; matching the right string is the backfill's job.
  """
  @tables ~w(
    documents
    revisions
    mutation_events
    media_files
    schema_definitions
    search_intel_events
    search_intel_crystals
    search_intel_merge_patterns
    search_synonyms
    webhooks
    api_tokens
    paper_events
  )a

  def change do
    for table_name <- @tables do
      alter table(table_name) do
        add :dataset_id,
            references(:datasets, type: :binary_id, on_delete: :nilify_all)
      end

      # mutation_events already has a `[:dataset, :id]` index whose Ecto
      # auto-name (mutation_events_dataset_id_index) collides with the default
      # name for a `[:dataset_id]` index — so name this one explicitly.
      create index(table_name, [:dataset_id], name: index_name(table_name))
    end
  end

  defp index_name(:mutation_events), do: :mutation_events_dataset_fk_index
  defp index_name(table_name), do: :"#{table_name}_dataset_id_index"
end
