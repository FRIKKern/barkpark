defmodule BarkparkCloud.Repo.Migrations.AddRequestedTeamToDeviceAuthRequests do
  use Ecto.Migration

  # bp-login-ux: a device login may name the team (workspace) it is FOR. When it
  # does, only a member of that team can approve it — an approver from another
  # team is refused (403 team_mismatch) and the row stays pending. NULL keeps the
  # original behaviour: the approver's primary team is minted. Deleting the team
  # deletes its in-flight requests, so a stale code can never bind to a dead team.
  def change do
    alter table(:device_auth_requests) do
      add :requested_team_id, references(:teams, type: :binary_id, on_delete: :delete_all)
    end
  end
end
