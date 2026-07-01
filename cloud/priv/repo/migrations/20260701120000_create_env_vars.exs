defmodule BarkparkCloud.Repo.Migrations.CreateEnvVars do
  use Ecto.Migration

  # User-managed env vars / secrets, scoped on Barkpark Cloud's tenancy ladder
  # (team | barkpark) and injected into provisioned instances. The Cloud
  # adaptation of Coolify's `shared_environment_variables` table, collapsed from
  # Coolify's four PaaS scopes onto Cloud's only two tenancy units.
  #
  # `value_encrypted` holds CIPHERTEXT ONLY — Base64 of AES-256-GCM
  # (BarkparkCloud.Registry.Vault); plaintext never touches the DB (text, since
  # the Base64 payload is unbounded by value length). Per-scope partial-unique
  # indexes give a key uniqueness WITHIN its (team) or (instance) scope:
  # Postgres treats NULL != NULL, so each index bites only the rows whose FK
  # matches its WHERE. FKs cascade on team/barkpark delete (Coolify's
  # cleanup invariant — drop a team or an instance, its vars go with it).
  def change do
    create table(:env_vars, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :team_id, references(:teams, type: :binary_id, on_delete: :delete_all), null: false

      add :barkpark_id, references(:barkparks, type: :binary_id, on_delete: :delete_all)

      add :key, :string, null: false
      add :value_encrypted, :text, null: false
      add :scope, :string, null: false, default: "team"
      add :is_secret, :boolean, null: false, default: true
      add :is_shown_once, :boolean, null: false, default: false
      add :comment, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:env_vars, [:team_id])
    create index(:env_vars, [:barkpark_id])

    # Team-scope: a key is unique per team among the rows with NO instance.
    create unique_index(:env_vars, [:key, :team_id],
             where: "barkpark_id IS NULL",
             name: :env_vars_team_key_unique_idx
           )

    # Instance-scope: a key is unique per barkpark among instance-scoped rows.
    create unique_index(:env_vars, [:key, :barkpark_id],
             where: "barkpark_id IS NOT NULL",
             name: :env_vars_barkpark_key_unique_idx
           )

    # The scope discriminator must agree with barkpark_id presence (DB-enforced).
    create constraint(:env_vars, :env_vars_scope_shape,
             check: """
             (scope = 'team' AND barkpark_id IS NULL) OR
             (scope = 'barkpark' AND barkpark_id IS NOT NULL)
             """
           )
  end
end
