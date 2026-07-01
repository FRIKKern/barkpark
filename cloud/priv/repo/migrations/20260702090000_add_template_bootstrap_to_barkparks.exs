defmodule BarkparkCloud.Repo.Migrations.AddTemplateBootstrapToBarkparks do
  use Ecto.Migration

  # dwb-4 — content-template bootstrap columns on the barkpark row.
  #
  #   * template — the deploy-template slug the owner picked at launch (validated
  #     at go-live against the worker's embedded catalog). NULL = no template,
  #     the pre-dwb-4 launch exactly.
  #
  # The bootstrap OUTPUTS the worker reports on /succeed (workspace → schemas →
  # seed+publish → read token → app env), stored so the dashboard/deploy step can
  # retrieve them without SSH:
  #
  #   * bootstrap_workspace / bootstrap_project / bootstrap_dataset — plain
  #     slugs (not secrets).
  #   * bootstrap_read_token_encrypted — the minted workspace-bound public-read
  #     token, Vault-encrypted at rest (the same AES-256-GCM seam as
  #     admin_token_encrypted). NEVER plaintext, NEVER serialized in
  #     barkpark_json.
  #   * bootstrap_env_encrypted — the resolved app env map (JSON), Vault-encrypted
  #     as a whole because it CONTAINS the read token (env[].source=read_token).
  #
  # Reversible: `alter/add` inverts to a column drop.
  def change do
    alter table(:barkparks) do
      add :template, :string
      add :bootstrap_workspace, :string
      add :bootstrap_project, :string
      add :bootstrap_dataset, :string
      add :bootstrap_read_token_encrypted, :text
      add :bootstrap_env_encrypted, :text
    end
  end
end
