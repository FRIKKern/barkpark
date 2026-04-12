defmodule SanityApi.Repo.Migrations.AddMediaFiles do
  use Ecto.Migration

  def change do
    create table(:media_files, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :filename, :string, null: false
      add :original_name, :string, null: false
      add :path, :string, null: false
      add :mime_type, :string
      add :size, :integer
      add :dataset, :string, null: false, default: "production"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:media_files, [:path, :dataset])
    create index(:media_files, [:dataset])
    create index(:media_files, [:mime_type])
  end
end
