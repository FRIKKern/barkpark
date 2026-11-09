defmodule Barkpark.Repo.Migrations.AddBindOnSsoToWorkspaceInvitations do
  @moduledoc """
  task-1881e6e768d1be22: an instance without mail never delivers an
  invitation, so an admin could not seat an existing account. A pending seat
  with `bind_on_sso` set is accepted on the user's next SSO sign-in through the
  workspace's organization. The user can still accept it by hand.

  Additive only: one column with a false default.
  """
  use Ecto.Migration

  def change do
    alter table(:workspace_invitations) do
      add :bind_on_sso, :boolean, null: false, default: false
    end
  end
end
