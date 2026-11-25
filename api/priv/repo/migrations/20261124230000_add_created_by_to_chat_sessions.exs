defmodule Barkpark.Repo.Migrations.AddCreatedByToChatSessions do
  @moduledoc """
  task-7efaf895e8bc88e4 — additive, nullable, no backfill. A chat session never
  recorded who made it. `created_by` is `"api_token:<id>"` or `"user:<id>"`
  (the principal-ref `preview_links.created_by` already uses), stamped at
  create. Every existing row stays NULL: nothing recorded its creator.

  `ADD COLUMN ... varchar` with no default is a catalog-only change in
  PostgreSQL 11+; it never rewrites `chat_sessions`.
  """
  use Ecto.Migration

  def change do
    alter table(:chat_sessions) do
      add :created_by, :string, null: true
    end
  end
end
