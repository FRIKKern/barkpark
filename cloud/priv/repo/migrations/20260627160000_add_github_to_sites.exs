defmodule BarkparkCloud.Repo.Migrations.AddGithubToSites do
  use Ecto.Migration

  # P7 (github-webhook): a Site can be configured with a GitHub repo + branch +
  # webhook secret so pushes to that branch trigger an automatic Deployment.
  #
  # All three columns are NULL-able additions — an unconfigured site behaves
  # exactly as before; the webhook route is the only consumer and it 404s when
  # github_webhook_secret_encrypted is NULL. The secret is Vault-encrypted at
  # rest (same pattern as env_encrypted); the plaintext is shown ONCE to the
  # user at connect time and never persisted.
  #
  # github_repo is the conventional "owner/repo" form (e.g. "FRIKKern/barkpark").
  # github_branch defaults to "main" on the changeset side, NULL here so an
  # untouched legacy row keeps "no github config" as a single null check.
  def change do
    alter table(:sites) do
      add :github_repo, :string
      add :github_branch, :string
      add :github_webhook_secret_encrypted, :text
    end
  end
end
