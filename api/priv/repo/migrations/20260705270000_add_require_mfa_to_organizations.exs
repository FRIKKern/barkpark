defmodule Barkpark.Repo.Migrations.AddRequireMfaToOrganizations do
  use Ecto.Migration

  # era-w2-org-require-mfa: the org-wide MFA overlay on top of step-up (#1140).
  # Opt-in, default false — with the flag unset everywhere the auth surface is
  # byte-identical to today.
  def change do
    alter table(:organizations) do
      add :require_mfa, :boolean, default: false, null: false
    end
  end
end
