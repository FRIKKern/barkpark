defmodule Barkpark.Repo.Migrations.CreateEcosystemPanelSnapshots do
  use Ecto.Migration

  @moduledoc """
  Ecosystem panel snapshots (task-270112c682dc71de, plan Paper
  `ecosystem-panel-behind-login`).

  One row per workspace, overwritten on every push: the built HTML of the
  eco-dash panel, when the Mac built it, when the server received it, its size
  and its sha256. Deliberately NOT a document, so a push leaves no revision
  history and the page never reaches search, webhooks, the listen stream or
  the desk.

  Additive: a new table, no change to any existing one. A core migration (like
  Pulse's tables), so it runs on every deploy whatever `BARKPARK_PLUGINS` says.
  """

  def change do
    create table(:ecosystem_panel_snapshots, primary_key: false) do
      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :html, :text, null: false
      add :built_at, :utc_datetime_usec, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :bytes, :integer, null: false
      add :sha256, :text, null: false
    end
  end
end
