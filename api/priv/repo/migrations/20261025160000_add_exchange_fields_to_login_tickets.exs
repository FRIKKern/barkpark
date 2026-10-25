defmodule Barkpark.Repo.Migrations.AddExchangeFieldsToLoginTickets do
  @moduledoc """
  "Sign in with Barkpark Cloud" for an external Studio: a login ticket can be
  minted for a SERVER-SIDE exchange instead of a browser consume.

  ADDITIVE ONLY: three nullable columns. `purpose` NULL is the browser ticket
  every existing row and every older control plane mints; "exchange" marks a
  ticket only `POST /v1/auth/login-tickets/exchange` accepts. `audience` is the
  Studio origin the exchange must name, and `code_challenge` the PKCE S256
  challenge its `code_verifier` must answer.
  """
  use Ecto.Migration

  def change do
    alter table(:login_tickets) do
      add :purpose, :string, null: true
      add :audience, :string, null: true
      add :code_challenge, :string, null: true
    end
  end
end
