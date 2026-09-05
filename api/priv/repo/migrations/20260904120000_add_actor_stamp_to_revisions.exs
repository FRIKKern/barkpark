defmodule Barkpark.Repo.Migrations.AddActorStampToRevisions do
  @moduledoc """
  Edit-on-the-link slice 4 (task-e99a8e946f80f52c) — WHO made a revision, in
  the vocabulary the reader actually has.

  `revisions.actor_user_id` already existed, but it is a bare id with no kind:
  it cannot say whether the string is a user id, an API-token id or a share
  link, and it has no room for a human label. The paper reader admits three
  identified principals (an account user, an API token, a share link) plus the
  anonymous visitor, so version history needs the KIND alongside the id to be
  readable at all.

  Three nullable text columns, no default, no constraint, no backfill:

    * `actor_kind`  — "user" | "api_token" | "share" | "anonymous"
    * `actor_id`    — the principal id for that kind (nil for anonymous)
    * `actor_label` — a display label (an email, a token name), nil when unknown

  `ADD COLUMN <name> varchar` with no default is a catalog-only change in
  PostgreSQL 11+ — it takes an ACCESS EXCLUSIVE lock for the catalog write
  alone, never rewrites the heap, and is safe against a live `revisions` table.

  NULLABLE by necessity: history written before these columns existed recorded
  no kind and cannot be backfilled (`actor_user_id` alone cannot tell a user id
  from a token id). Those rows keep reading exactly as before.
  """
  use Ecto.Migration

  def change do
    alter table(:revisions) do
      add :actor_kind, :string
      add :actor_id, :string
      add :actor_label, :string
    end
  end
end
