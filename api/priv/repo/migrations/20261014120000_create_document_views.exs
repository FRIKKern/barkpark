defmodule Barkpark.Repo.Migrations.CreateDocumentViews do
  use Ecto.Migration

  @moduledoc """
  Two tables for document view counts (`Barkpark.Search.Views`,
  task-5feac4e826cff9a5).

  `document_view_days` holds one row per document per UTC day with the number
  of views recorded that day. `Barkpark.Search.Views.Buffer` adds to it in
  batches, so a view never writes the document itself. Rows older than the
  retention window are deleted by the rollup job.

  `document_popularity` holds one row per document that had a view in the
  last 30 days: the 7-day and 30-day sums and a score that halves every 7
  days. The rollup job rewrites it from `document_view_days`. GROQ, the query
  API and search read it by `(dataset_id, doc_id)`, and the three descending
  indexes answer a top-N read without sorting the table.

  Neither table holds an IP address, a user agent or a visitor hash. Both
  reference `datasets` with ON DELETE CASCADE, so deleting a dataset,
  project or workspace deletes its counts.
  """

  def change do
    create table(:document_view_days, primary_key: false) do
      add :dataset_id, references(:datasets, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :doc_id, :string, null: false, primary_key: true
      add :day, :date, null: false, primary_key: true
      add :type, :string, null: false
      add :views, :integer, null: false, default: 0
    end

    create index(:document_view_days, [:day])

    create table(:document_popularity, primary_key: false) do
      add :dataset_id, references(:datasets, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :doc_id, :string, null: false, primary_key: true
      add :type, :string, null: false
      add :views_7d, :integer, null: false, default: 0
      add :views_30d, :integer, null: false, default: 0
      add :score, :float, null: false, default: 0.0
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:document_popularity, [:dataset_id, "views_30d DESC"],
             name: :document_popularity_views_30d_idx
           )

    create index(:document_popularity, [:dataset_id, "views_7d DESC"],
             name: :document_popularity_views_7d_idx
           )

    create index(:document_popularity, [:dataset_id, "score DESC"],
             name: :document_popularity_score_idx
           )
  end
end
