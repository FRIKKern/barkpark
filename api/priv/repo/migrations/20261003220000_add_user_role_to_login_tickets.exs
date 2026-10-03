defmodule Barkpark.Repo.Migrations.AddUserRoleToLoginTickets do
  @moduledoc """
  Owner ruling #26 (2026-10-03, "Match role, revoke"): a user-shaped login
  ticket carries the Cloud team role of the person it signs in, so a team
  member lands in Studio as a member, not as the Default-workspace owner.

  ADDITIVE ONLY: one nullable column. A NULL role is the pre-ruling ticket
  shape (an older control plane), which the consume keeps reading as before.
  """
  use Ecto.Migration

  def change do
    alter table(:login_tickets) do
      add :user_role, :string, null: true
    end
  end
end
