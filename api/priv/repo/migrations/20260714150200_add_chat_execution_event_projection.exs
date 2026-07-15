defmodule Barkpark.Repo.Migrations.AddChatExecutionEventProjection do
  use Ecto.Migration

  def change do
    alter table(:chat_execution_events) do
      add :projected_at, :utc_datetime_usec
    end

    create index(:chat_execution_events, [:projected_at], where: "projected_at IS NULL")
  end
end
