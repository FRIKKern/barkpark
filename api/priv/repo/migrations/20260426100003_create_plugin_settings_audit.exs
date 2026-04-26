defmodule Barkpark.Repo.Migrations.CreatePluginSettingsAudit do
  use Ecto.Migration

  def change do
    create table(:plugin_settings_audit) do
      add :plugin_name, :string, null: false
      add :action, :string, null: false
      add :user_id, :string
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create index(:plugin_settings_audit, [:plugin_name, :occurred_at])
  end
end
