defmodule Barkpark.Repo.Migrations.BindEpicAssignmentsToTasks do
  use Ecto.Migration

  def up do
    create table(:epic_assignment_tasks, primary_key: false) do
      add :assignment_id,
          references(:epic_assignments, type: :uuid, on_delete: :restrict),
          primary_key: true

      add :task_id,
          references(:documents, type: :uuid, on_delete: :restrict),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:epic_assignment_tasks, [:task_id],
             name: :epic_assignment_tasks_task_index
           )

    execute """
    CREATE TRIGGER epic_assignment_tasks_no_update_delete
    BEFORE UPDATE OR DELETE ON epic_assignment_tasks
    FOR EACH ROW EXECUTE FUNCTION barkpark_epic_ledger_immutable();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS epic_assignment_tasks_no_update_delete ON epic_assignment_tasks;"
    drop table(:epic_assignment_tasks)
  end
end
