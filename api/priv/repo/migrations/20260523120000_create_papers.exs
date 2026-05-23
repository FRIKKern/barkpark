defmodule Barkpark.Repo.Migrations.CreatePapers do
  use Ecto.Migration

  # Convergence MVP (masterplan Figure 6). A tiny dedicated store for
  # paperflow papers — deliberately NOT the `documents` table: papers carry
  # opaque pre-rendered HTML (no schema validation, no draft/published
  # machinery, no portable-doc block list). Keyed by slug within a dataset.
  def change do
    create table(:papers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :text, null: false
      add :dataset, :text, null: false, default: "paperflow"
      add :source_doc, :text
      add :goal_id, :text
      add :event_type, :text
      # The opaque article-body HTML rendered into the LiveView container.
      add :body_html, :text, null: false, default: ""
      # Per-save revision so a broadcast carries an identity LiveView can log.
      add :rev, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:papers, [:dataset, :slug])
  end
end
