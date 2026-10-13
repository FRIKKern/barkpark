defmodule Barkpark.Repo.Migrations.CreateUserPrefs do
  use Ecto.Migration

  # task-7d2a48dbf7e4bf34 — Barkpark had no per-user store for app tokens, so
  # the Studio kept recent searches in localStorage and list prefs in a
  # cookie (per browser, never following the editor). A small per-user,
  # per-workspace, per-dataset JSON blob keyed by name, mirroring Sanity's
  # studio.search.recent.<dataset>-style keys without baking the dataset
  # into the key string (it is its own column here, so a key name stays
  # dataset-independent: "recent_searches", "list_prefs.taskList", ...).
  def change do
    create table(:user_prefs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :dataset, :string, null: false
      add :key, :string, null: false
      add :value, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_prefs, [:user_id, :workspace_id, :dataset, :key],
             name: :user_prefs_user_workspace_dataset_key_idx
           )
  end
end
