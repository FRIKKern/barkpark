defmodule Barkpark.Repo.Migrations.AddPatFieldsToApiTokens do
  use Ecto.Migration

  # api/ PAT fast-follow — extend api_tokens for a self-service Studio token
  # pane with parity to the cloud/ control-plane PAT. ADDITIVE ONLY: every
  # existing token (the dev token, P5 site/share tokens) keeps working with the
  # new columns NULL. `label` and `permissions` are NOT renamed or dropped.
  #
  # ADAPTATION NOTE: the cloud/ design proposed a `user_id` FK, but api/ Studio
  # is admin-gated (a single admin identity via `LiveAuth :admin`) — there is no
  # `users` table to reference. So PAT "ownership" in api/ is the admin who
  # minted it, recorded as the `created_by` audit breadcrumb (Coolify ties a PAT
  # to a User; the api/ analogue is the admin session, captured as a string).
  #
  #   name         — user-facing description, distinct from the internal `label`.
  #   last_used_at — throttled stamp from require_token.ex so operators can spot
  #                  dead tokens (mirrors cloud/'s UserToken.last_used_at).
  #   created_by   — audit breadcrumb (the minting admin identity / email).
  def change do
    alter table(:api_tokens) do
      add :name, :string
      add :last_used_at, :utc_datetime_usec
      add :created_by, :string
    end
  end
end
