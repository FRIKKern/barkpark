defmodule Barkpark.Repo.Migrations.CreateWebauthnChallengeReplays do
  @moduledoc """
  Owner ruling #34 item 2 (2026-10-03, task-d9e8f02056e39763): one row per
  passkey authentication challenge a login or step-up has spent, keyed on the
  digest of the challenge bytes, kept until the challenge token's own expiry.
  A second assertion over the same challenge finds its row and is refused. A
  table rather than ETS so every node sees it (same shape as
  saml_assertion_replays). New and empty: no existing data to migrate.
  """
  use Ecto.Migration

  def change do
    create table(:webauthn_challenge_replays, primary_key: false) do
      add :digest, :string, primary_key: true, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:webauthn_challenge_replays, [:expires_at])
  end
end
