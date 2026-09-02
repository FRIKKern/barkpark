defmodule BarkparkCloud.Repo.Migrations.DropEnvVars do
  use Ecto.Migration

  # The team env-var feature is withdrawn (product ruling, 2026-09-02 15:05Z):
  #
  #   "DELETE the team env-var feature (zero prod rows ever; precedent says
  #    delete; git keeps it)."
  #
  # 20260701120400 created `env_vars` as the Cloud adaptation of Coolify's
  # `shared_environment_variables`. The console shipped the UI and the routes,
  # and in the two months since NOTHING was ever stored: on the production
  # control plane (barkpark-cp, 178.105.92.191, cloud-db-1 /
  # barkpark_cloud_prod), read READ-ONLY on 2026-09-02 before this migration was
  # written,
  #
  #   SELECT count(*) FROM env_vars;                    ->  0
  #   SELECT n_tup_ins, n_tup_upd, n_tup_del            ->  0, 0, 0
  #     FROM pg_stat_user_tables WHERE relname='env_vars';
  #
  # so the drop below destroys no customer data — the "zero rows ever" premise
  # the ruling rests on is the table's own insert counter, not just its current
  # size. The owner may overrule within the week; git keeps the feature.
  #
  # ORDERED WITH THE DEPLOY. The commit that carries this migration also deletes
  # `BarkparkCloud.Registry.EnvVar` and every route that read it, so no node —
  # old or new — selects the table after the swap. It still runs LAST in the
  # deploy (cp-deploy.sh boots the idle slot, which migrates on boot, while the
  # OLD slot is still serving): for the seconds both slots overlap the old slot
  # would 500 on the env-var routes it still exposes. That is acceptable for a
  # feature with zero rows and zero users, and it is the reason this is a table
  # drop rather than an expand/contract — there is nothing to contract onto.
  #
  # `down/0` recreates the table verbatim from 20260701120400 — same columns,
  # types, defaults, FKs, partial-unique indexes and the scope-shape check
  # constraint — so a rollback lands on a schema the previous release can read
  # and write. The rows are not restored, because there were none.
  def up do
    drop table(:env_vars)
  end

  def down do
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

    create unique_index(:env_vars, [:key, :team_id],
             where: "barkpark_id IS NULL",
             name: :env_vars_team_key_unique_idx
           )

    create unique_index(:env_vars, [:key, :barkpark_id],
             where: "barkpark_id IS NOT NULL",
             name: :env_vars_barkpark_key_unique_idx
           )

    create constraint(:env_vars, :env_vars_scope_shape,
             check: """
             (scope = 'team' AND barkpark_id IS NULL) OR
             (scope = 'barkpark' AND barkpark_id IS NOT NULL)
             """
           )
  end
end
