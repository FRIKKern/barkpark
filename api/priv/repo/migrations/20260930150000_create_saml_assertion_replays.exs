defmodule Barkpark.Repo.Migrations.CreateSamlAssertionReplays do
  @moduledoc """
  task-223e04ce556b1950: one row per SAML assertion the ACS has consumed, keyed
  on the digest of the SIGNED assertion (not the unsigned envelope), kept until
  the assertion's own stale time. A second POST of the same assertion finds
  its row and logs nobody in. A table rather than ETS so every node sees it.
  """
  use Ecto.Migration

  def change do
    create table(:saml_assertion_replays, primary_key: false) do
      add :digest, :string, primary_key: true, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end
  end
end
