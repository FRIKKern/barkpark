defmodule Barkpark.Repo.Migrations.AddUserEmailToLoginTickets do
  use Ecto.Migration

  # cloud-identity-studio-handoff: a USER-shaped login ticket carries the
  # cloud account's email; consuming it JIT-provisions that user and mints a
  # user_session instead of dropping the api_token into the session. Nullable
  # — a nil email is the legacy token-shaped ticket, byte-identical behavior.
  def change do
    alter table(:login_tickets) do
      add :user_email, :string
    end
  end
end
