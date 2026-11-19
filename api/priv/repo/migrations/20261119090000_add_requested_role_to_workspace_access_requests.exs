defmodule Barkpark.Repo.Migrations.AddRequestedRoleToWorkspaceAccessRequests do
  @moduledoc """
  task-018e79d8734a1b08: a member may ask for a higher role, and a request is
  fresh only while the asker's seat is unchanged.

  `workspace_memberships.seat_change` is the seat's change stamp, a random
  uuid. A BEFORE INSERT OR UPDATE trigger sets a new one on every write to a
  seat row, by any writer, whatever value the row carried, also under
  `session_replication_role = replica` (ENABLE ALWAYS). The column default
  gives every existing seat one here.

  On `workspace_access_requests`:

    * `requested_role` is the role the asker named (a seat request may name
      none);
    * `from_role` is the role a member held when asking, set only for a role
      request;
    * `seat_change` is the asker's seat stamp at ask time, nil when they had
      no seat. They are set together or not at all (CHECK).

  Existing requests get NULLs, which is a seat request.
  """
  use Ecto.Migration

  # `MANIFEST.sha256` is regenerated with this commit (migration_manifest_test).

  def up do
    alter table(:workspace_access_requests) do
      add :requested_role, :string
      add :from_role, :string
      add :seat_change, :uuid
    end

    create constraint(:workspace_access_requests, :workspace_access_requests_role_ask_shape,
             check: "(from_role IS NULL) = (seat_change IS NULL)"
           )

    execute """
    ALTER TABLE workspace_memberships
      ADD COLUMN seat_change uuid NOT NULL DEFAULT gen_random_uuid()
    """

    execute """
    CREATE FUNCTION workspace_memberships_seat_change() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      NEW.seat_change := gen_random_uuid();
      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER workspace_memberships_seat_change
      BEFORE INSERT OR UPDATE ON workspace_memberships
      FOR EACH ROW EXECUTE FUNCTION workspace_memberships_seat_change()
    """

    # ALWAYS: it fires under `session_replication_role = replica` too.
    execute "ALTER TABLE workspace_memberships ENABLE ALWAYS TRIGGER workspace_memberships_seat_change"
  end

  def down do
    execute "DROP TRIGGER workspace_memberships_seat_change ON workspace_memberships"
    execute "DROP FUNCTION workspace_memberships_seat_change()"
    execute "ALTER TABLE workspace_memberships DROP COLUMN seat_change"

    drop constraint(:workspace_access_requests, :workspace_access_requests_role_ask_shape)

    alter table(:workspace_access_requests) do
      remove :seat_change
      remove :from_role
      remove :requested_role
    end
  end
end
