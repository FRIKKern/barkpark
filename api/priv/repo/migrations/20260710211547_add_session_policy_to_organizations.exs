defmodule Barkpark.Repo.Migrations.AddSessionPolicyToOrganizations do
  use Ecto.Migration

  # era-w8-org-session-policy: org-wide session lifetime governance — an idle
  # timeout and an absolute lifetime, both in seconds. NULLABLE by design:
  # a NULL column imposes NO bound, so with both unset the session-auth surface
  # is byte-identical to the hardcoded 30-day / no-idle default (zero-tax).
  # Strictest-wins across a user's orgs is resolved in `Barkpark.Tenancy`.
  def change do
    alter table(:organizations) do
      add :session_idle_timeout_seconds, :integer, null: true
      add :session_absolute_lifetime_seconds, :integer, null: true
    end
  end
end
