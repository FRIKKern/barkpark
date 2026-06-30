defmodule Barkpark.Repo.Migrations.AddOwnerIdToDocuments do
  use Ecto.Migration

  # Phase 4 (core-auth) — row/ownership ACL. `owner_id` records the user who
  # owns a document on an `owner_scoped: true` type. ADDITIVE + opt-in: the
  # column is nullable with no FK and no default, so every existing row stays
  # NULL (unowned) and every non-owner_scoped write keeps it NULL — making
  # `Barkpark.Content.Scope.scope_to_owner/2` a structural no-op outside the
  # opt-in types. No FK to `users` on purpose: an owner_scoped type may predate
  # (or outlive) a given user row, and the ACL fails closed on a NULL owner
  # rather than cascading. The index supports the `owner_id == ? OR NULL` filter
  # the non-admin-user read path appends.
  def change do
    alter table(:documents) do
      add :owner_id, :binary_id, null: true
    end

    create index(:documents, [:owner_id])
  end
end
