defmodule Barkpark.Repo.Migrations.AddDisplayNameToUsers do
  use Ecto.Migration

  # task-cfb6ca3f5ffaf099 — a server-side display name for an account, so
  # Media.Storage.Actor.display/2 can name another editor by it instead of
  # the email-shaped stamp or the generic "another editor" fallback. Nullable:
  # an account with no display name set still renders "another editor",
  # exactly as it does today.
  def change do
    alter table(:users) do
      add :display_name, :string
    end
  end
end
