defmodule Barkpark.Repo.Migrations.AddExpiryWarnedDaysToApiTokens do
  @moduledoc """
  Expiry warnings for API tokens (`Barkpark.Auth.TokenExpiryWarningWorker`).

  ADDITIVE ONLY: one nullable column. `expiry_warned_days` holds the last
  warning step sent for the token's current `expires_at` (14, 7 or 1 days
  ahead). NULL means no warning has been sent, which is every existing row.
  """
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      add :expiry_warned_days, :integer, null: true
    end
  end
end
