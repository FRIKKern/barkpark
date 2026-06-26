defmodule BarkparkCloud.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  # Cloud identity: the User is the principal behind "one login for all your
  # Barkparks". Email is the natural key — case-insensitive via citext so
  # "Ada@x.com" and "ada@x.com" are the SAME login. The api/ app uses plain
  # text + a unique index for slugs (no citext anywhere there), but an email
  # login genuinely wants case-insensitive uniqueness at the DB level, so the
  # control plane reaches for the citext extension here.
  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :hashed_password, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
  end
end
