defmodule Barkpark.Repo.Migrations.CreatePluginSettings do
  use Ecto.Migration

  def change do
    create table(:plugin_settings, primary_key: false) do
      add :plugin_name, :string, primary_key: true, null: false
      add :settings, :binary, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :updated_by, :string
    end
  end
end
