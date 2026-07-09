defmodule Barkpark.Repo.Migrations.AddRailSnapshotToChatSessions do
  use Ecto.Migration

  def change do
    alter table(:chat_sessions) do
      # The agents-rail mission-control snapshot (charter D47), keyed by the
      # sub-agent's `task_id` (background_tasks_changed carries NO tool_use_id, so
      # the D45 spawn-row merge route cannot express it). Each entry:
      #   %{task_id => %{"row" => %{task_type, description}, "workflow" => tree,
      #                  "status" => "running"|"completed"|"interrupted",
      #                  "usage" => last-known totals, "seq" => insertion order}}
      # Updated IN PLACE (SET the whole column), so a reopened session replays the
      # last-known rail; nil until a Workflow runs. Persisted coarsely — only a
      # structural/state change writes; a token-only progress tick does not.
      add :rail_snapshot, :map
    end
  end
end
