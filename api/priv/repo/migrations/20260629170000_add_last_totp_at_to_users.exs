defmodule Barkpark.Repo.Migrations.AddLastTotpAtToUsers do
  use Ecto.Migration

  # MEDIUM-6 (RED-TEAM): TOTP codes were replayable within their 30s step — a
  # captured code worked again until the period rolled over. We now record the
  # last consumed time-step (`last_totp_at`) and feed it to NimbleTOTP's `:since`
  # option so a code from the same-or-earlier period is rejected as reuse.
  #
  # ADDITIVE: nullable, defaults to nil (no prior consumption). Existing rows
  # need no backfill — the first successful verify stamps it.
  def change do
    alter table(:users) do
      add :last_totp_at, :utc_datetime_usec
    end
  end
end
