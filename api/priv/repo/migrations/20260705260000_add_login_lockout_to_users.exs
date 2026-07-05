defmodule Barkpark.Repo.Migrations.AddLoginLockoutToUsers do
  use Ecto.Migration

  # Per-account login lockout (era-w7): `failed_login_count` counts consecutive
  # failures; when it crosses the threshold the account is locked until
  # `locked_until`. Independent of source IP — an attacker rotating IPs against
  # ONE account is throttled, unlike the IP-keyed RateLimit plug.
  def change do
    alter table(:users) do
      add :failed_login_count, :integer, null: false, default: 0
      add :locked_until, :utc_datetime_usec
    end
  end
end
